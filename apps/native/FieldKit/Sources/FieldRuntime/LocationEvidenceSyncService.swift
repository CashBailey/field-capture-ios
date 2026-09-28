// Port of src/runtime/locationEvidenceSyncService.ts — Location-evidence sync runtime. The
// location-validation screen owns capture/classification and the durable store owns preservation;
// this service only queues the immutable Hub event owed for a saved evidence row.
import Foundation
import FieldContracts
import FieldDomain

private let LOCATION_EVIDENCE_OP: SyncOpType = "location.evidence"

public enum LocationEvidenceSyncResult {
    case ok(envelope: OperationEnvelope<LocationEvidence>)
    case invalid(errors: [String])
}

public struct LocationEvidenceSyncDeps {
    /// A failed outbox write must propagate; `.ok` means the evidence event is durably queued.
    public var enqueueEvent: (OperationEnvelope<LocationEvidence>) throws -> Void
    public var identity: WriteIdentity

    public init(enqueueEvent: @escaping (OperationEnvelope<LocationEvidence>) throws -> Void, identity: WriteIdentity) {
        self.enqueueEvent = enqueueEvent
        self.identity = identity
    }
}

public final class LocationEvidenceSyncService {
    private let deps: LocationEvidenceSyncDeps

    public init(_ deps: LocationEvidenceSyncDeps) {
        self.deps = deps
    }

    public func enqueue(_ evidence: LocationEvidence) throws -> LocationEvidenceSyncResult {
        var errors: [String] = []
        if evidence.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("location evidence id is required")
        }
        if evidence.serviceRequestId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("service request is required")
        }
        if evidence.evidenceType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("evidence type is required")
        }
        guard errors.isEmpty else { return .invalid(errors: errors) }

        let opId = deps.identity.generateUuid()
        let localSeq = deps.identity.allocateLocalSeq()
        let idempotencyKey = try buildIdempotencyKey(deps.identity.deviceInstanceId, localSeq, opId)
        let envelope = OperationEnvelope<LocationEvidence>(
            opId: opId, kind: .event, type: LOCATION_EVIDENCE_OP, idempotencyKey: idempotencyKey,
            localSeq: localSeq, dependsOn: [], payload: evidence)
        try assertEnvelopeConsistent(envelope)
        try deps.enqueueEvent(envelope)
        return .ok(envelope: envelope)
    }
}
