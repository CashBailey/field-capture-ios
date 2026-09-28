// From src/domain/hubGateway.ts — what a store REALLY guarantees, verified at open
// (`PRAGMA cipher_version`); implementations must not claim encryption they cannot verify.
public enum StoreDurability: String, Codable, Sendable {
    case volatileMemory = "volatile-memory"
    case durablePlain = "durable-plain"
    case durableEncrypted = "durable-encrypted"
}
