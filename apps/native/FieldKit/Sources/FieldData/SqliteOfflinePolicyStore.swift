// Port of src/data/SqliteOfflinePolicyStore.ts — Durable `OfflinePolicyStore` over SQLite: the
// single-row table that makes the 24h offline window honest across restarts. `recordHubContact`
// is monotonic-forward (a row write only ever advances `last_hub_contact_at_ms`), so neither a
// relaunch nor a clock-skewed earlier value can extend the offline grace window.
import FieldDomain

public final class SqliteOfflinePolicyStore: OfflinePolicyStore {
    private let db: SqlDriver
    public let durability: StoreDurability

    public init(_ db: SqlDriver, _ durability: StoreDurability) {
        self.db = db
        self.durability = durability
    }

    public func getState() -> OfflinePolicyPersistedState {
        let row = try! db.first(
            "SELECT last_hub_contact_at_ms, window_hours FROM offline_policy_state WHERE id = 1")
        return OfflinePolicyPersistedState(
            lastHubContactAtMs: row?.int("last_hub_contact_at_ms"),
            windowHours: row?.real("window_hours"))
    }

    public func recordHubContact(_ atMs: Int64) {
        // Keep the monotonic comparison inside SQLite so two callers cannot interleave a read and
        // write and let an older timestamp win.
        try! db.run(
            """
            INSERT INTO offline_policy_state (id, last_hub_contact_at_ms) VALUES (1, ?)
            ON CONFLICT(id) DO UPDATE SET last_hub_contact_at_ms = CASE
                WHEN offline_policy_state.last_hub_contact_at_ms IS NULL
                    OR excluded.last_hub_contact_at_ms > offline_policy_state.last_hub_contact_at_ms
                THEN excluded.last_hub_contact_at_ms
                ELSE offline_policy_state.last_hub_contact_at_ms
            END
            """, [.int(atMs)])
    }

    public func setWindowHours(_ hours: Double) {
        try! db.run(
            """
            INSERT INTO offline_policy_state (id, window_hours) VALUES (1, ?)
            ON CONFLICT(id) DO UPDATE SET window_hours = excluded.window_hours
            """, [.real(hours)])
    }
}
