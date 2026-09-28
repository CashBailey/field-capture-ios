/**
 * Boot-time restart recovery (spec: pending → retry, in-flight → retry, failed → stays failed,
 * accepted → done).
 *
 * An app killed mid-submit leaves durable evidence `in-flight` with the Hub outcome unknown.
 * Re-sending is safe — the SAME idempotency key means Hub dedupes — so those orphans are swept
 * back to `pending` here. Terminal rows (`accepted` / `rejected` / `needs-review`) are never
 * touched, and `pending` rows simply remain queued for the retry engine.
 *
 * MUST run before the retry engine starts and before any submit path executes: a stale
 * in-flight row would otherwise deadlock against the double-submit guard ("already-in-flight")
 * forever. `wireAppRuntime` enforces this ordering.
 */
import { sync } from '@fieldcapture/contracts';

import type { TicketEvidenceStore } from '../domain';

export interface EvidenceRecovery {
  /** Idempotency keys of orphaned in-flight rows returned to pending. */
  recoveredKeys: string[];
}

export function recoverEvidenceOnStartup(
  store: TicketEvidenceStore,
  now: () => Date = () => new Date(),
): EvidenceRecovery {
  const recoveredKeys: string[] = [];
  for (const evidence of store.list()) {
    if (evidence.state !== 'in-flight') continue;
    sync.assertTransition(evidence.state, 'pending');
    const at = now().toISOString();
    store.save({
      ...evidence,
      state: 'pending',
      attempts: evidence.attempts + 1, // the interrupted attempt counts — it may have reached Hub
      updatedAt: at,
      lastTransientReason: 'restart-interrupted',
    });
    recoveredKeys.push(evidence.envelope.idempotencyKey);
  }
  return { recoveredKeys };
}
