function fillRandom(bytes: Uint8Array): Uint8Array {
  const cryptoLike = globalThis.crypto as
    | { getRandomValues?: (array: Uint8Array) => Uint8Array }
    | undefined;
  if (typeof cryptoLike?.getRandomValues === 'function') {
    return cryptoLike.getRandomValues(bytes);
  }
  throw new Error('secure random bytes are unavailable in this runtime');
}

export function randomBytes(length: number): Uint8Array {
  if (!Number.isInteger(length) || length <= 0) {
    throw new Error(`random byte length must be positive (got ${length})`);
  }
  return fillRandom(new Uint8Array(length));
}

export function randomUuid(): string {
  const randomUUID = (globalThis.crypto as { randomUUID?: () => string } | undefined)?.randomUUID;
  if (typeof randomUUID === 'function') return randomUUID();

  const bytes = randomBytes(16);
  bytes[6] = (bytes[6] % 16) + 64;
  bytes[8] = (bytes[8] % 64) + 128;
  const hex = Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join('');
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(
    16,
    20,
  )}-${hex.slice(20)}`;
}
