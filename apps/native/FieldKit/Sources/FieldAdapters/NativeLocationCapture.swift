import CoreLocation
// Port of adapters/device/NativeLocationCapture.ts — Capture one foreground GPS fix for
// validation evidence. This is intentionally not a tracker: no watchPosition, no background task,
// no geofencing, and no map dependency.
import Foundation
import FieldContracts

/// One raw GPS fix as CoreLocation reports it — mirrors the slice of the TS
/// `GeolocationResponse.coords`/`.timestamp` this code actually reads.
public struct RawLocationFix: Equatable, Sendable {
    public var latitude: Double
    public var longitude: Double
    /// CoreLocation reports a negative accuracy when it cannot determine one; nil mirrors the TS
    /// `accuracy: number | null`.
    public var accuracy: Double?
    public var timestampMs: Int64

    public init(latitude: Double, longitude: Double, accuracy: Double?, timestampMs: Int64) {
        self.latitude = latitude
        self.longitude = longitude
        self.accuracy = accuracy
        self.timestampMs = timestampMs
    }
}

/// Thrown by `currentFix` when the device could not produce one (permission race, hardware
/// error, or the bound elapsed) — `captureValidationGps` turns this into nil, never fabricated GPS.
public struct LocationCaptureError: Error, CustomStringConvertible {
    public let message: String
    public var description: String { message }
    public init(_ message: String) { self.message = message }
}

/// The seam CoreLocation is wrapped behind — mirrors the TS `GeolocationLike` (permission +
/// one-shot fix), letting tests fake GPS without touching real location services.
public protocol LocationCaptureSource {
    func requestForegroundAuthorization() async -> Bool
    func currentFix(timeoutMs: Int) async throws -> RawLocationFix
}

/// Capture one foreground GPS fix for validation evidence. This is intentionally not a tracker:
/// no watchPosition, no background task, no geofencing, and no map dependency.
public func captureValidationGps(
    _ source: LocationCaptureSource = CoreLocationCaptureSource(),
    timeoutMs: Int = 15_000
) async -> LocationGpsPoint? {
    let granted = await source.requestForegroundAuthorization()
    guard granted else { return nil }
    guard let fix = try? await source.currentFix(timeoutMs: timeoutMs) else { return nil }
    return LocationGpsPoint(
        lat: fix.latitude,
        lon: fix.longitude,
        accuracyM: max(0, fix.accuracy ?? 0),
        timestampMs: fix.timestampMs
    )
}

/// Production `LocationCaptureSource`, backed by `CLLocationManager`.
public final class CoreLocationCaptureSource: NSObject, LocationCaptureSource, CLLocationManagerDelegate,
    @unchecked Sendable
{
    private let manager = CLLocationManager()
    private let lock = NSLock()
    private var authContinuations: [CheckedContinuation<Bool, Never>] = []
    private let locationRequests = LocationRequestCoordinator()

    public override init() {
        super.init()
        manager.delegate = self
    }

    public func requestForegroundAuthorization() async -> Bool {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                self.lock.lock()
                let shouldRequest = self.authContinuations.isEmpty
                self.authContinuations.append(continuation)
                self.lock.unlock()
                if shouldRequest {
                    self.manager.requestWhenInUseAuthorization()
                }
            }
        @unknown default:
            return false
        }
    }

    public func currentFix(timeoutMs: Int) async throws -> RawLocationFix {
        try await locationRequests.wait(timeoutMs: timeoutMs) { [self] in
            manager.requestLocation()
        }
    }

    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        lock.lock()
        let continuations = authContinuations
        authContinuations.removeAll()
        lock.unlock()
        guard !continuations.isEmpty else { return }
        let granted: Bool
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            granted = true
        default:
            granted = false
        }
        for continuation in continuations {
            continuation.resume(returning: granted)
        }
    }

    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else {
            locationRequests.fail(LocationCaptureError("CoreLocation returned no locations"))
            return
        }
        locationRequests.succeed(
            RawLocationFix(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                accuracy: location.horizontalAccuracy >= 0 ? location.horizontalAccuracy : nil,
                timestampMs: Int64(location.timestamp.timeIntervalSince1970 * 1000)
            ))
    }

    public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        locationRequests.fail(error)
    }
}

/// Owns the one-shot continuation so timeout, cancellation, and CoreLocation callbacks all resolve
/// the same request exactly once. A second caller fails fast instead of replacing the first caller.
final class LocationRequestCoordinator: @unchecked Sendable {
    private typealias Continuation = CheckedContinuation<RawLocationFix, Error>

    private let lock = NSLock()
    private var request: (id: UUID, continuation: Continuation)?
    private var canceledRequestIDs: Set<UUID> = []

    func wait(timeoutMs: Int, start: @escaping @Sendable () -> Void) async throws -> RawLocationFix {
        let requestID = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let registrationError = register(requestID: requestID, continuation: continuation)
                if let registrationError {
                    continuation.resume(throwing: registrationError)
                    return
                }

                let boundedTimeoutMs = max(0, timeoutMs)
                DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(boundedTimeoutMs)) { [self] in
                    finish(
                        requestID: requestID,
                        result: .failure(BoundedFetchTimeoutError(timeoutMs: boundedTimeoutMs)))
                }
                start()
            }
        } onCancel: { [self] in
            cancel(requestID: requestID)
        }
    }

    func succeed(_ fix: RawLocationFix) {
        finishCurrent(with: .success(fix))
    }

    func fail(_ error: Error) {
        finishCurrent(with: .failure(error))
    }

    private func register(requestID: UUID, continuation: Continuation) -> Error? {
        lock.lock()
        defer { lock.unlock() }
        if canceledRequestIDs.remove(requestID) != nil || Task.isCancelled {
            return CancellationError()
        }
        guard request == nil else {
            return LocationCaptureError("a location request is already in progress")
        }
        request = (requestID, continuation)
        return nil
    }

    private func cancel(requestID: UUID) {
        lock.lock()
        guard request?.id == requestID else {
            canceledRequestIDs.insert(requestID)
            lock.unlock()
            return
        }
        let continuation = request?.continuation
        request = nil
        lock.unlock()
        continuation?.resume(throwing: CancellationError())
    }

    private func finishCurrent(with result: Result<RawLocationFix, Error>) {
        lock.lock()
        guard let request else {
            lock.unlock()
            return
        }
        self.request = nil
        lock.unlock()
        request.continuation.resume(with: result)
    }

    private func finish(requestID: UUID, result: Result<RawLocationFix, Error>) {
        lock.lock()
        guard request?.id == requestID else {
            lock.unlock()
            return
        }
        let continuation = request?.continuation
        request = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}
