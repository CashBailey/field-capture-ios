// Port of src/data/SqlitePrintJobStore.ts — Durable `printer.PrintJobStore` over SQLite: backs the
// contracts `PrintJobQueue` so its never-silently-lose semantics survive restart. Dumb row mapping
// only; every safety rule lives in the tested queue.
import Foundation
import FieldContracts

private let COLUMNS =
    "print_job_id, sr_id, field_ticket_id, employee_id, worker_ref, printer_profile_id, "
    + "created_at, printed_at, synced_at, status, retry_count, error_code, diagnostic_message, "
    + "payload_hash, payload_size_bytes"

private func toRowParams(_ job: PrintJob) -> [SqlValue] {
    [
        .text(job.printJobId),
        .text(job.srId),
        .text(job.fieldTicketId),
        job.employeeId.map(SqlValue.text) ?? .null,
        job.workerRef.map(SqlValue.text) ?? .null,
        .text(job.printerProfileId),
        .text(job.createdAt),
        job.printedAt.map(SqlValue.text) ?? .null,
        job.syncedAt.map(SqlValue.text) ?? .null,
        .text(job.status.rawValue),
        .int(Int64(job.retryCount)),
        job.errorCode.map(SqlValue.text) ?? .null,
        job.diagnosticMessage.map(SqlValue.text) ?? .null,
        .text(job.payloadHash),
        .int(Int64(job.payloadSizeBytes)),
    ]
}

public enum SqlitePrintJobStoreError: Error, Equatable, Sendable, CustomStringConvertible, LocalizedError {
    case corruptRecord(printJobId: String, detail: String)

    public var description: String {
        switch self {
        case .corruptRecord(let printJobId, let detail):
            return "print job \(printJobId) is corrupt: \(detail)"
        }
    }

    public var errorDescription: String? { description }
}

private func corrupt(_ printJobId: String, _ detail: String) -> SqlitePrintJobStoreError {
    .corruptRecord(printJobId: printJobId, detail: detail)
}

private func requiredText(_ column: String, in row: SqlRow, printJobId: String) throws -> String {
    guard let value = row.string(column) else {
        throw corrupt(printJobId, "missing or invalid \(column)")
    }
    return value
}

private func optionalText(_ column: String, in row: SqlRow, printJobId: String) throws -> String? {
    switch row[column] {
    case .text(let value)?: return value
    case .null?: return nil
    default: throw corrupt(printJobId, "invalid \(column)")
    }
}

private func requiredNonnegativeInt(_ column: String, in row: SqlRow, printJobId: String) throws -> Int {
    guard let rawValue = row.int(column), let value = Int(exactly: rawValue), value >= 0 else {
        throw corrupt(printJobId, "missing, invalid, or negative \(column)")
    }
    return value
}

private func fromRow(_ row: SqlRow) throws -> PrintJob {
    let storedId = row.string("print_job_id") ?? "<unknown>"
    let printJobId = try requiredText("print_job_id", in: row, printJobId: storedId)
    let statusRaw = try requiredText("status", in: row, printJobId: printJobId)
    guard let status = PrintJobStatus(rawValue: statusRaw) else {
        throw corrupt(printJobId, "unknown status \"\(statusRaw)\"")
    }

    let payloadSizeBytes = try requiredNonnegativeInt(
        "payload_size_bytes", in: row, printJobId: printJobId)
    guard payloadSizeBytes > 0 else {
        throw corrupt(printJobId, "payload_size_bytes must be greater than zero")
    }

    return PrintJob(
        printJobId: printJobId,
        srId: try requiredText("sr_id", in: row, printJobId: printJobId),
        fieldTicketId: try requiredText("field_ticket_id", in: row, printJobId: printJobId),
        employeeId: try optionalText("employee_id", in: row, printJobId: printJobId),
        workerRef: try optionalText("worker_ref", in: row, printJobId: printJobId),
        printerProfileId: try requiredText("printer_profile_id", in: row, printJobId: printJobId),
        createdAt: try requiredText("created_at", in: row, printJobId: printJobId),
        printedAt: try optionalText("printed_at", in: row, printJobId: printJobId),
        syncedAt: try optionalText("synced_at", in: row, printJobId: printJobId),
        status: status,
        retryCount: try requiredNonnegativeInt("retry_count", in: row, printJobId: printJobId),
        errorCode: try optionalText("error_code", in: row, printJobId: printJobId),
        diagnosticMessage: try optionalText("diagnostic_message", in: row, printJobId: printJobId),
        payloadHash: try requiredText("payload_hash", in: row, printJobId: printJobId),
        payloadSizeBytes: payloadSizeBytes
    )
}

public final class SqlitePrintJobStore: PrintJobStore, @unchecked Sendable {
    private let db: SqlDriver

    public init(_ db: SqlDriver) {
        self.db = db
    }

    public func upsert(_ job: PrintJob) throws {
        try db.run(
            "INSERT OR REPLACE INTO print_jobs (\(COLUMNS)) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            toRowParams(job))
    }

    public func get(_ id: String) throws -> PrintJob? {
        guard
            let row = try db.first(
                "SELECT \(COLUMNS) FROM print_jobs WHERE print_job_id = ?", [.text(id)])
        else { return nil }
        return try fromRow(row)
    }

    public func all() throws -> [PrintJob] {
        try db.all("SELECT \(COLUMNS) FROM print_jobs ORDER BY created_at, print_job_id").map(fromRow)
    }

    public func delete(_ id: String) throws {
        try db.run("DELETE FROM print_jobs WHERE print_job_id = ?", [.text(id)])
    }
}
