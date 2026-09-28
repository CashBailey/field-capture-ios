/**
 * Real-Hub wire-contract regression. The fixture in `fixtures/real-hub-assignments.json` is a
 * VERBATIM `GET /api/v1/sync/assignments` response captured from a locally-running opshub Hub
 * (`make up`, :8000) for an assigned Service Request. It guards the three wire-breaks that used
 * to empty the assignment list against the real Hub:
 *   1. latest_server_version is a STRING (== snapshot_hash), not an integer.
 *   2. job_type is an OBJECT { id, name }, not a bare string.
 *   3. workflow_requirements is { clock_in_required, required_steps[] }, not the legacy require_*
 *      booleans.
 * Re-capture with: curl -s :8000/api/v1/sync/assignments -H "Authorization: Bearer <token>".
 */
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

import { parseHubAssignmentEntry, parseWorkflowRequirementsFromAssignments } from '../src/domain';

const REAL_PAYLOAD = JSON.parse(
  readFileSync(join(__dirname, 'fixtures', 'real-hub-assignments.json'), 'utf8'),
) as Record<string, unknown>[];

describe('real opshub assignments payload', () => {
  it('parses the verbatim Hub response without throwing (the wire-break regression)', () => {
    expect(REAL_PAYLOAD.length).toBeGreaterThan(0);
    expect(() => REAL_PAYLOAD.map((entry) => parseHubAssignmentEntry(entry))).not.toThrow();
  });

  it('reads latest_server_version as the string snapshot hash, not an integer', () => {
    const entry = REAL_PAYLOAD[0]!;
    const parsed = parseHubAssignmentEntry(entry);
    expect(typeof parsed.latestServerVersion).toBe('string');
    expect(parsed.latestServerVersion).toBe(entry.snapshot_hash);
  });

  it('reads job_type as an object { id, name }', () => {
    const parsed = parseHubAssignmentEntry(REAL_PAYLOAD[0]!);
    expect(parsed.details?.jobType).toEqual({
      id: '11946f7f-49f7-4cce-b5f0-b2ea03d47dda',
      name: 'Vacuum Haul',
    });
  });

  it('reads workflow_requirements as { clockInRequired, requiredSteps[] }', () => {
    const parsed = parseHubAssignmentEntry(REAL_PAYLOAD[0]!);
    expect(parsed.details?.workflowRequirements).toEqual({
      clockInRequired: true,
      requiredSteps: [],
    });
    expect(parseWorkflowRequirementsFromAssignments([parsed])).toEqual({
      clockInRequired: true,
      requiredSteps: [],
    });
  });

  it('maps the rich master-data refs (customer/lease/material) the driver needs on device', () => {
    const parsed = parseHubAssignmentEntry(REAL_PAYLOAD[0]!);
    expect(parsed.details?.customer).toEqual({
      id: 'cbaf53e3-a698-4209-bdc4-9aa8bae23975',
      name: 'Acme Energy, LLC',
    });
    expect(parsed.details?.lease?.name).toBe('Northfield');
    expect(parsed.details?.material).toBe('Produced Water');
  });

  it('labels wells by well_no so the driver sees the well number, not a UUID', () => {
    const parsed = parseHubAssignmentEntry(REAL_PAYLOAD[0]!);
    // The real Hub carries the driver-facing well label in `well_no` ("114H"), not `name`;
    // a blank `field_name` on the same well must not wire-break the parse.
    expect(parsed.details?.wells).toEqual([
      { id: '06f59e71-0ff0-4e3a-8b17-28472062f6c0', name: '114H' },
    ]);
  });

  it('labels the vehicle by truck_no when the Hub assigns one (not the vehicle UUID)', () => {
    const parsed = parseHubAssignmentEntry({
      service_request_id: 'sr-veh',
      snapshot_hash: 'h-veh',
      vehicle: { id: 'veh-1', truck_no: 'Truck 12', vehicle_type: 'Vacuum', capacity_bbl: 130 },
    });
    expect(parsed.details?.vehicle).toEqual({ id: 'veh-1', name: 'Truck 12' });
  });

  it('captures request_no, status, and geofence hints; drops null coordinates', () => {
    const parsed = parseHubAssignmentEntry(REAL_PAYLOAD[0]!);
    expect(parsed.details?.requestNo).toBe('2026-000001');
    expect(parsed.details?.status).toBe('assigned');
    expect(parsed.details?.geofenceHints).toEqual({ required: false, radiusM: 250 });
    // This SR's wells have null lat/lon, so validation-only coordinates resolve to none.
    expect(parsed.details?.coordinates).toBeUndefined();
  });

  it('parses populated coordinates as validation-only points (not nav/routing data)', () => {
    const parsed = parseHubAssignmentEntry({
      service_request_id: 'sr-geo',
      snapshot_hash: 'h-geo',
      coordinates: {
        primary: { lat: 31.5, lon: -102.1 },
        wells: [{ well_id: 'w-1', lat: 31.5, lon: -102.1 }],
      },
    });
    expect(parsed.details?.coordinates).toEqual({
      primary: { lat: 31.5, lon: -102.1 },
      wells: [{ lat: 31.5, lon: -102.1, wellId: 'w-1' }],
    });
  });
});
