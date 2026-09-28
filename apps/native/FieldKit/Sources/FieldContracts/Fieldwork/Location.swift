// Port of fieldwork/location.ts — Validation-only location evidence (spec 7.13 / Phase 7). This
// proves WHERE a field action happened — it is NOT navigation: single-shot GPS only, no streaming,
// no LocationProvider, no map render, no routing. A fresh evidence model, deliberately NOT a
// revival of the deleted nav/map stack (kept out by the nav-stays-out guard). The native
// single-shot GPS capture feeds this model; the model + classification + durability are pure and
// live here / in the store.
import Foundation

public enum LocationPlaceKind: String, Equatable, Sendable, Codable {
    case yard
    case disposalSite = "disposal-site"
    case wellSite = "well-site"
    case other
}

/// The 8 validation states (field-day-workflow).
public enum LocationEvidenceState: String, Equatable, Sendable, Codable {
    case notCaptured = "not-captured"
    case captured
    case verified
    case outsideExpectedArea = "outside-expected-area"
    case unverified
    case rejected
    case gpsUnavailable = "gps-unavailable"
    case manualOnly = "manual-only"
}

/// Shared shape of `LocationGpsPoint` and `ExpectedArea` for `distanceMeters`, mirroring the TS
/// structural union `LocationGpsPoint | ExpectedArea`.
public protocol LatLon {
    var lat: Double { get }
    var lon: Double { get }
}

public struct LocationGpsPoint: Equatable, Sendable, LatLon, Codable {
    public var lat: Double
    public var lon: Double
    public var accuracyM: Double
    public var timestampMs: Int64

    public init(lat: Double, lon: Double, accuracyM: Double, timestampMs: Int64) {
        self.lat = lat
        self.lon = lon
        self.accuracyM = accuracyM
        self.timestampMs = timestampMs
    }
}

public struct LocationEvidence: Equatable, Sendable, Codable {
    public var id: String
    public var serviceRequestId: String
    public var placeKind: LocationPlaceKind
    /// What the evidence marks, e.g. "arrival" | "work-start" | "disposal". Free-form, Hub-defined.
    public var evidenceType: String
    public var gps: LocationGpsPoint?
    public var notes: String?
    public var state: LocationEvidenceState
    public var createdAt: String

    public init(
        id: String,
        serviceRequestId: String,
        placeKind: LocationPlaceKind,
        evidenceType: String,
        gps: LocationGpsPoint? = nil,
        notes: String? = nil,
        state: LocationEvidenceState,
        createdAt: String
    ) {
        self.id = id
        self.serviceRequestId = serviceRequestId
        self.placeKind = placeKind
        self.evidenceType = evidenceType
        self.gps = gps
        self.notes = notes
        self.state = state
        self.createdAt = createdAt
    }
}

/// An expected location (a known place + its geofence radius) to validate a capture against.
public struct ExpectedArea: Equatable, Sendable, LatLon {
    public var lat: Double
    public var lon: Double
    public var radiusM: Double

    public init(lat: Double, lon: Double, radiusM: Double) {
        self.lat = lat
        self.lon = lon
        self.radiusM = radiusM
    }
}

public struct LocationClassifyInput: Equatable, Sendable {
    public var gps: LocationGpsPoint?
    /// The expected place/geofence, when one is known (from the assignment coordinates/hints).
    public var expected: ExpectedArea?
    /// The worker chose to record a place manually (e.g. an unknown well) without trusting GPS.
    public var manualOnly: Bool?
    /// GPS was attempted but the device could not get a fix.
    public var gpsUnavailable: Bool?

    public init(
        gps: LocationGpsPoint? = nil,
        expected: ExpectedArea? = nil,
        manualOnly: Bool? = nil,
        gpsUnavailable: Bool? = nil
    ) {
        self.gps = gps
        self.expected = expected
        self.manualOnly = manualOnly
        self.gpsUnavailable = gpsUnavailable
    }
}

private let EARTH_RADIUS_M = 6_371_000.0

/// Great-circle distance between two points, in metres (haversine). Pure.
public func distanceMeters<A: LatLon, B: LatLon>(_ a: A, _ b: B) -> Double {
    func toRad(_ d: Double) -> Double { d * Double.pi / 180 }
    let dLat = toRad(b.lat - a.lat)
    let dLon = toRad(b.lon - a.lon)
    let lat1 = toRad(a.lat)
    let lat2 = toRad(b.lat)
    let h = pow(sin(dLat / 2), 2) + cos(lat1) * cos(lat2) * pow(sin(dLon / 2), 2)
    return 2 * EARTH_RADIUS_M * asin(min(1, sqrt(h)))
}

/**
 * Classify a location capture into one of the validation states. Conservative + honest:
 *  - manual-only / gps-unavailable take precedence (no GPS to trust).
 *  - with GPS but no expected area: unverified (captured, but nothing to check against).
 *  - within the geofence radius: verified; outside it: outside-expected-area.
 * The office adjudicates `unverified`/`outside-expected-area`; the phone never fabricates `verified`.
 */
public func classifyLocationEvidence(_ input: LocationClassifyInput) -> LocationEvidenceState {
    if input.manualOnly == true { return .manualOnly }
    guard input.gpsUnavailable != true, let gps = input.gps else { return .gpsUnavailable }
    guard let expected = input.expected else { return .unverified }
    let distance = distanceMeters(gps, expected)
    return distance <= expected.radiusM ? .verified : .outsideExpectedArea
}
