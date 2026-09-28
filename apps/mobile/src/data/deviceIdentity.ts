/**
 * Durable write identity: the per-install `device_instance_id` and the monotonic `local_seq`
 * allocator behind every idempotency key (`gtr:<device>:<seq>:<uuid>`, ADR 004).
 *
 * Both MUST be durable: a device id that changes on restart breaks Hub-side dedupe history, and
 * a reused local_seq mints an idempotency key that collides with a different operation — Hub
 * would then 422 it as an idempotency mismatch. The allocator increments inside a transaction so
 * two callers can never be handed the same sequence number.
 */
import type { SqlDriver } from './sqlDriver';

export class DeviceIdentity {
  constructor(private readonly db: SqlDriver) {}

  /**
   * The stable per-install device id, creating it on first run. `generateUuid` is injected
   * (secure native random in production) — it is used ONCE per install.
   */
  ensureDeviceInstanceId(generateUuid: () => string): string {
    return this.db.transaction(() => {
      const row = this.db.first<{ device_instance_id: string }>(
        'SELECT device_instance_id FROM device_identity WHERE id = 1',
      );
      if (row !== null) return row.device_instance_id;
      const id = generateUuid();
      if (!id || id.includes(':')) {
        throw new Error(`generated device id is unusable in an idempotency key: "${id}"`);
      }
      this.db.run(
        'INSERT INTO device_identity (id, device_instance_id, next_local_seq) VALUES (1, ?, 0)',
        [id],
      );
      return id;
    });
  }

  /** Allocate the next local_seq (monotonic, never reused, durable before it is returned). */
  allocateLocalSeq(): number {
    return this.db.transaction(() => {
      const row = this.db.first<{ next_local_seq: number }>(
        'SELECT next_local_seq FROM device_identity WHERE id = 1',
      );
      if (row === null) {
        throw new Error('device identity not initialized — call ensureDeviceInstanceId first');
      }
      this.db.run('UPDATE device_identity SET next_local_seq = ? WHERE id = 1', [
        row.next_local_seq + 1,
      ]);
      return row.next_local_seq;
    });
  }
}
