// Port of src/data/SqliteSyncFrontierStore.ts — Durable `SyncFrontierStore` over SQLite: the
// single-row table holding the server-issued change token the next `/sync/changes` pull resumes
// after. Monotonicity is enforced by the engine (`advanceFrontier`); the one legitimate
// non-monotonic write is the explicit reset after Hub declares the stored token stale.
import FieldContracts
import FieldDomain

public final class SqliteSyncFrontierStore: SyncFrontierStore {
    private let db: SqlDriver
    public let durability: StoreDurability

    public init(_ db: SqlDriver, _ durability: StoreDurability) {
        self.db = db
        self.durability = durability
    }

    public func get() -> ChangeToken? {
        guard
            let row = try! db.first(
                "SELECT authority_epoch, commit_seq FROM sync_frontier WHERE id = 1")
        else { return nil }
        return ChangeToken(
            authorityEpoch: Int(row.int("authority_epoch") ?? 0),
            commitSeq: Int(row.int("commit_seq") ?? 0))
    }

    public func set(_ token: ChangeToken) {
        try! db.run(
            """
            INSERT INTO sync_frontier (id, authority_epoch, commit_seq) VALUES (1, ?, ?)
            ON CONFLICT(id) DO UPDATE SET authority_epoch = excluded.authority_epoch,
                                          commit_seq      = excluded.commit_seq
            """, [.int(Int64(token.authorityEpoch)), .int(Int64(token.commitSeq))])
    }
}
