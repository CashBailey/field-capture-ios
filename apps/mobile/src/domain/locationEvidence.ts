/**
 * Durable home for validation-only location evidence (Phase 7). Append-only and NON-EVICTABLE:
 * location evidence is unsynced field work — it is preserved until the Hub acks it, never auto-
 * deleted (cross-cutting invariant). The single-shot native GPS capture and the sync-wire
 * shape are device-/Hub-gated; this store + the contract model are the pure, durable foundation.
 */
import type { fieldwork } from '@fieldcapture/contracts';

import type { StoreDurability } from './hubGateway';

export interface LocationEvidenceStore {
  readonly durability: StoreDurability;
  /** Append a location-evidence record (append-only; never overwritten away as unsynced work). */
  record(evidence: fieldwork.LocationEvidence): void;
  get(id: string): fieldwork.LocationEvidence | undefined;
  listByServiceRequest(serviceRequestId: string): fieldwork.LocationEvidence[];
  list(): fieldwork.LocationEvidence[];
}

/** In-memory test seam — explicitly volatile. */
export class VolatileLocationEvidenceStore implements LocationEvidenceStore {
  readonly durability = 'volatile-memory' as const;
  private readonly rows = new Map<string, fieldwork.LocationEvidence>();

  record(evidence: fieldwork.LocationEvidence): void {
    if (this.rows.has(evidence.id)) {
      throw new Error(`location evidence ${evidence.id} already exists`);
    }
    this.rows.set(evidence.id, { ...evidence });
  }
  get(id: string): fieldwork.LocationEvidence | undefined {
    const row = this.rows.get(id);
    return row === undefined ? undefined : { ...row };
  }
  listByServiceRequest(serviceRequestId: string): fieldwork.LocationEvidence[] {
    return this.list().filter((e) => e.serviceRequestId === serviceRequestId);
  }
  list(): fieldwork.LocationEvidence[] {
    return [...this.rows.values()].map((row) => ({ ...row }));
  }
}
