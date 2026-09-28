/**
 * Durable `printer.PrintJobStore` over SQLite (migration v5) — the backing the contracts
 * `PrintJobQueue` needs so its never-silently-lose semantics survive restart. Dumb row mapping
 * only; every safety rule lives in the tested queue.
 */
import type { printer } from '@fieldcapture/contracts';

import type { SqlDriver, SqlValue } from './sqlDriver';

interface PrintJobRow extends Record<string, unknown> {
  print_job_id: string;
  sr_id: string;
  field_ticket_id: string;
  employee_id: string | null;
  worker_ref: string | null;
  printer_profile_id: string;
  created_at: string;
  printed_at: string | null;
  synced_at: string | null;
  status: string;
  retry_count: number;
  error_code: string | null;
  diagnostic_message: string | null;
  payload_hash: string;
  payload_size_bytes: number;
}

const COLUMNS =
  'print_job_id, sr_id, field_ticket_id, employee_id, worker_ref, printer_profile_id, ' +
  'created_at, printed_at, synced_at, status, retry_count, error_code, diagnostic_message, ' +
  'payload_hash, payload_size_bytes';

function toRowParams(job: printer.PrintJob): SqlValue[] {
  return [
    job.printJobId,
    job.srId,
    job.fieldTicketId,
    job.employeeId ?? null,
    job.workerRef ?? null,
    job.printerProfileId,
    job.createdAt,
    job.printedAt,
    job.syncedAt,
    job.status,
    job.retryCount,
    job.errorCode,
    job.diagnosticMessage,
    job.payloadHash,
    job.payloadSizeBytes,
  ];
}

function fromRow(row: PrintJobRow): printer.PrintJob {
  return {
    printJobId: row.print_job_id,
    srId: row.sr_id,
    fieldTicketId: row.field_ticket_id,
    ...(row.employee_id !== null ? { employeeId: row.employee_id } : {}),
    ...(row.worker_ref !== null ? { workerRef: row.worker_ref } : {}),
    printerProfileId: row.printer_profile_id,
    createdAt: row.created_at,
    printedAt: row.printed_at,
    syncedAt: row.synced_at,
    status: row.status as printer.PrintJobStatus,
    retryCount: row.retry_count,
    errorCode: row.error_code,
    diagnosticMessage: row.diagnostic_message,
    payloadHash: row.payload_hash,
    payloadSizeBytes: row.payload_size_bytes,
  };
}

export class SqlitePrintJobStore implements printer.PrintJobStore {
  constructor(private readonly db: SqlDriver) {}

  upsert(job: printer.PrintJob): void {
    this.db.run(
      `INSERT OR REPLACE INTO print_jobs (${COLUMNS})
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      toRowParams(job),
    );
  }

  get(id: string): printer.PrintJob | undefined {
    const row = this.db.first<PrintJobRow>(
      `SELECT ${COLUMNS} FROM print_jobs WHERE print_job_id = ?`,
      [id],
    );
    return row === null ? undefined : fromRow(row);
  }

  all(): printer.PrintJob[] {
    return this.db
      .all<PrintJobRow>(`SELECT ${COLUMNS} FROM print_jobs ORDER BY created_at, print_job_id`)
      .map(fromRow);
  }

  delete(id: string): void {
    this.db.run('DELETE FROM print_jobs WHERE print_job_id = ?', [id]);
  }
}
