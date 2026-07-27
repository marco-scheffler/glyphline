import Foundation
import GRDB

enum DatabaseQueueFactory {
    static func makeInMemory() throws -> DatabaseQueue {
        try DatabaseQueue()
    }

    static func makeDefault() throws -> DatabaseQueue {
        let baseURL = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directoryURL = baseURL.appendingPathComponent("Glyphline", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let databaseURL = directoryURL.appendingPathComponent("glyphline.sqlite", isDirectory: false)
        return try DatabaseQueue(path: databaseURL.path)
    }
}
