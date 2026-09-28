// GENERATED from contracts/triad-contract.json — do not edit; run node codegen.mjs (from packages/contracts).
export const CONTRACT_VERSION = "1.0.0" as const;
export const SYNC_OP_TYPES = ["attachment.link", "dvir.submit", "field.note", "jhajsa.submit", "location.evidence", "print.event", "sr.update", "ticket.submit", "work.start"] as const;
export type SyncOpType = (typeof SYNC_OP_TYPES)[number];
export const NFC_AUTH_METHODS = ["desfire_aes128_protected_read"] as const;
