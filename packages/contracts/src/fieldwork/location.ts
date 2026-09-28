/**
 * Validation-only location evidence (spec 7.13 / Phase 7). This proves WHERE a field action
 * happened — it is NOT navigation: single-shot GPS only, no streaming, no LocationProvider, no map
 * render, no routing. A fresh evidence model, deliberately NOT a revival of the deleted nav/map
 * stack (kept out by the nav-stays-out guard). The native single-shot GPS capture
 * (@react-native-community/geolocation) feeds this model; the model + classification + durability
 * are pure and live here / in the store.
 */

export type LocationPlaceKind =
  | "yard"
  | "disposal-site"
  | "well-site"
  | "other";

/** The 8 validation states (field-day-workflow). */
export type LocationEvidenceState =
  | "not-captured"
  | "captured"
  | "verified"
  | "outside-expected-area"
  | "unverified"
  | "rejected"
  | "gps-unavailable"
  | "manual-only";

export interface LocationGpsPoint {
  lat: number;
  lon: number;
  accuracyM: number;
  timestampMs: number;
}

export interface LocationEvidence {
  id: string;
  serviceRequestId: string;
  placeKind: LocationPlaceKind;
  /** What the evidence marks, e.g. "arrival" | "work-start" | "disposal". Free-form, Hub-defined. */
  evidenceType: string;
  gps?: LocationGpsPoint;
  notes?: string;
  state: LocationEvidenceState;
  createdAt: string;
}

/** An expected location (a known place + its geofence radius) to validate a capture against. */
export interface ExpectedArea {
  lat: number;
  lon: number;
  radiusM: number;
}

export interface LocationClassifyInput {
  gps?: LocationGpsPoint;
  /** The expected place/geofence, when one is known (from the assignment coordinates/hints). */
  expected?: ExpectedArea;
  /** The worker chose to record a place manually (e.g. an unknown well) without trusting GPS. */
  manualOnly?: boolean;
  /** GPS was attempted but the device could not get a fix. */
  gpsUnavailable?: boolean;
}

const EARTH_RADIUS_M = 6_371_000;

/** Great-circle distance between two points, in metres (haversine). Pure. */
export function distanceMeters(
  a: LocationGpsPoint | ExpectedArea,
  b: LocationGpsPoint | ExpectedArea,
): number {
  const toRad = (d: number) => (d * Math.PI) / 180;
  const dLat = toRad(b.lat - a.lat);
  const dLon = toRad(b.lon - a.lon);
  const lat1 = toRad(a.lat);
  const lat2 = toRad(b.lat);
  const h =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(lat1) * Math.cos(lat2) * Math.sin(dLon / 2) ** 2;
  return 2 * EARTH_RADIUS_M * Math.asin(Math.min(1, Math.sqrt(h)));
}

/**
 * Classify a location capture into one of the validation states. Conservative + honest:
 *  - manual-only / gps-unavailable take precedence (no GPS to trust).
 *  - with GPS but no expected area: unverified (captured, but nothing to check against).
 *  - within the geofence radius: verified; outside it: outside-expected-area.
 * The office adjudicates `unverified`/`outside-expected-area`; the phone never fabricates `verified`.
 */
export function classifyLocationEvidence(
  input: LocationClassifyInput,
): LocationEvidenceState {
  if (input.manualOnly === true) return "manual-only";
  if (input.gpsUnavailable === true || input.gps === undefined)
    return "gps-unavailable";
  if (input.expected === undefined) return "unverified";
  const distance = distanceMeters(input.gps, input.expected);
  return distance <= input.expected.radiusM
    ? "verified"
    : "outside-expected-area";
}
