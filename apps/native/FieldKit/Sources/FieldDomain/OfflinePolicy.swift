// Port of src/domain/offlinePolicy.ts — 24-hour offline policy (spec 7.14 / plan Phase 8) — a PURE
// state machine, no storage or clock.
//
// The clock-in gate (`FieldSession.evaluateClockGate`) decides whether field work is unlocked from
// Hub truth. This policy is the ORTHOGONAL "how long have we been flying blind?" axis: once a
// worker is clocked in, an unreachable Hub WITHIN the window keeps capture/continue-work allowed
// (offline-first), but OVER the window blocks NEW work and labels fresh captures as "offline
// over-limit evidence / requires office review". It never relaxes the clock-in gate, and it must
// be fed a DURABLE last-successful-Hub-contact timestamp so a restart can't reset the clock.

public enum OfflinePolicyState: String, Equatable, Sendable, Codable {
    case online
    case offlineWithinLimit = "offline-within-limit"
    case offlineOverLimit = "offline-over-limit"
}

public struct OfflinePolicyInput {
    /// When the device last had a SUCCESSFUL Hub exchange (session-status or sync push/pull), in
    /// epoch ms. `nil` means no successful contact is on record (fresh install / never reached
    /// the Hub).
    public var lastHubContactAtMs: Int64?
    /// Current time, epoch ms (caller supplies — keeps this pure and testable).
    public var nowMs: Int64
    /// Is the Hub reachable right now? When `true`, the window is irrelevant (state is `.online`).
    public var online: Bool?
    /// Window before offline work is over-limit. Default 24h; Hub may seed a different value.
    public var windowHours: Double?

    public init(lastHubContactAtMs: Int64?, nowMs: Int64, online: Bool? = nil, windowHours: Double? = nil) {
        self.lastHubContactAtMs = lastHubContactAtMs
        self.nowMs = nowMs
        self.online = online
        self.windowHours = windowHours
    }
}

public struct OfflinePolicy: Equatable, Sendable {
    public var state: OfflinePolicyState
    /// ms since the last successful Hub contact (0 when online or never-contacted).
    public var elapsedMs: Int64
    /// ms remaining before crossing the over-limit threshold (0 when over-limit or
    /// never-contacted).
    public var remainingMs: Int64
    /// The resolved window length in ms (for display: "X of 24h remaining").
    public var windowMs: Int64

    public init(state: OfflinePolicyState, elapsedMs: Int64, remainingMs: Int64, windowMs: Int64) {
        self.state = state
        self.elapsedMs = elapsedMs
        self.remainingMs = remainingMs
        self.windowMs = windowMs
    }
}

private let DEFAULT_WINDOW_HOURS = 24.0

/**
 * Evaluate the offline policy. Conservative by construction: an unknown baseline
 * (`lastHubContactAtMs == nil`) while offline is treated as OVER-limit — we never grant the
 * offline grace window without a proven recent Hub contact to start the clock from.
 */
public func evaluateOfflinePolicy(_ input: OfflinePolicyInput) -> OfflinePolicy {
    let windowMs = Int64(max(0, (input.windowHours ?? DEFAULT_WINDOW_HOURS) * 60 * 60 * 1000))

    if input.online == true {
        return OfflinePolicy(state: .online, elapsedMs: 0, remainingMs: windowMs, windowMs: windowMs)
    }
    guard let lastHubContactAtMs = input.lastHubContactAtMs else {
        return OfflinePolicy(state: .offlineOverLimit, elapsedMs: 0, remainingMs: 0, windowMs: windowMs)
    }

    let elapsedMs = max(0, input.nowMs - lastHubContactAtMs)
    let remainingMs = max(0, windowMs - elapsedMs)
    return OfflinePolicy(
        state: elapsedMs >= windowMs ? .offlineOverLimit : .offlineWithinLimit,
        elapsedMs: elapsedMs,
        remainingMs: remainingMs,
        windowMs: windowMs
    )
}

/**
 * May NEW field work begin under this policy? (The clock-in gate is enforced separately and still
 * applies.) Over-limit blocks new work; online and within-limit allow it — offline-first.
 */
public func offlineAllowsNewWork(_ state: OfflinePolicyState) -> Bool {
    state != .offlineOverLimit
}

/// The needs-review sub-reason captures earned while over the offline limit are tagged with, so
/// the office can adjudicate evidence taken with no recent Hub truth. Distinct from
/// snapshot-drift etc.
public let OFFLINE_OVER_LIMIT_REVIEW_REASON = "offline-over-limit-evidence"

// ---- durable persistence (the restart-proof part) ----

/// What survives a restart for the offline policy.
public struct OfflinePolicyPersistedState: Equatable, Sendable {
    /// Durable last-successful-Hub-contact timestamp (epoch ms), or nil if none on record.
    public var lastHubContactAtMs: Int64?
    /// Hub-seeded window in hours, or nil to use the 24h default.
    public var windowHours: Double?

    public init(lastHubContactAtMs: Int64?, windowHours: Double? = nil) {
        self.lastHubContactAtMs = lastHubContactAtMs
        self.windowHours = windowHours
    }
}

/**
 * Durable home for the offline-policy baseline. The contract that makes the 24h window honest:
 * `recordHubContact` is MONOTONIC-FORWARD — it never moves the timestamp backward, so neither a
 * restart nor a clock-skewed earlier value can extend the offline grace window.
 */
public protocol OfflinePolicyStore {
    var durability: StoreDurability { get }
    func getState() -> OfflinePolicyPersistedState
    /// Record a successful Hub contact; ignored if `atMs` is older than what's already stored.
    func recordHubContact(_ atMs: Int64)
    /// Persist a Hub-seeded offline window (hours).
    func setWindowHours(_ hours: Double)
}

/// In-memory test seam — explicitly volatile; never present its contents as "saved on the device".
public final class VolatileOfflinePolicyStore: OfflinePolicyStore {
    public let durability: StoreDurability = .volatileMemory
    private var lastHubContactAtMs: Int64?
    private var windowHours: Double?

    public init() {}

    public func getState() -> OfflinePolicyPersistedState {
        OfflinePolicyPersistedState(lastHubContactAtMs: lastHubContactAtMs, windowHours: windowHours)
    }

    public func recordHubContact(_ atMs: Int64) {
        if lastHubContactAtMs == nil || atMs > lastHubContactAtMs! {
            lastHubContactAtMs = atMs
        }
    }

    public func setWindowHours(_ hours: Double) {
        windowHours = hours
    }
}
