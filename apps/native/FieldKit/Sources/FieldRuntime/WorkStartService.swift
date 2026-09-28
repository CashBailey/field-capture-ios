// Port of src/runtime/workStartService.ts — Work-start runtime: records the immutable event that
// lets Hub derive the SR lock.
//
// Mobile only queues evidence; Hub still validates clock-in, actor authorization, assignment drift,
// and whether this is the first accepted work-start event for the SR.
import Foundation
import FieldContracts
import FieldDomain

private let WORK_START_OP: SyncOpType = "work.start"

public enum WorkStartResult {
    case ok(envelope: OperationEnvelope<WorkStartEvent>)
    case locked(reason: String)
    case invalid(errors: [String])
}

public struct WorkStartInput {
    public var serviceRequestId: String
    public var actorRef: String
    public var kind: WorkStartKind?

    public init(serviceRequestId: String, actorRef: String, kind: WorkStartKind? = nil) {
        self.serviceRequestId = serviceRequestId
        self.actorRef = actorRef
        self.kind = kind
    }
}

public struct WorkStartServiceDeps {
    /// The controller's cached clock gate; Hub authoritatively re-validates on sync.
    public var gateState: () -> FieldWorkGate
    /// Enqueue the immutable work-start event in the same durable outbox as DVIR/JHA evidence. A
    /// failed write must propagate; `.ok` means the event is durably queued.
    public var enqueueEvent: (OperationEnvelope<WorkStartEvent>) throws -> Void
    public var identity: WriteIdentity
    public var now: (() -> Date)?

    public init(
        gateState: @escaping () -> FieldWorkGate,
        enqueueEvent: @escaping (OperationEnvelope<WorkStartEvent>) throws -> Void,
        identity: WriteIdentity, now: (() -> Date)? = nil
    ) {
        self.gateState = gateState
        self.enqueueEvent = enqueueEvent
        self.identity = identity
        self.now = now
    }
}

public final class WorkStartService {
    private let deps: WorkStartServiceDeps
    private let now: () -> Date

    public init(_ deps: WorkStartServiceDeps) {
        self.deps = deps
        self.now = deps.now ?? { Date() }
    }

    public func startWork(_ input: WorkStartInput) throws -> WorkStartResult {
        let gate = deps.gateState()
        if case .locked(let reason, _) = gate {
            return .locked(reason: fieldWorkGateLockReason(reason))
        }

        let srId = input.serviceRequestId.trimmingCharacters(in: .whitespacesAndNewlines)
        let actorRef = input.actorRef.trimmingCharacters(in: .whitespacesAndNewlines)
        var errors: [String] = []
        if srId.isEmpty { errors.append("service request is required") }
        if actorRef.isEmpty { errors.append("actor is required") }
        guard errors.isEmpty else { return .invalid(errors: errors) }

        let opId = deps.identity.generateUuid()
        let localSeq = deps.identity.allocateLocalSeq()
        let payload = WorkStartEvent(
            eventId: opId, srId: srId, kind: input.kind ?? .workEventSubmitted, actorRef: actorRef,
            occurredAt: isoStamp(now()))
        let idempotencyKey = try buildIdempotencyKey(deps.identity.deviceInstanceId, localSeq, opId)
        let envelope = OperationEnvelope<WorkStartEvent>(
            opId: opId, kind: .event, type: WORK_START_OP, idempotencyKey: idempotencyKey,
            localSeq: localSeq, dependsOn: [], payload: payload)
        try assertEnvelopeConsistent(envelope)
        try deps.enqueueEvent(envelope)
        return .ok(envelope: envelope)
    }
}
