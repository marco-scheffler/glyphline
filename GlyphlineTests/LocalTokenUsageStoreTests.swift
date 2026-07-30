import GRDB
import XCTest
@testable import Glyphline

final class LocalTokenUsageStoreTests: XCTestCase {
    private func makeStore() throws -> LedgerStore {
        let dbQueue = try DatabaseQueueFactory.makeInMemory()
        try Migrations.migrate(dbQueue)
        return LedgerStore(dbQueue: dbQueue)
    }

    private let day = Date(timeIntervalSince1970: 1_800_000_000)

    /// The test this task exists for. A transcript is read incrementally, so the
    /// same day and model is written again and again carrying only the newly
    /// read tokens. If any conflict clause replaces instead of adds, everything
    /// accumulated for that day and model is silently destroyed.
    func testASecondWriteForTheSameDayAndModelAddsToTheFirst() throws {
        let store = try makeStore()

        try store.upsertLocalTokenUsage([
            LocalTokenUsage(
                bucketStart: day,
                model: "claude-opus-4-8",
                inputTokens: 10,
                cacheCreationTokens: 20,
                cacheReadTokens: 30,
                outputTokens: 40,
                requests: 1
            ),
        ])

        try store.upsertLocalTokenUsage([
            LocalTokenUsage(
                bucketStart: day,
                model: "claude-opus-4-8",
                inputTokens: 1,
                cacheCreationTokens: 2,
                cacheReadTokens: 3,
                outputTokens: 4,
                requests: 5
            ),
        ])

        let rows = try store.fetchLocalTokenUsage(since: nil)
        XCTAssertEqual(rows.count, 1, "the two writes are the same row, not two")

        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.inputTokens, 11, "inputTokens must accumulate, not be replaced")
        XCTAssertEqual(row.cacheCreationTokens, 22, "cacheCreationTokens must accumulate")
        XCTAssertEqual(row.cacheReadTokens, 33, "cacheReadTokens must accumulate")
        XCTAssertEqual(row.outputTokens, 44, "outputTokens must accumulate")
        XCTAssertEqual(row.requests, 6, "requests must accumulate")
        XCTAssertEqual(row.totalTokens, 110)
    }

    /// Many small deltas, as a real incremental scan produces them.
    func testManyDeltasSumExactly() throws {
        let store = try makeStore()

        for _ in 0 ..< 50 {
            try store.upsertLocalTokenUsage([
                LocalTokenUsage(
                    bucketStart: day,
                    model: "claude-sonnet-4-8",
                    inputTokens: 7,
                    cacheCreationTokens: 0,
                    cacheReadTokens: 100,
                    outputTokens: 3,
                    requests: 1
                ),
            ])
        }

        let row = try XCTUnwrap(try store.fetchLocalTokenUsage(since: nil).first)
        XCTAssertEqual(row.inputTokens, 350)
        XCTAssertEqual(row.cacheReadTokens, 5_000)
        XCTAssertEqual(row.outputTokens, 150)
        XCTAssertEqual(row.requests, 50)
    }

    func testDifferentModelsAndDaysStayApart() throws {
        let store = try makeStore()
        let nextDay = day.addingTimeInterval(86_400)

        try store.upsertLocalTokenUsage([
            LocalTokenUsage(bucketStart: day, model: "opus", inputTokens: 1),
            LocalTokenUsage(bucketStart: day, model: "sonnet", inputTokens: 2),
            LocalTokenUsage(bucketStart: nextDay, model: "opus", inputTokens: 4),
        ])

        let rows = try store.fetchLocalTokenUsage(since: nil)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows.map(\.inputTokens).reduce(0, +), 7)
    }

    /// A record without a model name must get its own row rather than colliding
    /// on SQL NULL, which never equals itself in a primary key.
    func testAnUnnamedModelAccumulatesInItsOwnRow() throws {
        let store = try makeStore()

        try store.upsertLocalTokenUsage([
            LocalTokenUsage(bucketStart: day, model: nil, inputTokens: 5),
        ])
        try store.upsertLocalTokenUsage([
            LocalTokenUsage(bucketStart: day, model: nil, inputTokens: 6),
        ])

        let rows = try store.fetchLocalTokenUsage(since: nil)
        XCTAssertEqual(rows.count, 1)
        XCTAssertNil(rows[0].model)
        XCTAssertEqual(rows[0].inputTokens, 11)
    }

    func testFetchSinceReturnsRowsOnOrAfterTheDateAndNilMeansAllTime() throws {
        let store = try makeStore()
        let older = day.addingTimeInterval(-2 * 86_400)
        let boundary = day
        let newer = day.addingTimeInterval(86_400)

        try store.upsertLocalTokenUsage([
            LocalTokenUsage(bucketStart: older, model: "opus", inputTokens: 1),
            LocalTokenUsage(bucketStart: boundary, model: "opus", inputTokens: 2),
            LocalTokenUsage(bucketStart: newer, model: "opus", inputTokens: 4),
        ])

        XCTAssertEqual(try store.fetchLocalTokenUsage(since: nil).count, 3)

        let fromBoundary = try store.fetchLocalTokenUsage(since: boundary)
        XCTAssertEqual(
            fromBoundary.map(\.inputTokens),
            [2, 4],
            "the boundary day itself is included"
        )

        XCTAssertEqual(try store.fetchLocalTokenUsage(since: newer).map(\.inputTokens), [4])
    }

    func testEmptyWriteIsANoOp() throws {
        let store = try makeStore()
        try store.upsertLocalTokenUsage([])
        XCTAssertTrue(try store.fetchLocalTokenUsage(since: nil).isEmpty)
    }

    func testLocalScanWatermarkRoundTripsAndAdvances() throws {
        let store = try makeStore()
        let stamp = Date(timeIntervalSince1970: 1_800_000_000)

        XCTAssertNil(try store.fetchLocalScanWatermark(sourceKey: "/tmp/a.jsonl"))

        try store.saveLocalScanWatermark(
            LocalScanWatermark(
                sourceKey: "/tmp/a.jsonl",
                fileSize: 4_096,
                fileMTime: stamp,
                byteOffset: 2_048,
                updatedAt: stamp
            )
        )

        let stored = try XCTUnwrap(try store.fetchLocalScanWatermark(sourceKey: "/tmp/a.jsonl"))
        XCTAssertEqual(stored.fileSize, 4_096)
        XCTAssertEqual(stored.byteOffset, 2_048)
        XCTAssertEqual(stored.fileMTime.timeIntervalSince1970, stamp.timeIntervalSince1970, accuracy: 0.001)

        // A watermark is a resume point, not a total: a later save replaces it.
        try store.saveLocalScanWatermark(
            LocalScanWatermark(
                sourceKey: "/tmp/a.jsonl",
                fileSize: 8_192,
                fileMTime: stamp,
                byteOffset: 8_192,
                updatedAt: stamp
            )
        )

        let advanced = try XCTUnwrap(try store.fetchLocalScanWatermark(sourceKey: "/tmp/a.jsonl"))
        XCTAssertEqual(advanced.byteOffset, 8_192)
        XCTAssertEqual(advanced.fileSize, 8_192)
        XCTAssertNil(try store.fetchLocalScanWatermark(sourceKey: "/tmp/b.jsonl"))
    }

    private func scanUsage(input: Int64) -> LocalTokenUsage {
        LocalTokenUsage(
            bucketStart: day,
            model: "claude-opus-4-8",
            inputTokens: input,
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            outputTokens: 0,
            requests: 1
        )
    }

    private func scanWatermark(byteOffset: Int64) -> LocalScanWatermark {
        LocalScanWatermark(
            sourceKey: "/tmp/scan.jsonl",
            fileSize: 4_096,
            fileMTime: day,
            byteOffset: byteOffset,
            updatedAt: day
        )
    }

    func testApplyLocalScanWritesRowsAndWatermarksTogether() throws {
        let store = try makeStore()

        try store.applyLocalScan(
            usage: [scanUsage(input: 100)],
            watermarks: [scanWatermark(byteOffset: 512)]
        )

        let rows = try store.fetchLocalTokenUsage(since: nil)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.inputTokens, 100)

        let watermark = try XCTUnwrap(try store.fetchLocalScanWatermark(sourceKey: "/tmp/scan.jsonl"))
        XCTAssertEqual(watermark.byteOffset, 512)
    }

    /// The one that matters. The scan emits deltas, so a watermark that advances
    /// without its tokens landing loses those tokens permanently — the bytes are
    /// never read again. If the write fails anywhere, nothing may survive it.
    func testAFailedApplyLocalScanWritesNeitherRowsNorWatermarks() throws {
        let dbQueue = try DatabaseQueueFactory.makeInMemory()
        try Migrations.migrate(dbQueue)
        let store = LedgerStore(dbQueue: dbQueue)

        try store.applyLocalScan(
            usage: [scanUsage(input: 100)],
            watermarks: [scanWatermark(byteOffset: 512)]
        )

        // Make the watermark half of the next apply fail, after the usage half
        // has already been written inside the same transaction.
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    CREATE TRIGGER blockWatermarks
                    BEFORE INSERT ON \(LedgerTable.localScanWatermarks)
                    BEGIN SELECT RAISE(ABORT, 'watermark write failed'); END
                    """
            )
        }

        XCTAssertThrowsError(
            try store.applyLocalScan(
                usage: [scanUsage(input: 7)],
                watermarks: [scanWatermark(byteOffset: 1_024)]
            )
        )

        let rows = try store.fetchLocalTokenUsage(since: nil)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(
            rows.first?.inputTokens,
            100,
            "the failed scan's tokens must be rolled back, not added"
        )

        try dbQueue.write { db in
            try db.execute(sql: "DROP TRIGGER blockWatermarks")
        }

        let watermark = try XCTUnwrap(try store.fetchLocalScanWatermark(sourceKey: "/tmp/scan.jsonl"))
        XCTAssertEqual(
            watermark.byteOffset,
            512,
            "the failed scan must not have advanced the resume point"
        )
    }

    /// The watermark of a successful apply really does advance, so the next scan
    /// resumes past what was already counted instead of adding it twice.
    func testASecondApplyResumesFromTheAdvancedWatermark() throws {
        let store = try makeStore()

        try store.applyLocalScan(
            usage: [scanUsage(input: 100)],
            watermarks: [scanWatermark(byteOffset: 512)]
        )
        try store.applyLocalScan(
            usage: [scanUsage(input: 20)],
            watermarks: [scanWatermark(byteOffset: 1_024)]
        )

        let rows = try store.fetchLocalTokenUsage(since: nil)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.inputTokens, 120, "two deltas, added once each")

        let watermark = try XCTUnwrap(try store.fetchLocalScanWatermark(sourceKey: "/tmp/scan.jsonl"))
        XCTAssertEqual(watermark.byteOffset, 1_024)
    }
}
