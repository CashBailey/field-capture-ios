// Port of src/runtime/fieldWorkflowService.ts — DVIR / JHA-JSA field-workflow runtime — the
// screen-level state machine behind the safety-form flow (field-day-workflow.md: pre-trip DVIR →
// per-SR JHA → tickets → post-trip DVIR).
//
// Invariants:
//  - Field actions are LOCKED unless the Hub clock gate is unlocked (`gateState` is the
//    controller's cached gate). Locked = non-actionable, with the reason surfaced; the gate is
//    UX-level — Hub still authoritatively re-validates every submit.
//  - Completed forms sync as APPEND-ONLY evidence events through the durable sync outbox
//    (`SyncEngine.enqueue` — same idempotency/retry/backoff rules as everything else; nothing here
//    is durable until Hub accepts).
//  - Once enqueued, a form is FROZEN: append-only evidence is never edited. A needs-review or
//    rejected outcome preserves the record and Hub's verbatim reason — never deleted, never
//    silently retried.
//  - Ticket submission is gated on Hub-configured required steps (`checkTicketSubmitAllowed`); a
//    flagged (needs-review/rejected) safety form does NOT satisfy its step, and evidence from an
//    earlier clock session never unlocks or blocks the current one.
//
// ponytail: the TS `enqueueEvidence` takes `sync.OperationEnvelope` (payload defaults to `unknown`
// — TS's structural typing lets the concrete `FieldForm` flow through untouched). Swift has no
// generic covariance, so this seam is typed at the concrete payload it actually produces
// (`OperationEnvelope<FieldForm>`) instead of forcing a `JSONValue` re-encode nothing in this file
// (or its tests) ever needs — the composition root wires the real bridge to `SyncEngine.enqueue`
// later, exactly as it must already do for `UploadEngine`'s `enqueueLink`.
import Foundation
import FieldContracts
import FieldDomain

private let JHA_JSA_OP: SyncOpType = "jhajsa.submit"
private let DVIR_OP: SyncOpType = "dvir.submit"

public enum WorkflowActionResult<T> {
    case ok(T)
    case locked(reason: String)
    case invalid(errors: [String])
    case notFound(formId: String)
    case frozen(formId: String, recordStatus: FieldFormStatus)
}

public enum FieldWorkflowStorageOperation: String, Equatable, Sendable {
    case loadForm = "load-form"
    case saveDraft = "save-draft"
    case completeForm = "complete-form"
    case submitForm = "submit-form"
    case listEnqueuedForms = "list-enqueued-forms"
    case readOutboxOutcome = "read-outbox-outcome"
    case reconcileForm = "reconcile-form"
    case listCompletedSteps = "list-completed-steps"
}

/// Retryable infrastructure failures are errors, not form-validation results. Callers can show
/// these details without treating an unavailable database as a missing or invalid safety form.
public enum FieldWorkflowError: Error, Equatable, Sendable, CustomStringConvertible, LocalizedError {
    case storage(
        operation: FieldWorkflowStorageOperation,
        formId: String?,
        detail: String
    )
    case evidenceEnqueue(formId: String, detail: String)
    case writeIdentity(formId: String, detail: String)

    public var description: String {
        switch self {
        case .storage(let operation, let formId, let detail):
            let target = formId.map { " for \($0)" } ?? ""
            return "field workflow \(operation.rawValue) failed\(target): \(detail)"
        case .evidenceEnqueue(let formId, let detail):
            return "failed to enqueue form \(formId): \(detail)"
        case .writeIdentity(let formId, let detail):
            return "failed to build write identity for form \(formId): \(detail)"
        }
    }

    public var errorDescription: String? { description }
}

/// Statuses that satisfy a required workflow step. Flagged evidence never greenlights work.
private let STEP_SATISFYING: Set<FieldFormStatus> = [.completed, .enqueued, .accepted]

/// Statuses whose payload is frozen append-only evidence.
private let FROZEN: Set<FieldFormStatus> = [.enqueued, .accepted, .needsReview, .rejected]

/// Outcome of an outbox row backing an enqueued form (mirrors the TS inline type).
public struct FieldWorkflowOutboxItem {
    public var state: OutboxItemState
    public var rejectionCode: String?
    public var lastError: String?
    public init(state: OutboxItemState, rejectionCode: String? = nil, lastError: String? = nil) {
        self.state = state
        self.rejectionCode = rejectionCode
        self.lastError = lastError
    }
}

public struct FieldWorkflowDeps {
    public var forms: FieldFormStore
    /// The controller's cached clock gate — refreshed elsewhere; consulted on every action.
    public var gateState: () -> FieldWorkGate
    /// Enqueue an evidence event into the durable sync outbox (SyncEngine.enqueue). A failed
    /// durable write must propagate so the form remains completed and retryable.
    public var enqueueEvidence: (OperationEnvelope<FieldForm>) throws -> Void
    /// Outbox row for a previously enqueued op (SyncOutboxStore.get).
    public var outboxItem: (String) throws -> FieldWorkflowOutboxItem?
    /// Hub-configured workflow requirements (parsed from session/assignment config).
    public var requirements: () -> WorkflowRequirements
    public var identity: WriteIdentity
    public var now: (() -> Date)?

    public init(
        forms: FieldFormStore, gateState: @escaping () -> FieldWorkGate,
        enqueueEvidence: @escaping (OperationEnvelope<FieldForm>) throws -> Void,
        outboxItem: @escaping (String) throws -> FieldWorkflowOutboxItem?,
        requirements: @escaping () -> WorkflowRequirements, identity: WriteIdentity,
        now: (() -> Date)? = nil
    ) {
        self.forms = forms
        self.gateState = gateState
        self.enqueueEvidence = enqueueEvidence
        self.outboxItem = outboxItem
        self.requirements = requirements
        self.identity = identity
        self.now = now
    }
}

public enum TicketSubmitGuard: Equatable {
    case allowed
    case locked(reason: String)
    case vehicleUnsafe(reviewRequired: Bool)
    case blocked(missing: [FieldFormKind])
}

public enum SubmitTicketWithWorkflowResult<T> {
    case submitted(result: T)
    case locked(reason: String)
    case vehicleUnsafe(reviewRequired: Bool)
    case blocked(missing: [FieldFormKind])
}

public struct ReconcileOutcomesResult {
    public var accepted: [String]
    public var needsReview: [String]
    public var rejected: [String]
}

private extension FieldForm {
    var isJhaJsa: Bool {
        if case .jha = self { return true }
        return false
    }

    var completedAt: String? {
        switch self {
        case .dvir(let dvir): return dvir.completedAt
        case .jha(let jha): return jha.completedAt
        }
    }

    func withCompletedAt(_ at: String) -> FieldForm {
        switch self {
        case .dvir(var dvir):
            dvir.completedAt = at
            return .dvir(dvir)
        case .jha(var jha):
            jha.completedAt = at
            return .jha(jha)
        }
    }
}

public final class FieldWorkflowService {
    private let deps: FieldWorkflowDeps
    private let now: () -> Date

    public init(_ deps: FieldWorkflowDeps) {
        self.deps = deps
        self.now = deps.now ?? { Date() }
    }

    private func lockedReason() -> String? {
        guard case .locked(let reason, _) = deps.gateState() else { return nil }
        return fieldWorkGateLockReason(reason)
    }

    private func form(
        _ formId: String,
        operation: FieldWorkflowStorageOperation = .loadForm
    ) throws -> FieldFormRecord? {
        do {
            return try deps.forms.get(formId)
        } catch {
            throw FieldWorkflowError.storage(
                operation: operation, formId: formId, detail: String(describing: error))
        }
    }

    private func save(
        _ record: FieldFormRecord,
        operation: FieldWorkflowStorageOperation
    ) throws {
        do {
            try deps.forms.save(record)
        } catch {
            throw FieldWorkflowError.storage(
                operation: operation, formId: record.form.formId,
                detail: String(describing: error))
        }
    }

    /// Earliest completion time that belongs to the active clock session. Hub's timestamp is
    /// authoritative when present. A missing timestamp falls back to the start of the device's
    /// current calendar day; a malformed timestamp fails closed rather than admitting historical
    /// evidence.
    private func currentSessionStartedAt() -> Date? {
        guard case .unlocked(let clockedInSince, _, _) = deps.gateState() else { return nil }
        guard let clockedInSince else {
            return Calendar.current.startOfDay(for: now())
        }
        return parseIso8601(clockedInSince)
    }

    /// Create or update a form draft. Editable only while the record is still local (draft /
    /// completed-not-yet-enqueued); a frozen record refuses with its status.
    public func saveDraft(_ form: FieldForm) throws -> WorkflowActionResult<FieldFormRecord> {
        if let reason = lockedReason() { return .locked(reason: reason) }
        let existing = try self.form(form.formId, operation: .saveDraft)
        if let existing, FROZEN.contains(existing.status) {
            return .frozen(formId: form.formId, recordStatus: existing.status)
        }
        let at = isoStamp(now())
        let record = FieldFormRecord(form: form, status: .draft, createdAt: existing?.createdAt ?? at, updatedAt: at)
        try save(record, operation: .saveDraft)
        return .ok(record)
    }

    /// Validate and mark a draft complete (contracts `validateFormCompletion`).
    public func completeForm(_ formId: String) throws -> WorkflowActionResult<FieldFormRecord> {
        if let reason = lockedReason() { return .locked(reason: reason) }
        guard let existing = try form(formId, operation: .completeForm) else {
            return .notFound(formId: formId)
        }
        if FROZEN.contains(existing.status) {
            return .frozen(formId: formId, recordStatus: existing.status)
        }
        let errors = validateFormCompletion(existing.form)
        guard errors.isEmpty else { return .invalid(errors: errors) }
        let at = isoStamp(now())
        var record = existing
        record.form = existing.form.withCompletedAt(at)
        record.status = .completed
        record.updatedAt = at
        try save(record, operation: .completeForm)
        return .ok(record)
    }

    /// Hand a completed form to the sync outbox as an append-only evidence event. The enqueue is
    /// LOCAL (works offline); durability comes only from Hub's later accept. Idempotent: an
    /// already-enqueued form returns frozen rather than minting a second operation.
    public func submitForm(_ formId: String) throws -> WorkflowActionResult<FieldFormRecord> {
        if let reason = lockedReason() { return .locked(reason: reason) }
        guard let existing = try form(formId, operation: .submitForm) else {
            return .notFound(formId: formId)
        }
        if FROZEN.contains(existing.status) {
            return .frozen(formId: formId, recordStatus: existing.status)
        }
        guard existing.status == .completed else {
            return .invalid(errors: ["form \(formId) is not completed (\(existing.status.rawValue))"])
        }
        let opId = deps.identity.generateUuid()
        let localSeq = deps.identity.allocateLocalSeq()
        let idempotencyKey: String
        do {
            idempotencyKey = try buildIdempotencyKey(
                deps.identity.deviceInstanceId, localSeq, opId)
        } catch {
            throw FieldWorkflowError.writeIdentity(
                formId: formId, detail: String(describing: error))
        }
        let envelope = OperationEnvelope<FieldForm>(
            opId: opId, kind: .event, type: existing.form.isJhaJsa ? JHA_JSA_OP : DVIR_OP,
            idempotencyKey: idempotencyKey, localSeq: localSeq, dependsOn: [], payload: existing.form)
        let at = isoStamp(now())
        var record = existing
        record.status = .enqueued
        record.opId = opId
        record.updatedAt = at
        do {
            try deps.forms.transaction {
                do {
                    try deps.enqueueEvidence(envelope)
                } catch {
                    throw FieldWorkflowError.evidenceEnqueue(
                        formId: formId, detail: String(describing: error))
                }
                try save(record, operation: .submitForm)
            }
        } catch let error as FieldWorkflowError {
            throw error
        } catch {
            throw FieldWorkflowError.storage(
                operation: .submitForm, formId: formId,
                detail: String(describing: error))
        }
        return .ok(record)
    }

    /// Fold Hub outcomes from the sync outbox back onto form records. Accepted = durable;
    /// needs-review / rejected = preserved + frozen with Hub's verbatim reason.
    public func reconcileOutcomes() throws -> ReconcileOutcomesResult {
        var result = ReconcileOutcomesResult(accepted: [], needsReview: [], rejected: [])
        let enqueued: [FieldFormRecord]
        do {
            enqueued = try deps.forms.listByStatus(.enqueued)
        } catch {
            throw FieldWorkflowError.storage(
                operation: .listEnqueuedForms, formId: nil,
                detail: String(describing: error))
        }
        for record in enqueued {
            guard let opId = record.opId else { continue }
            let op: FieldWorkflowOutboxItem?
            do {
                op = try deps.outboxItem(opId)
            } catch {
                throw FieldWorkflowError.storage(
                    operation: .readOutboxOutcome, formId: record.form.formId,
                    detail: String(describing: error))
            }
            guard let op else { continue }
            let at = isoStamp(now())
            var next = record
            switch op.state {
            case .accepted:
                next.status = .accepted
                next.updatedAt = at
                try save(next, operation: .reconcileForm)
                result.accepted.append(record.form.formId)
            case .needsReview:
                next.status = .needsReview
                next.updatedAt = at
                if let lastError = op.lastError { next.lastError = lastError }
                try save(next, operation: .reconcileForm)
                result.needsReview.append(record.form.formId)
            case .rejected:
                next.status = .rejected
                next.updatedAt = at
                next.lastError = op.rejectionCode ?? op.lastError ?? "rejected"
                try save(next, operation: .reconcileForm)
                result.rejected.append(record.form.formId)
            case .pending, .inFlight:
                break  // still owed to Hub — leave enqueued
            }
        }
        return result
    }

    /// Compatibility projection across every vehicle. New production ticket flows should call
    /// `completedSteps(vehicleRef:)` so one truck's inspection cannot affect another truck.
    public func completedSteps() throws -> CompletedWorkflowSteps {
        try completedSteps(matchingVehicleRef: nil)
    }

    /// Completed steps for one exact vehicle reference in the current clock session. JHA remains
    /// keyed by service request; only pre-trip completion and safety are vehicle-scoped.
    public func completedSteps(vehicleRef: String) throws -> CompletedWorkflowSteps {
        try completedSteps(matchingVehicleRef: vehicleRef)
    }

    private func completedSteps(matchingVehicleRef vehicleRef: String?) throws -> CompletedWorkflowSteps {
        var preTripDvirFormId: String?
        var preTripVehicleUnsafe = false
        var latestMatchingPreTrip: (completedAt: Date, formId: String, unsafe: Bool)?
        var jhaFormIdByServiceRequest: [String: String] = [:]
        guard let sessionStartedAt = currentSessionStartedAt() else {
            return CompletedWorkflowSteps(jhaFormIdByServiceRequest: [:])
        }
        let records: [FieldFormRecord]
        do {
            records = try deps.forms.list()
        } catch {
            throw FieldWorkflowError.storage(
                operation: .listCompletedSteps, formId: nil,
                detail: String(describing: error))
        }
        for record in records {
            guard STEP_SATISFYING.contains(record.status) else { continue }
            guard let completedAt = record.form.completedAt,
                let completedDate = parseIso8601(completedAt),
                completedDate >= sessionStartedAt,
                completedDate <= now()
            else { continue }
            switch record.form {
            case .dvir(let dvir) where dvir.kind == .preTripDvir:
                let unsafe = dvirCertifiesUnsafe(dvir)
                if let vehicleRef {
                    if dvir.vehicleRef == vehicleRef {
                        if let latest = latestMatchingPreTrip {
                            if completedDate > latest.completedAt {
                                latestMatchingPreTrip = (completedDate, dvir.formId, unsafe)
                            } else if completedDate == latest.completedAt {
                                // Equal timestamps are uncommon but possible at whole-second
                                // precision. Preserve the most conservative safety answer
                                // deterministically.
                                latestMatchingPreTrip = (
                                    completedDate,
                                    max(latest.formId, dvir.formId),
                                    latest.unsafe || unsafe
                                )
                            }
                        } else {
                            latestMatchingPreTrip = (completedDate, dvir.formId, unsafe)
                        }
                    }
                } else {
                    // Compatibility behavior: any current-session pre-trip satisfies the legacy
                    // projection, and any unsafe vehicle keeps its original global hard gate.
                    preTripDvirFormId = dvir.formId
                    if unsafe { preTripVehicleUnsafe = true }
                }
            case .jha(let jha):
                jhaFormIdByServiceRequest[jha.serviceRequestId] = jha.formId
            default:
                break
            }
        }
        if let latestMatchingPreTrip {
            preTripDvirFormId = latestMatchingPreTrip.formId
            preTripVehicleUnsafe = latestMatchingPreTrip.unsafe
        }
        return CompletedWorkflowSteps(
            preTripDvirFormId: preTripDvirFormId,
            preTripVehicleUnsafe: preTripVehicleUnsafe ? true : nil,
            jhaFormIdByServiceRequest: jhaFormIdByServiceRequest)
    }

    /// May a field ticket for this SR be submitted right now? Clock gate, unsafe-vehicle rule, then
    /// the Hub-configured required workflow steps.
    public func guardTicketSubmit(_ serviceRequestId: String) throws -> TicketSubmitGuard {
        if let reason = lockedReason() { return .locked(reason: reason) }
        let completed = try completedSteps()
        return ticketSubmitGuard(serviceRequestId, completed: completed)
    }

    /// Vehicle-aware production guard. A matching current-session pre-trip is a hard prerequisite
    /// even when cached Hub requirements omit it: absence must never be interpreted as "safe."
    public func guardTicketSubmit(
        _ serviceRequestId: String,
        vehicleRef: String
    ) throws -> TicketSubmitGuard {
        if let reason = lockedReason() { return .locked(reason: reason) }
        let completed = try completedSteps(vehicleRef: vehicleRef)
        guard completed.preTripDvirFormId != nil else {
            return .blocked(missing: [.preTripDvir])
        }
        return ticketSubmitGuard(serviceRequestId, completed: completed)
    }

    private func ticketSubmitGuard(
        _ serviceRequestId: String,
        completed: CompletedWorkflowSteps
    ) -> TicketSubmitGuard {
        // Hard safety gate: a pre-trip DVIR that certified the vehicle unsafe blocks field work for
        // the day and escalates to Hub review — independent of, and ahead of, the Hub-step gate.
        let safety = checkVehicleSafeToOperate(completed)
        if case .unsafe(_, let reviewRequired) = safety {
            return .vehicleUnsafe(reviewRequired: reviewRequired)
        }
        switch checkTicketSubmitAllowed(deps.requirements(), completed, serviceRequestId) {
        case .allowed: return .allowed
        case .blocked(let missing): return .blocked(missing: missing)
        }
    }

    /// Submit handoff: enforce the workflow gate, then delegate to the existing ticket submit path
    /// (AppController.submitNewTicket / submitFieldTicket — idempotency and retry rules untouched).
    public func submitTicketWithWorkflow<T>(
        _ serviceRequestId: String, _ submit: () async throws -> T
    ) async throws -> SubmitTicketWithWorkflowResult<T> {
        switch try guardTicketSubmit(serviceRequestId) {
        case .allowed:
            return .submitted(result: try await submit())
        case .locked(let reason):
            return .locked(reason: reason)
        case .vehicleUnsafe(let reviewRequired):
            return .vehicleUnsafe(reviewRequired: reviewRequired)
        case .blocked(let missing):
            return .blocked(missing: missing)
        }
    }

    /// Vehicle-aware production handoff. This is intentionally an overload so legacy callers keep
    /// their original cross-vehicle behavior until they can supply the assignment's vehicle ref.
    public func submitTicketWithWorkflow<T>(
        _ serviceRequestId: String,
        vehicleRef: String,
        _ submit: () async throws -> T
    ) async throws -> SubmitTicketWithWorkflowResult<T> {
        switch try guardTicketSubmit(serviceRequestId, vehicleRef: vehicleRef) {
        case .allowed:
            return .submitted(result: try await submit())
        case .locked(let reason):
            return .locked(reason: reason)
        case .vehicleUnsafe(let reviewRequired):
            return .vehicleUnsafe(reviewRequired: reviewRequired)
        case .blocked(let missing):
            return .blocked(missing: missing)
        }
    }
}

/// Parse the two ISO-8601 shapes emitted by the app and Hub. Invalid evidence timestamps fail
/// closed in `completedSteps()` and never satisfy a safety gate.
private func parseIso8601(_ value: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: value) { return date }

    let wholeSeconds = ISO8601DateFormatter()
    wholeSeconds.formatOptions = [.withInternetDateTime]
    return wholeSeconds.date(from: value)
}

private extension FieldForm {
    var formId: String {
        switch self {
        case .dvir(let dvir): return dvir.formId
        case .jha(let jha): return jha.formId
        }
    }
}
