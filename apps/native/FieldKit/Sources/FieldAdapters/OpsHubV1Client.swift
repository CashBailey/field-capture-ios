// Port of adapters/sync/OpsHubV1Client.ts — Real Ops Hub v1 client (first real integration
// slice). Implements the domain gateway interfaces over the Hub's minimal mobile routes:
//
//   GET  /api/v1/sync/session-status
//   GET  /api/v1/sync/assignments
//   POST /api/v1/sync/submit
//
// This is deliberately NOT the ADR 004 `SyncTransport` engine (`/sync/commands`, `/sync/changes`,
// tus uploads) — that protocol is the real `OpsHubSyncTransport`, which lives beside this V1
// client. Wire contract: docs/integration/ops-triad-contract.md.
//
// Mapping discipline (cross-cutting invariant #2):
//  - Reads throw typed errors (`HubNetworkError` / `HubAuthError` / `HubResponseError`) — the
//    caller locks field work visibly instead of assuming a clock-in or inventing assignments.
//  - Submit NEVER throws for an expected condition; it returns a `HubSubmitOutcome` so every arm
//    (accepted / rejected / auth / transient) is handled and rejection detail is never lost.
//  - Only an explicit `accepted: true` body makes a submit "accepted". A 2xx with anything else
//    (captive portal, proxy garbage) is `.transient`, not success.
//
// Deviation from the TS: the TS constructor takes a shared `HubRuntimeConfig` (from
// `src/config/hubConfig.ts`, ported to `FieldRuntime`). `FieldAdapters` sits BELOW `FieldRuntime`
// in the Swift package graph (`FieldRuntime` depends on `FieldAdapters`, never the reverse), so
// this client cannot import that type — it takes `baseUrl`/`sessionToken` directly instead. Callers
// in `FieldRuntime` pass `config.baseUrl, config.sessionToken`.
import Foundation
import FieldContracts
import FieldDomain

private enum Routes {
    static let sessionStatus = "/api/v1/sync/session-status"
    static let assignments = "/api/v1/sync/assignments"
    static let submit = "/api/v1/sync/submit"
}

public final class OpsHubV1Client: SessionStatusSource, AssignmentSource, FieldTicketSubmitter, Sendable {
    private let baseUrl: String
    private let sessionToken: String
    private let fetchFn: HubFetch
    private let timeoutMs: Int

    // Default wall-clock bound per request (15s). `URLSession` has no default timeout for our
    // purposes here — without a bound, a black-holed connection would hang a submit forever and
    // leave its local evidence sitting in-flight.
    public init(baseUrl: String, sessionToken: String, fetchFn: HubFetch? = nil, timeoutMs: Int = 15_000) {
        self.baseUrl = baseUrl
        self.sessionToken = sessionToken
        self.fetchFn = fetchFn ?? urlSessionHubFetch
        self.timeoutMs = timeoutMs
    }

    private func headers(_ extra: [String: String] = [:]) -> [String: String] {
        var h = ["Authorization": "Bearer \(sessionToken)", "Accept": "application/json"]
        for (k, v) in extra { h[k] = v }
        return h
    }

    /// Shared GET path: network → `HubNetworkError`; 401/403 → `HubAuthError`; other non-2xx /
    /// non-JSON → `HubResponseError`.
    private func getJson(_ path: String) async throws -> Any {
        let response: HubHttpResponse
        do {
            response = try await boundedFetch(
                fetchFn, "\(baseUrl)\(path)", HubFetchInit(method: "GET", headers: headers()), timeoutMs: timeoutMs)
        } catch {
            throw HubNetworkError("Hub unreachable for GET \(path): \(error)", cause: error)
        }
        if response.status == 401 || response.status == 403 {
            throw HubAuthError("Hub auth failed (\(response.status)) for GET \(path)", httpStatus: response.status)
        }
        guard response.ok else {
            throw HubResponseError("Hub returned \(response.status) for GET \(path)", httpStatus: response.status)
        }
        guard let json = response.json() else {
            throw HubResponseError("Hub returned a non-JSON body for GET \(path)", httpStatus: response.status)
        }
        return json
    }

    public func getSessionStatus(options: HubRequestOptions?) async throws -> HubSessionStatus {
        let body = try await getJson(Routes.sessionStatus)
        guard let rec = body as? [String: Any], let clockedIn = rec["clocked_in"] as? Bool else {
            // Never guess clock state from a malformed answer — the gate stays locked instead.
            throw HubResponseError("session-status body is missing a boolean clocked_in")
        }
        // The real Hub sends `clocked_in_since` AND a `since` alias (same value); read either.
        return HubSessionStatus(
            clockedIn: clockedIn,
            clockedInSince: Self.optionalString(rec["clocked_in_since"]) ?? Self.optionalString(rec["since"]),
            source: Self.optionalString(rec["source"]),
            employeeId: Self.optionalString(rec["employee_id"]),
            assignmentsAvailable: (rec["assignments_available"] as? Bool) == true,
            serverTime: Self.optionalString(rec["server_time"])
        )
    }

    public func getAssignments(options: HubRequestOptions?) async throws -> [HubAssignment] {
        let body = try await getJson(Routes.assignments)
        let raw: [Any]
        if let arr = body as? [Any] {
            raw = arr
        } else if let rec = body as? [String: Any], let arr = rec["assignments"] as? [Any] {
            raw = arr
        } else {
            throw HubResponseError("assignments body is not a list")
        }
        return try raw.enumerated().map { i, entry in try parseHubAssignmentEntry(entry, indexLabel: "assignment[\(i)]")
        }
    }

    public func submitFieldTicket(_ submission: HubFieldTicketSubmission, options: HubRequestOptions?) async throws
        -> HubSubmitOutcome
    {
        var body: [String: Any] = [
            "idempotency_key": submission.idempotencyKey,
            "service_request_id": submission.serviceRequestId,
            "snapshot_hash": submission.snapshotHash,
            "ticket_no": submission.ticketNo,
            "quantity_bbl": submission.quantityBbl,
            "disposal_ticket_no": submission.disposalTicketNo,
        ]
        if let detail = submission.detail {
            body["field_ticket_detail"] = Self.toWireDetail(detail)
        }

        let response: HubHttpResponse
        do {
            let data = try JSONSerialization.data(withJSONObject: body)
            response = try await boundedFetch(
                fetchFn,
                "\(baseUrl)\(Routes.submit)",
                HubFetchInit(
                    method: "POST",
                    // Also in the body; the header lets Hub middleware dedupe before parsing.
                    headers: headers(["Content-Type": "application/json", "Idempotency-Key": submission.idempotencyKey]
                    ),
                    body: data
                ),
                timeoutMs: timeoutMs
            )
        } catch {
            return .transient(reason: .network, httpStatus: nil, detail: "\(error)")
        }

        let rec = (response.json() as? [String: Any]) ?? [:]
        let code = Self.optionalString(rec["rejection_code"]) ?? Self.optionalString(rec["reason_code"])
        let detail = Self.optionalString(rec["detail"])

        if response.ok {
            if (rec["accepted"] as? Bool) == true {
                let duplicate = (rec["duplicate"] as? Bool) == true || code == "duplicate"
                // Tolerant id read (spec: accept both): modern ticket_id, legacy field_ticket_id.
                let ticketId = Self.optionalString(rec["ticket_id"]) ?? Self.optionalString(rec["field_ticket_id"])
                // The real Hub returns 201 + snapshot_drift:true when it commits a ticket whose
                // snapshot had drifted. The work is durable, but the drift must be surfaced for
                // office review — never swallowed. (Verified live against opshub /sync/submit.)
                let snapshotDrift = (rec["snapshot_drift"] as? Bool) == true
                return .accepted(duplicate: duplicate, snapshotDrift: snapshotDrift ? true : nil, ticketId: ticketId)
            }
            if (rec["snapshot_drift"] as? Bool) == true {
                return .rejected(
                    kind: .needsReview, httpStatus: response.status, rejectionCode: code ?? "snapshot_drift",
                    detail: detail)
            }
            // Compatibility only: older Hub builds returned `{ field_ticket_id, status, duplicate,
            // snapshot_drift }` WITHOUT an `accepted` field at all. The legacy read applies ONLY
            // when `accepted` is absent — a present `accepted: false` (or garbage) is Hub
            // explicitly not accepting, and must never be promoted to success by the compat path.
            // Also require a success-like status and no snapshot drift so arbitrary 2xx bodies
            // stay transient.
            if rec["accepted"] == nil,
                let legacyTicketId = Self.optionalString(rec["field_ticket_id"]),
                Self.isLegacyAcceptedStatus(rec["status"]),
                (rec["snapshot_drift"] as? Bool) != true
            {
                return .accepted(
                    duplicate: (rec["duplicate"] as? Bool) == true || code == "duplicate", snapshotDrift: nil,
                    ticketId: legacyTicketId)
            }
            // 2xx without an explicit accept: do NOT mark work durable on a guess.
            return .transient(
                reason: .malformedResponse, httpStatus: response.status, detail: "2xx response without accepted:true")
        }

        switch response.status {
        case 401:
            return .authFailed(httpStatus: 401)
        case 403:
            // e.g. not clocked in, SR not assigned to this driver. User-visible, retryable after acting.
            return .rejected(kind: .blocked, httpStatus: 403, rejectionCode: code ?? "forbidden", detail: detail)
        case 409:
            // Real Hub: the forced-workflow guard rejected this — the driver is NOT clocked in, or
            // a Hub-required step (pre-trip DVIR / JHA) is missing for this SR (opshub
            // workflow.WorkflowError). Retryable after the user acts (clock in / complete the
            // step). NOT an idempotency conflict. Body carries only `detail`; preserve Hub's
            // verbatim reason.
            return .rejected(kind: .blocked, httpStatus: 409, rejectionCode: code ?? "workflow_blocked", detail: detail)
        // 412/422 are DEFENSIVE: the live V1 /sync/submit returns only 201/403/409 (verified
        // against opshub). These arms stay as a safety net for any future contract that does
        // surface drift/idempotency as a hard status, mapping both to needs-review with an
        // informative code.
        case 412:
            return .rejected(
                kind: .needsReview, httpStatus: 412, rejectionCode: code ?? "stale_version", detail: detail)
        case 422:
            return .rejected(
                kind: .needsReview, httpStatus: 422, rejectionCode: code ?? "idempotency_mismatch", detail: detail)
        default:
            if response.status == 429 || response.status >= 500 {
                return .transient(reason: .server, httpStatus: response.status, detail: detail)
            }
            // Any other 4xx: an unanticipated contract disagreement — surface for review with the
            // status preserved rather than inventing a retry loop or dropping the reason.
            return .rejected(
                kind: .needsReview, httpStatus: response.status, rejectionCode: code ?? "http_\(response.status)",
                detail: detail)
        }
    }
}

private extension OpsHubV1Client {
    static func optionalString(_ value: Any?) -> String? {
        guard let s = value as? String, !s.isEmpty else { return nil }
        return s
    }

    static func isLegacyAcceptedStatus(_ value: Any?) -> Bool {
        guard let s = value as? String else { return false }
        return s == "accepted" || s == "created" || s == "submitted"
    }

    static func ftInJSON(_ v: FtIn) -> [String: Any] {
        var o: [String: Any] = [:]
        if let ft = v.ft { o["ft"] = ft }
        if let inches = v.inches { o["inches"] = inches }
        return o
    }

    static func gaugeReadingJSON(_ v: GaugeReading) -> [String: Any] {
        var o: [String: Any] = [:]
        if let total = v.total { o["total"] = ftInJSON(total) }
        if let water = v.water { o["water"] = ftInJSON(water) }
        if let condensate = v.condensate { o["condensate"] = ftInJSON(condensate) }
        return o
    }

    /// Snake-case the full paper-ticket detail for the wire (`field_ticket_detail`). Only the
    /// camelCase keys are converted; ft/inches/total/water/condensate are already wire-shaped.
    /// Undefined fields are dropped so the Hub sees a clean, minimal blob. See
    /// docs/integration/field-ticket-full-form-hub-spec.md.
    static func toWireDetail(_ d: FieldTicketDetail) -> [String: Any] {
        var out: [String: Any] = [:]
        if let rigNo = d.rigNo { out["rig_no"] = rigNo }
        if let times = d.times {
            var tm: [String: Any] = [:]
            if let yardArrival = times.yardArrival { tm["yard_arrival"] = yardArrival }
            if let timeIn = times.timeIn { tm["time_in"] = timeIn }
            if let timeOut = times.timeOut { tm["time_out"] = timeOut }
            out["times"] = tm
        }
        if let tanks = d.tanks {
            out["tanks"] = tanks.map { tk -> [String: Any] in
                var o: [String: Any] = [:]
                if let label = tk.label { o["label"] = label }
                if let locationTime = tk.locationTime { o["location_time"] = locationTime }
                if let beginning = tk.beginning { o["beginning"] = gaugeReadingJSON(beginning) }
                if let ending = tk.ending { o["ending"] = gaugeReadingJSON(ending) }
                if let waterPulled = tk.waterPulled { o["water_pulled"] = ftInJSON(waterPulled) }
                if let barrelsPulled = tk.barrelsPulled { o["barrels_pulled"] = barrelsPulled }
                return o
            }
        }
        if let lineItems = d.lineItems {
            out["line_items"] = lineItems.map { li -> [String: Any] in
                var o: [String: Any] = ["description": li.description]
                if let qty = li.qty { o["qty"] = qty }
                if let rate = li.rate { o["rate"] = rate }
                if let total = li.total { o["total"] = total }
                return o
            }
        }
        return out
    }
}
