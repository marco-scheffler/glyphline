import Foundation

extension LedgerStore {
    static func makeDefault() -> LedgerStore? {
        do {
            let dbQueue = try DatabaseQueueFactory.makeDefault()
            try Migrations.migrate(dbQueue)
            return LedgerStore(dbQueue: dbQueue)
        } catch {
            return nil
        }
    }
}
