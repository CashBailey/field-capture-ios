// Durable ESC/POS payload bytes for print jobs. Payloads live separately from print_jobs because
// PrintRuntime finalizes and stores the bytes before it enqueues the corresponding job row.
import Foundation
import FieldContracts

public enum SqlitePrintPayloadStoreError: Error, Equatable, Sendable, CustomStringConvertible, LocalizedError {
    case corruptRecord(printJobId: String, detail: String)

    public var description: String {
        switch self {
        case .corruptRecord(let printJobId, let detail):
            return "print payload \(printJobId) is corrupt: \(detail)"
        }
    }

    public var errorDescription: String? { description }
}

public final class SqlitePrintPayloadStore: PrintPayloadStore, @unchecked Sendable {
    private let db: SqlDriver

    public init(_ db: SqlDriver) {
        self.db = db
    }

    public func put(_ printJobId: String, _ bytes: Data) throws {
        try db.run(
            "INSERT OR REPLACE INTO print_payloads (print_job_id, payload) VALUES (?, ?)",
            [.text(printJobId), .blob(bytes)])
    }

    public func get(_ printJobId: String) throws -> Data? {
        guard
            let row = try db.first(
                "SELECT payload FROM print_payloads WHERE print_job_id = ?",
                [.text(printJobId)])
        else { return nil }
        guard let bytes = row.blob("payload") else {
            throw SqlitePrintPayloadStoreError.corruptRecord(
                printJobId: printJobId, detail: "missing or invalid payload bytes")
        }
        return bytes
    }

    public func delete(_ printJobId: String) throws {
        try db.run("DELETE FROM print_payloads WHERE print_job_id = ?", [.text(printJobId)])
    }
}
