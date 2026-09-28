// Port of src/runtime/wireAppRuntime.ts — production wiring: the only place the controller meets
// real device modules (SQLite database, keychain, secure random, URLSession). Throws
// `HubConfigError` when the build has no Hub URL — the app shows that visibly instead of guessing
// a Hub (config honesty).
import Foundation
import FieldAdapters
import FieldContracts
import FieldData
import FieldDomain

public struct AppRuntime {
    public let controller: AppController
    /// What the local store REALLY guarantees (verified at open, surfaced in the UI).
    public let durability: StoreDurability
    public let assignmentStore: AssignmentStore
    /// Durable pre-submit draft storage; submit evidence/outbox rows are separate.
    public let draftStore: SqliteFieldTicketDraftStore
    /// Durable pre-submit receipt drafts (the receipt half of the ticket+receipt package).
    public let receiptStore: SqliteReceiptDraftStore
    /// Durable, non-evictable validation-only location evidence (Phase 7).
    public let locationStore: SqliteLocationEvidenceStore
    /// Durable 24h offline-policy baseline (last successful Hub contact).
    public let offlinePolicyStore: SqliteOfflinePolicyStore
    /// Generic ADR-004 operation outbox (safety-form events, blob links, print events).
    public let outbox: SqliteSyncOutboxStore
    /// ADR-004 V2 sync engine with the REAL transport wired (push DVIR/JHA evidence via
    /// /sync/commands). A caller must drive syncOnce/pushOnce — the runtime trigger is a follow-up.
    public let syncEngine: SyncEngine
    public let field: FieldRuntimeWorkspace
    public let recovery: EvidenceRecovery
}

public struct FieldRuntimeWorkspace {
    public let gate: GateBox
    public let workflow: FieldWorkflowService
    public let workStart: WorkStartService
    public let locationEvidenceSync: LocationEvidenceSyncService
    public let forms: SqliteFieldFormStore
    public let capture: CaptureFlow
    /// Stable per-install device id, for signature/audit metadata.
    public let deviceInstanceId: String
    public let uploadEngine: UploadEngine
    public let blobs: SqliteBlobUploadStore
    public let printRuntime: PrintRuntime
    public let printQueue: PrintJobQueue
    public let linkOutcome: (String) throws -> OutboxItemState?
}

/// The controller's cached clock gate (TS closure pair over a captured `let`).
public final class GateBox {
    private let lock = NSLock()
    private var current: FieldWorkGate
    init(_ initial: FieldWorkGate) { self.current = initial }
    public func get() -> FieldWorkGate {
        lock.lock()
        defer { lock.unlock() }
        return current
    }
    public func set(_ gate: FieldWorkGate) {
        lock.lock()
        current = gate
        lock.unlock()
    }
}

private let INITIAL_GATE: FieldWorkGate = .locked(
    reason: .hubUnreachable, detail: "session not refreshed yet")

// ---- typed payload → JSONValue bridges (TS gets these for free: the payload IS the JSON) ----

private func anyToJSONValue(_ any: Any?) -> JSONValue {
    guard let any, !(any is NSNull) else { return .null }
    switch any {
    case let v as JSONValue: return v
    case let v as Bool: return .bool(v)
    case let v as String: return .string(v)
    case let v as Int: return .number(Double(v))
    case let v as Int64: return .number(Double(v))
    case let v as Double: return .number(v)
    case let v as NSNumber: return .number(v.doubleValue)
    case let v as [Any]: return .array(v.map(anyToJSONValue))
    case let v as [String: Any]: return .object(v.mapValues(anyToJSONValue))
    default: return .null
    }
}

private func jsonValueToAny(_ value: JSONValue) -> Any {
    switch value {
    case .string(let s): return s
    case .number(let d): return d
    case .bool(let b): return b
    case .null: return NSNull()
    case .array(let a): return a.map(jsonValueToAny)
    case .object(let o): return o.mapValues(jsonValueToAny)
    }
}

/// Record a complete pull page or fail it. The surrounding sync transaction rolls back any rows
/// recorded before a malformed change was encountered, and the engine keeps the old frontier.
func recordAllPulledChanges(_ changes: [JSONValue], in ledger: SyncChangeLedger) throws {
    let result = try recordChanges(ledger, changes.map(jsonValueToAny))
    guard result.skipped == 0 else {
        throw SyncEngineError.skippedPulledChanges(count: result.skipped)
    }
}

private func encodableToJSONValue<T: Encodable>(_ value: T) throws -> JSONValue {
    let data = try JSONEncoder().encode(value)
    return try JSONDecoder().decode(JSONValue.self, from: data)
}

private func mapEnvelope<T>(_ e: OperationEnvelope<T>, _ payload: JSONValue) -> OperationEnvelope<JSONValue> {
    OperationEnvelope(
        opId: e.opId, kind: e.kind, type: e.type, idempotencyKey: e.idempotencyKey,
        localSeq: e.localSeq, dependsOn: e.dependsOn, precondition: e.precondition, payload: payload)
}

// ---- FieldAdapters ↔ FieldRuntime seam conformances ----

/// The real Hub transport already speaks both narrowed seams the engines drive.
extension OpsHubSyncTransport: SyncCommandTransport, UploadSessionOpening {}

/// Adapts the real tus HTTP client to the engine's chunk-transport seam (both sides define
/// structurally identical result/error types; the engine's are the ones it catches).
private struct TusClientChunkTransport: TusChunkTransport {
    let client: TusUploadClient

    func probe(_ uploadUrl: String) async throws -> FieldRuntime.TusProbeResult {
        do {
            let r = try await client.probe(uploadUrl)
            return .init(offset: r.offset, sha256: r.sha256)
        } catch { throw Self.mapError(error) }
    }

    func uploadChunk(_ uploadUrl: String, _ offset: Int, _ chunk: Data) async throws
        -> FieldRuntime.TusPatchResult
    {
        do {
            let r = try await client.uploadChunk(uploadUrl, offset, chunk)
            return .init(offset: r.offset, sha256: r.sha256)
        } catch { throw Self.mapError(error) }
    }

    private static func mapError(_ error: Error) -> Error {
        switch error {
        case let e as FieldAdapters.TusSessionGoneError:
            return FieldRuntime.TusSessionGoneError(e.description)
        case let e as FieldAdapters.TusHashMismatchError:
            return FieldRuntime.TusHashMismatchError(e.description, serverSha256: e.serverSha256)
        default:
            return error
        }
    }
}

/// FieldData's durable `DeviceIdentity` wired to the engines' write-identity seam.
private final class DurableWriteIdentity: WriteIdentity {
    private let identity: DeviceIdentity
    init(_ identity: DeviceIdentity) { self.identity = identity }
    // ponytail: try! — the identity row is created during wiring (before any caller can reach
    // this); a failure here is a broken database mid-session, unrecoverable in-process.
    var deviceInstanceId: String { try! identity.ensureDeviceInstanceId(randomUuid) }
    func allocateLocalSeq() -> Int {
        identity_ensure()
        return Int(try! identity.allocateLocalSeq())
    }
    func generateUuid() -> String { randomUuid() }
    private func identity_ensure() { _ = try! identity.ensureDeviceInstanceId(randomUuid) }
}

public func wireAppRuntime(
    hubUrl: String?,
    onAuthRequired: (() -> Void)? = nil
) throws -> AppRuntime {
    // Validates the build-time Hub URL (throws HubConfigError when unset). The placeholder token
    // is never sent anywhere — real tokens come from the auth slice per call.
    let baseUrl = try resolveHubRuntimeConfig(hubUrl: hubUrl, sessionToken: "startup-validation")
        .baseUrl

    let encryptionKey = try getOrCreateDatabaseKey()
    let opened = try openFieldDatabase(encryptionKey: encryptionKey)
    let db = opened.db
    let durability = opened.durability
    let assignmentStore = SqliteAssignmentStore(db, durability)
    let draftStore = SqliteFieldTicketDraftStore(db, durability)
    let receiptStore = SqliteReceiptDraftStore(db, durability)
    let locationStore = SqliteLocationEvidenceStore(db, durability)
    let offlinePolicyStore = SqliteOfflinePolicyStore(db, durability)
    let identity = DeviceIdentity(db)
    let outbox = SqliteSyncOutboxStore(db, durability)
    let frontier = SqliteSyncFrontierStore(db, durability)
    let changeLedger = SqliteSyncChangeLedger(db, durability)
    // Durable, secret-free anomaly log (Sync Center copy-diagnostic). Sync engine non-fatal
    // events — including an unkeyable down-sync change the Hub should never have sent — land here
    // so they are surfaced for the office rather than silently swallowed.
    let diagnosticLog = SqliteDiagnosticLogStore(db, durability)
    let isoNow: () -> String = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }
    let recordAnomaly: (DiagnosticLevel, String, [String: JSONValue]?) -> Void = {
        level, message, context in
        do {
            try diagnosticLog.record(
                DiagnosticLog(
                    id: randomUuid(), level: level, message: message, context: context,
                    createdAt: isoNow()))
        } catch {
            // The diagnostic store shares this database. If it is also unavailable, there is no
            // safer local sink; never let that secondary failure mask or crash after the primary
            // sync/upload error that reached this reporting hook.
        }
    }
    // The real ADR-004 transports share ONE lazy token provider that resolves a fresh bearer
    // through the AppController's single-flight session (the controller is built below;
    // controllerRef is set right after, before anything can drive a push or an upload).
    let controllerRef = ControllerRef()
    let syncTokenProvider: HubTokenProvider = {
        guard let controller = controllerRef.controller else {
            // No push/upload can run before wiring; throw (transient) rather than send a junk token.
            throw HubNetworkError("sync transport used before controller wiring")
        }
        return try await controller.getSyncSessionToken()
    }
    // SyncEngine push/pull (/sync/commands, /sync/changes) AND blob upload session-open
    // (/sync/uploads) go through this one transport — both share the controller's session refresh.
    let pushTransport = OpsHubSyncTransport(
        baseUrl: baseUrl,
        // sessionToken is a never-used fallback: tokenProvider resolves a fresh bearer per call.
        sessionToken: "unused-tokenProvider-overrides",
        tokenProvider: syncTokenProvider)
    // Real tus blob-upload client: HEAD/PATCH the per-session upload_url with a fresh bearer per
    // request — a multi-chunk upload can outlive a token.
    let tusClient = try TusUploadClient(
        tokenProvider: syncTokenProvider, fetchFn: createTusFetch(), hubBaseUrl: baseUrl)
    // The SyncRunner (owned by the AppController below) DRIVES this engine: a periodic timer plus
    // a kick-on-enqueue (onEnqueue -> controller.notifyQueuedSync), so enqueued field evidence
    // (DVIR/JHA/...) actually reaches the Hub.
    let syncEngine = SyncEngine(
        SyncEngineDeps(
            outbox: outbox,
            frontier: frontier,
            transport: pushTransport,
            // Idempotently record every down-synced change BEFORE the frontier advances, so
            // authoritative changes are durably kept (never dropped by a no-op apply). An
            // unkeyable/malformed change (Hub contract violation) cannot be recorded — surface it
            // instead of letting the frontier silently skip past.
            applyChanges: { changes in
                try recordAllPulledChanges(changes, in: changeLedger)
            },
            // Atomic apply + frontier-advance: the frontier never moves past changes that were
            // not applied.
            transaction: { fn in try db.transaction { try fn() } },
            // Non-fatal sync anomalies (e.g. Hub answered for an op we never sent, or a pull-leg
            // error) are logged to the durable diagnostic store rather than dropped.
            onError: { scope, error in
                let level: DiagnosticLevel = error is SyncEngineError ? .error : .warning
                recordAnomaly(level, "sync \(scope) anomaly", ["detail": .string(String(describing: error))])
            },
            // Kick the background driver to push promptly when fresh work is enqueued
            // (controllerRef is set right after the controller is built, before any submit-time
            // enqueue can happen).
            onEnqueue: { controllerRef.controller?.notifyQueuedSync() },
            onHubContact: { at in
                offlinePolicyStore.recordHubContact(Int64(at.timeIntervalSince1970 * 1000))
            }))
    let writeIdentity = DurableWriteIdentity(identity)
    let gate = GateBox(INITIAL_GATE)
    let forms = SqliteFieldFormStore(db, durability)
    let blobs = SqliteBlobUploadStore(db, durability)
    // Every producer receives the throwing enqueue seam. A caller may present the error in its own
    // UI, but no layer may turn a failed durable write into an apparent success.
    let enqueueAuxiliaryJSON: (OperationEnvelope<JSONValue>) throws -> Void = { envelope in
        _ = try syncEngine.enqueue(envelope)
    }
    let uploadEngine = UploadEngine(
        UploadEngineDeps(
            blobs: blobs,
            bytes: FileBlobBytesSource(createNativeBlobFileDriver()),
            // Real blob upload: open the session via the same Hub transport as commands, then
            // HEAD/PATCH the bytes through the real tus client. A captured photo/signature
            // reaches the Hub and its attachment.link is enqueued for the SyncRunner to push.
            transport: pushTransport,
            tus: TusClientChunkTransport(client: tusClient),
            enqueueLink: { envelope in
                try enqueueAuxiliaryJSON(mapEnvelope(envelope, try encodableToJSONValue(envelope.payload)))
            },
            linkState: { opId in try outbox.get(opId)?.state },
            // Kick the upload driver the moment a blob is captured (controllerRef is set before
            // any capture).
            onRegister: { controllerRef.controller?.notifyQueuedUpload() },
            identity: writeIdentity))
    let printQueue = PrintJobQueue(SqlitePrintJobStore(db))
    let printRuntime = PrintRuntime(
        PrintRuntimeDeps(
            queue: printQueue,
            payloads: SqlitePrintPayloadStore(db),
            transport: Pt210PrinterTransport(),
            enqueueEvent: { envelope in
                try enqueueAuxiliaryJSON(mapEnvelope(envelope, try encodableToJSONValue(envelope.payload)))
            },
            // Outbox state of the event op for (printJobId, event) — scanned from the sync outbox
            // (payloads live there as JSONValue; match on the wire fields directly).
            eventOutcome: { printJobId, event in
                for item in try outbox.list() where item.envelope.type == "print.event" {
                    guard case .object(let payload) = item.envelope.payload,
                        case .string(let jobId)? = payload["printJobId"], jobId == printJobId,
                        case .string(let kind)? = payload["event"], kind == event.rawValue
                    else { continue }
                    return item.state
                }
                return nil
            },
            identity: writeIdentity))
    let field = FieldRuntimeWorkspace(
        gate: gate,
        workflow: FieldWorkflowService(
            FieldWorkflowDeps(
                forms: forms,
                gateState: { gate.get() },
                enqueueEvidence: { envelope in
                    _ = try syncEngine.enqueue(
                        mapEnvelope(envelope, anyToJSONValue(fieldFormToJSON(envelope.payload))))
                },
                outboxItem: { opId in
                    try outbox.get(opId).map {
                        FieldWorkflowOutboxItem(
                            state: $0.state, rejectionCode: $0.rejectionCode, lastError: $0.lastError)
                    }
                },
                requirements: {
                    parseWorkflowRequirementsFromAssignments(assignmentStore.listAssignments())
                },
                identity: writeIdentity)),
        workStart: WorkStartService(
            WorkStartServiceDeps(
                gateState: { gate.get() },
                enqueueEvent: { envelope in
                    try enqueueAuxiliaryJSON(mapEnvelope(envelope, try encodableToJSONValue(envelope.payload)))
                },
                identity: writeIdentity)),
        locationEvidenceSync: LocationEvidenceSyncService(
            LocationEvidenceSyncDeps(
                enqueueEvent: { envelope in
                    try enqueueAuxiliaryJSON(mapEnvelope(envelope, try encodableToJSONValue(envelope.payload)))
                },
                identity: writeIdentity)),
        forms: forms,
        capture: CaptureFlow(
            CaptureFlowDeps(
                uploads: uploadEngine,
                persistBytes: { blobId, bytes in
                    try await FileBlobBytesSource(createNativeBlobFileDriver())
                        .persist(blobId: blobId, bytes: bytes)
                },
                gateState: { gate.get() },
                identity: CaptureIdentity(generateUuid: randomUuid))),
        deviceInstanceId: try identity.ensureDeviceInstanceId(randomUuid),
        uploadEngine: uploadEngine,
        blobs: blobs,
        printRuntime: printRuntime,
        printQueue: printQueue,
        linkOutcome: { opId in try outbox.get(opId)?.state })

    let controller = AppController(
        AppControllerDeps(
            evidenceStore: SqliteTicketEvidenceStore(db, durability),
            assignmentStore: assignmentStore,
            tokenStore: KeychainTokenStore(),
            // Bind the refresh-token family to this install's stable device id (resolved lazily
            // so the device-identity store needn't be touched until first sign-in).
            authApi: HubAuthApiV1(
                baseUrl, deviceId: { try identity.ensureDeviceInstanceId(randomUuid) }),
            syncEngine: syncEngine,
            uploadEngine: uploadEngine,
            offlinePolicyStore: offlinePolicyStore,
            hubClientFor: { sessionToken in
                OpsHubV1Client(baseUrl: baseUrl, sessionToken: sessionToken)
            },
            identity: AppControllerIdentity(
                ensureDeviceInstanceId: { gen in try! identity.ensureDeviceInstanceId(gen) },
                allocateLocalSeq: {
                    _ = try! identity.ensureDeviceInstanceId(randomUuid)
                    return Int(try! identity.allocateLocalSeq())
                }),
            generateUuid: randomUuid,
            onAuthRequired: onAuthRequired,
            onSyncError: { scope, error in
                recordAnomaly(
                    .error, "\(scope) sweep failed",
                    ["detail": .string(String(describing: error))])
            }))
    // The push transport's lazy tokenProvider resolves through the controller — wire it now,
    // before start() or any caller can drive a sync push.
    controllerRef.controller = controller

    // Restart recovery MUST precede the retry engine and any submit (start() enforces order).
    let recovery = try controller.start()
    return AppRuntime(
        controller: controller,
        durability: durability,
        assignmentStore: assignmentStore,
        draftStore: draftStore,
        receiptStore: receiptStore,
        locationStore: locationStore,
        offlinePolicyStore: offlinePolicyStore,
        outbox: outbox,
        syncEngine: syncEngine,
        field: field,
        recovery: recovery)
}

/// TS `let controllerRef: AppController | undefined` captured by the token provider.
private final class ControllerRef: @unchecked Sendable {
    weak var controller: AppController?
}
