// Port of src/domain/fieldSession.ts — Clock gate + assignment pull (first real OpsHub
// integration slice).
//
// The TimeClock clock-in, surfaced through Hub, gates field work: the app may always OPEN, but
// field steps/actions are non-actionable until Hub confirms an open punch. This gating is
// advisory UX only — Hub's submit guard remains the authority and re-checks clock-in on every
// submission (docs/integration/ops-triad-contract.md).

/// Whether field work is actionable. Locked is the safe default: an unreachable Hub or a failed
/// auth NEVER unlocks field work (we refuse to assume a clock-in we cannot verify), but it also
/// never crashes the app shell — the reason is surfaced to the user instead.
public enum FieldWorkGate: Equatable, Sendable {
    public enum LockedReason: String, Equatable, Sendable {
        case notClockedIn = "not-clocked-in"
        case hubUnreachable = "hub-unreachable"
        case authFailed = "auth-failed"
        case badHubResponse = "bad-hub-response"
        case offlineOverLimit = "offline-over-limit"
    }

    // ponytail: enum cases cannot carry default associated-value arguments, so every construction
    // site passes `detail`/`employeeId` explicitly (nil where the TS object literal omits them).
    case locked(reason: LockedReason, detail: String?)
    case unlocked(clockedInSince: String?, source: String?, employeeId: String?)
}

/**
 * Apply the 24h offline grace window without relaxing the Hub clock-in rule.
 *
 * A Hub-unreachable refresh can keep field work actionable only when this app session already had
 * a Hub-proven unlocked gate and the durable last-Hub-contact timestamp is still within the
 * offline window. A cold offline startup, signed-out state, or expired over-limit window stays
 * locked — we never invent a clock-in from a timestamp alone.
 */
public func applyOfflinePolicyToGate(
    previousGate: FieldWorkGate,
    nextGate: FieldWorkGate,
    offlinePolicy: OfflinePolicy? = nil
) -> FieldWorkGate {
    guard case .locked(let reason, _) = nextGate else { return nextGate }
    guard reason == .hubUnreachable else { return nextGate }
    guard case .unlocked = previousGate else { return nextGate }
    if offlinePolicy?.state == .offlineWithinLimit { return previousGate }
    if offlinePolicy?.state == .offlineOverLimit {
        return .locked(reason: .offlineOverLimit, detail: OFFLINE_OVER_LIMIT_REVIEW_REASON)
    }
    return nextGate
}

/// Driver-facing lock reason for UI/runtime messages; stable codes stay internal.
public func fieldWorkGateLockReason(_ reason: FieldWorkGate.LockedReason) -> String {
    if reason == .offlineOverLimit {
        return "offline over limit — reconnect to Ops Hub before starting new work"
    }
    return reason.rawValue
}

/**
 * Ask Hub for the driver's clock state and map it to a gate. Every Hub-side failure (offline,
 * auth, 5xx, malformed body, missing field) resolves to a LOCKED gate — anything other than an
 * explicit `clockedIn == true` locks field work. Only non-Hub errors (client bugs) propagate.
 */
public func evaluateClockGate(_ source: SessionStatusSource) async throws -> FieldWorkGate {
    let status: HubSessionStatus
    do {
        status = try await source.getSessionStatus()
    } catch let error as HubNetworkError {
        return .locked(reason: .hubUnreachable, detail: error.message)
    } catch let error as HubAuthError {
        return .locked(reason: .authFailed, detail: error.message)
    } catch let error as HubResponseError {
        // Hub answered garbage (5xx, non-JSON, missing clocked_in). Never guess a clock state
        // from it — lock, and surface what Hub actually said.
        return .locked(reason: .badHubResponse, detail: error.message)
    }
    // client-side programming errors propagate (not caught above) — must fail loud, never
    // masquerade as a lock.
    if !status.clockedIn {
        return .locked(reason: .notClockedIn, detail: nil)
    }
    return .unlocked(clockedInSince: status.clockedInSince, source: status.source, employeeId: status.employeeId)
}

// ---- assignment cache ----

/// Where pulled assignments (frozen SR snapshots + hashes) are kept between pulls. Implementations
/// MUST declare their real durability; this slice ships only the volatile in-memory stub below.
public protocol AssignmentStore {
    var durability: StoreDurability { get }
    /// Replace the cached set with Hub's latest answer (Hub is the authority on assignment).
    func putAssignments(_ assignments: [HubAssignment])
    func listAssignments() -> [HubAssignment]
    func getSnapshotHash(_ serviceRequestId: String) -> String?
}

/// In-memory assignment cache. VOLATILE: lost on app restart. TEST SEAM ONLY — production uses
/// FieldData's durable SQLite assignment store (SQLCipher in real builds). Do not present its
/// contents as "saved on the device".
public final class VolatileAssignmentStore: AssignmentStore {
    public let durability: StoreDurability = .volatileMemory
    private var assignments: [HubAssignment] = []

    public init() {}

    public func putAssignments(_ assignments: [HubAssignment]) {
        self.assignments = assignments
    }

    public func listAssignments() -> [HubAssignment] {
        assignments
    }

    public func getSnapshotHash(_ serviceRequestId: String) -> String? {
        assignments.first { $0.serviceRequestId == serviceRequestId }?.snapshotHash
    }
}

// ---- session refresh (gate, then pull) ----

public enum AssignmentRefresh: Equatable, Sendable {
    case synced(count: Int)
    /// The gate is locked; the pull is never attempted (TS's fixed `reason: 'locked'` literal).
    case notPulled
    /// The gate is open but the pull failed; any previously-cached assignments are kept.
    case unavailable(reason: String)
}

public struct FieldSessionResult {
    public var gate: FieldWorkGate
    public var assignments: AssignmentRefresh

    public init(gate: FieldWorkGate, assignments: AssignmentRefresh) {
        self.gate = gate
        self.assignments = assignments
    }
}

/**
 * One refresh cycle: evaluate the clock gate; only if unlocked, pull assignments and retain the
 * snapshots + hashes. A failed pull never wipes the existing cache and never unlocks anything.
 */
public func refreshFieldSession(
    statusSource: SessionStatusSource,
    assignmentSource: AssignmentSource,
    store: AssignmentStore
) async throws -> FieldSessionResult {
    let gate = try await evaluateClockGate(statusSource)
    guard case .unlocked = gate else {
        return FieldSessionResult(gate: gate, assignments: .notPulled)
    }
    do {
        let assignments = try await assignmentSource.getAssignments()
        store.putAssignments(assignments)
        return FieldSessionResult(gate: gate, assignments: .synced(count: assignments.count))
    } catch let error as HubNetworkError {
        return FieldSessionResult(gate: gate, assignments: .unavailable(reason: error.message))
    } catch let error as HubAuthError {
        return FieldSessionResult(gate: gate, assignments: .unavailable(reason: error.message))
    } catch let error as HubResponseError {
        return FieldSessionResult(gate: gate, assignments: .unavailable(reason: error.message))
    }
}
