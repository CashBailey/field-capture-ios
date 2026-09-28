/**
 * Idempotency key format, consistent with Field Time:
 *   gtr:<device_instance_id>:<local_seq>:<op_uuid>
 * (ADR 004). device_instance_id and op_uuid may not contain ':'; local_seq is a non-negative
 * integer.
 */

export class IdempotencyKeyError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "IdempotencyKeyError";
  }
}

export interface ParsedIdempotencyKey {
  deviceInstanceId: string;
  localSeq: number;
  opUuid: string;
}

export function buildIdempotencyKey(
  deviceInstanceId: string,
  localSeq: number,
  opUuid: string,
): string {
  if (!deviceInstanceId || deviceInstanceId.includes(":")) {
    throw new IdempotencyKeyError("deviceInstanceId must be non-empty and contain no ':'");
  }
  if (!Number.isInteger(localSeq) || localSeq < 0) {
    throw new IdempotencyKeyError("localSeq must be a non-negative integer");
  }
  if (!opUuid || opUuid.includes(":")) {
    throw new IdempotencyKeyError("opUuid must be non-empty and contain no ':'");
  }
  return `gtr:${deviceInstanceId}:${localSeq}:${opUuid}`;
}

export function parseIdempotencyKey(key: string): ParsedIdempotencyKey {
  const parts = key.split(":");
  if (parts.length !== 4 || parts[0] !== "gtr") {
    throw new IdempotencyKeyError(`malformed idempotency key: ${key}`);
  }
  const [, deviceInstanceId, localSeqRaw, opUuid] = parts as [string, string, string, string];
  const localSeq = Number(localSeqRaw);
  if (!Number.isInteger(localSeq) || localSeq < 0) {
    throw new IdempotencyKeyError(`bad local_seq in key: ${key}`);
  }
  if (!deviceInstanceId || !opUuid) {
    throw new IdempotencyKeyError(`empty segment in key: ${key}`);
  }
  return { deviceInstanceId, localSeq, opUuid };
}
