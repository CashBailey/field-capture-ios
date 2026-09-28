// Port of sync/idempotency.ts — Idempotency key format, consistent with Field Time:
//   gtr:<device_instance_id>:<local_seq>:<op_uuid>
// (ADR 004). device_instance_id and op_uuid may not contain ':'; local_seq is a non-negative
// integer.

public struct IdempotencyKeyError: Error, CustomStringConvertible, Equatable {
    public let message: String
    public var description: String { message }
    public init(_ message: String) { self.message = message }
}

public struct ParsedIdempotencyKey: Equatable, Sendable {
    public var deviceInstanceId: String
    public var localSeq: Int
    public var opUuid: String
}

public func buildIdempotencyKey(_ deviceInstanceId: String, _ localSeq: Int, _ opUuid: String) throws -> String {
    guard !deviceInstanceId.isEmpty, !deviceInstanceId.contains(":") else {
        throw IdempotencyKeyError("deviceInstanceId must be non-empty and contain no ':'")
    }
    guard localSeq >= 0 else {
        throw IdempotencyKeyError("localSeq must be a non-negative integer")
    }
    guard !opUuid.isEmpty, !opUuid.contains(":") else {
        throw IdempotencyKeyError("opUuid must be non-empty and contain no ':'")
    }
    return "gtr:\(deviceInstanceId):\(localSeq):\(opUuid)"
}

public func parseIdempotencyKey(_ key: String) throws -> ParsedIdempotencyKey {
    let parts = key.components(separatedBy: ":")
    guard parts.count == 4, parts[0] == "gtr" else {
        throw IdempotencyKeyError("malformed idempotency key: \(key)")
    }
    let deviceInstanceId = parts[1]
    let opUuid = parts[3]
    guard let localSeq = Int(parts[2]), localSeq >= 0 else {
        throw IdempotencyKeyError("bad local_seq in key: \(key)")
    }
    guard !deviceInstanceId.isEmpty, !opUuid.isEmpty else {
        throw IdempotencyKeyError("empty segment in key: \(key)")
    }
    return ParsedIdempotencyKey(deviceInstanceId: deviceInstanceId, localSeq: localSeq, opUuid: opUuid)
}
