// Port of src/_generated.ts — GENERATED from contracts/triad-contract.json; do not edit; run
// node codegen.mjs (from packages/contracts).

public let CONTRACT_VERSION = "1.0.0"

public let SYNC_OP_TYPES: [String] = [
    "attachment.link", "dvir.submit", "field.note", "jhajsa.submit", "location.evidence",
    "print.event", "sr.update", "ticket.submit", "work.start",
]

/// String-literal union of `SYNC_OP_TYPES` members (mirrors the TS `(typeof SYNC_OP_TYPES)[number]`).
/// Kept as a plain `String` rather than an enum: nothing in the contracts module discriminates on
/// this type, so an enum would be unused ceremony (ponytail: YAGNI).
public typealias SyncOpType = String

public let NFC_AUTH_METHODS: [String] = ["desfire_aes128_protected_read"]
