/**
 * Durable validation-only location-evidence store over SQLite (Phase 7). Append-only and
 * non-evictable — location evidence is unsynced field work, preserved until the Hub acks it.
 */
import type { fieldwork } from '@fieldcapture/contracts';

import type { LocationEvidenceStore, StoreDurability } from '../domain';
import type { SqlDriver } from './sqlDriver';

interface EvidenceRow extends Record<string, unknown> {
  id: string;
  service_request_id: string;
  place_kind: string;
  evidence_type: string;
  gps_json: string | null;
  notes: string | null;
  state: string;
  created_at: string;
}

const COLUMNS =
  'id, service_request_id, place_kind, evidence_type, gps_json, notes, state, created_at';

function fromRow(row: EvidenceRow): fieldwork.LocationEvidence {
  return {
    id: row.id,
    serviceRequestId: row.service_request_id,
    placeKind: row.place_kind as fieldwork.LocationPlaceKind,
    evidenceType: row.evidence_type,
    ...(row.gps_json !== null
      ? { gps: JSON.parse(row.gps_json) as fieldwork.LocationGpsPoint }
      : {}),
    ...(row.notes !== null ? { notes: row.notes } : {}),
    state: row.state as fieldwork.LocationEvidenceState,
    createdAt: row.created_at,
  };
}

export class SqliteLocationEvidenceStore implements LocationEvidenceStore {
  constructor(
    private readonly db: SqlDriver,
    readonly durability: Exclude<StoreDurability, 'volatile-memory'>,
  ) {}

  record(evidence: fieldwork.LocationEvidence): void {
    this.db.run(
      `INSERT INTO location_evidence (${COLUMNS})
       VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
      [
        evidence.id,
        evidence.serviceRequestId,
        evidence.placeKind,
        evidence.evidenceType,
        evidence.gps !== undefined ? JSON.stringify(evidence.gps) : null,
        evidence.notes ?? null,
        evidence.state,
        evidence.createdAt,
      ],
    );
  }

  get(id: string): fieldwork.LocationEvidence | undefined {
    const row = this.db.first<EvidenceRow>(
      `SELECT ${COLUMNS} FROM location_evidence WHERE id = ?`,
      [id],
    );
    return row === null ? undefined : fromRow(row);
  }

  listByServiceRequest(serviceRequestId: string): fieldwork.LocationEvidence[] {
    return this.db
      .all<EvidenceRow>(
        `SELECT ${COLUMNS} FROM location_evidence WHERE service_request_id = ? ORDER BY created_at, id`,
        [serviceRequestId],
      )
      .map(fromRow);
  }

  list(): fieldwork.LocationEvidence[] {
    return this.db
      .all<EvidenceRow>(`SELECT ${COLUMNS} FROM location_evidence ORDER BY created_at, id`)
      .map(fromRow);
  }
}
