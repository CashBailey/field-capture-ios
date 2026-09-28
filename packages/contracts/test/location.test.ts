import { describe, it, expect } from "vitest";
import {
  classifyLocationEvidence,
  distanceMeters,
  type LocationGpsPoint,
} from "../src/fieldwork/index.js";

const gps = (lat: number, lon: number): LocationGpsPoint => ({
  lat,
  lon,
  accuracyM: 5,
  timestampMs: 1_750_000_000_000,
});

describe("distanceMeters (haversine)", () => {
  it("is ~0 for the same point and grows with separation", () => {
    expect(distanceMeters(gps(31.5, -102.1), gps(31.5, -102.1))).toBeCloseTo(
      0,
      5,
    );
    // ~111 km per degree of latitude.
    expect(
      distanceMeters(gps(31.5, -102.1), gps(32.5, -102.1)),
    ).toBeGreaterThan(100_000);
  });
});

describe("classifyLocationEvidence (validation-only, never fabricates 'verified')", () => {
  const expected = { lat: 31.5, lon: -102.1, radiusM: 250 };

  it("verified when GPS is inside the geofence radius", () => {
    expect(classifyLocationEvidence({ gps: gps(31.5, -102.1), expected })).toBe(
      "verified",
    );
  });

  it("outside-expected-area when GPS is beyond the radius", () => {
    expect(classifyLocationEvidence({ gps: gps(31.6, -102.1), expected })).toBe(
      "outside-expected-area",
    );
  });

  it("unverified when there is GPS but no expected area to check against", () => {
    expect(classifyLocationEvidence({ gps: gps(31.5, -102.1) })).toBe(
      "unverified",
    );
  });

  it("gps-unavailable when GPS is missing or the fix failed", () => {
    expect(classifyLocationEvidence({ expected })).toBe("gps-unavailable");
    expect(
      classifyLocationEvidence({
        gpsUnavailable: true,
        gps: gps(31.5, -102.1),
      }),
    ).toBe("gps-unavailable");
  });

  it("manual-only takes precedence — the worker recorded a place without trusting GPS", () => {
    expect(
      classifyLocationEvidence({
        manualOnly: true,
        gps: gps(31.5, -102.1),
        expected,
      }),
    ).toBe("manual-only");
  });
});
