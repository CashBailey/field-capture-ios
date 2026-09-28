// Port of src/data/deviceIdentity.ts — durable write identity: the per-install
// `device_instance_id` and the monotonic `local_seq` allocator behind every idempotency key
// (`gtr:<device>:<seq>:<uuid>`, ADR 004).
//
// Both MUST be durable: a device id that changes on restart breaks Hub-side dedupe history, and
// a reused local_seq mints an idempotency key that collides with a different operation — Hub
// would then 422 it as an idempotency mismatch. The allocator increments inside a transaction so
// two callers can never be handed the same sequence number.
import Foundation

/// Safe to share when backed by the production `SystemSqliteDriver`, which serializes every
/// operation and transaction on its connection lock.
public final class DeviceIdentity: @unchecked Sendable {
    private let db: SqlDriver

    public init(_ db: SqlDriver) {
        self.db = db
    }

    /// The stable per-install device id, creating it on first run. `generateUuid` is injected
    /// (secure native random in production) — it is used ONCE per install.
    public func ensureDeviceInstanceId(_ generateUuid: () -> String) throws -> String {
        try db.transaction {
            if let row = try db.first("SELECT device_instance_id FROM device_identity WHERE id = 1"),
                let existing = row.string("device_instance_id")
            {
                return existing
            }
            let id = generateUuid()
            if id.isEmpty || id.contains(":") {
                throw SqlError(
                    message: "generated device id is unusable in an idempotency key: \"\(id)\"",
                    code: 1)
            }
            try db.run(
                "INSERT INTO device_identity (id, device_instance_id, next_local_seq) VALUES (1, ?, 0)",
                [.text(id)])
            return id
        }
    }

    /// Allocate the next local_seq (monotonic, never reused, durable before it is returned).
    public func allocateLocalSeq() throws -> Int64 {
        try db.transaction {
            guard let row = try db.first("SELECT next_local_seq FROM device_identity WHERE id = 1"),
                let seq = row.int("next_local_seq")
            else {
                throw SqlError(
                    message: "device identity not initialized — call ensureDeviceInstanceId first",
                    code: 1)
            }
            try db.run("UPDATE device_identity SET next_local_seq = ? WHERE id = 1", [.int(seq + 1)])
            return seq
        }
    }
}
