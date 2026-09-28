import { fieldwork } from '@fieldcapture/contracts';

import {
  HubResponseError,
  type AssignmentCoordinates,
  type AssignmentDetails,
  type AssignmentDisposalSite,
  type AssignmentGeofenceHints,
  type AssignmentGpsPoint,
  type AssignmentNamedRef,
  type AssignmentStatus,
  type AssignmentWell,
  type AssignmentWellCoordinate,
  type HubAssignment,
} from './hubGateway';

const KNOWN_ASSIGNMENT_STATUSES: readonly AssignmentStatus[] = [
  'requested',
  'authorized',
  'assigned',
  'in_progress',
  'completed',
  'closed',
  'on_hold',
  'cancelled',
];

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function optionalString(value: unknown, path: string): string | undefined {
  if (value === undefined || value === null) return undefined;
  if (typeof value === 'string' && value.trim().length > 0) return value.trim();
  throw new HubResponseError(`${path} must be a non-empty string`);
}

function firstString(
  rec: Record<string, unknown>,
  path: string,
  keys: readonly string[],
): string | undefined {
  for (const key of keys) {
    const value = rec[key];
    if (value === undefined || value === null) continue;
    // A present-but-blank string is treated as absent so a later key (or the id fallback) can
    // supply the label. The real Hub sends "" for optional labels (e.g. well field_name), and a
    // blank must never wire-break the assignment list. Non-string values still defer to
    // optionalString for a clear typed error.
    if (typeof value === 'string') {
      const trimmed = value.trim();
      if (trimmed.length === 0) continue;
      return trimmed;
    }
    return optionalString(value, `${path}.${key}`);
  }
  return undefined;
}

function parseNamedRef(
  value: unknown,
  path: string,
  idKeys: readonly string[],
  nameKeys: readonly string[] = ['name', 'label', 'display_name'],
): AssignmentNamedRef | undefined {
  if (value === undefined || value === null) return undefined;
  if (typeof value === 'string') return { name: optionalString(value, path)! };
  if (!isRecord(value)) throw new HubResponseError(`${path} must be an object or string`);
  const id = firstString(value, path, idKeys);
  const name = firstString(value, path, nameKeys) ?? id;
  if (name === undefined)
    throw new HubResponseError(`${path}.name is required when ${path} is set`);
  return id === undefined ? { name } : { id, name };
}

function parseWell(value: unknown, path: string): AssignmentWell {
  // The real Hub sends the driver-facing well label as `well_no` (e.g. "114H"), not `name`;
  // prefer it so the driver sees the well number instead of a falling-back-to-id UUID.
  const named = parseNamedRef(
    value,
    path,
    ['well_id', 'wellId', 'id'],
    ['well_no', 'name', 'label', 'display_name'],
  );
  if (named === undefined) throw new HubResponseError(`${path} is required`);
  const rec = isRecord(value) ? value : {};
  const leaseId = firstString(rec, path, ['lease_id', 'leaseId']);
  return {
    ...named,
    ...(leaseId !== undefined ? { leaseId } : {}),
  };
}

function parseWells(value: unknown, path: string): AssignmentWell[] | undefined {
  if (value === undefined || value === null) return undefined;
  if (!Array.isArray(value)) throw new HubResponseError(`${path} must be a list`);
  return value.map((entry, index) => parseWell(entry, `${path}[${index}]`));
}

function parseDisposalSite(value: unknown, path: string): AssignmentDisposalSite | undefined {
  return parseNamedRef(value, path, ['site_id', 'disposal_site_id', 'id']);
}

function parseMaterial(value: unknown, path: string): string | undefined {
  if (value === undefined || value === null) return undefined;
  if (typeof value === 'string') return optionalString(value, path);
  if (!isRecord(value)) throw new HubResponseError(`${path} must be an object or string`);
  return firstString(value, path, ['name', 'label', 'material_name', 'description']);
}

function parseLatestServerVersion(value: unknown, path: string): string | undefined {
  // The real Hub sends a STRING equal to snapshot_hash. Tolerate a legacy finite number by
  // coercing to its string form so older cached/replayed payloads still parse.
  if (value === undefined || value === null) return undefined;
  if (typeof value === 'number' && Number.isFinite(value)) return String(value);
  return optionalString(value, path);
}

function parseWorkflowRequirements(value: unknown): fieldwork.WorkflowRequirements | undefined {
  if (value === undefined || value === null) return undefined;
  if (!isRecord(value)) throw new HubResponseError('workflow_requirements must be an object');
  return fieldwork.parseWorkflowRequirements(value);
}

/** Tolerant status parse: unknown/malformed values yield undefined — never a wire-break. */
function parseStatus(value: unknown): AssignmentStatus | undefined {
  if (typeof value !== 'string') return undefined;
  const normalized = value
    .trim()
    .toLowerCase()
    .replace(/[\s-]+/g, '_');
  return (KNOWN_ASSIGNMENT_STATUSES as readonly string[]).includes(normalized)
    ? (normalized as AssignmentStatus)
    : undefined;
}

function parseGpsPoint(value: unknown): AssignmentGpsPoint | undefined {
  if (!isRecord(value)) return undefined;
  const { lat, lon } = value;
  if (
    typeof lat === 'number' &&
    Number.isFinite(lat) &&
    typeof lon === 'number' &&
    Number.isFinite(lon)
  ) {
    return { lat, lon };
  }
  return undefined;
}

/**
 * Validation-only coordinates from Hub `coordinates` ({primary, wells[]}). Tolerant: anything
 * malformed is simply dropped (no throw) — assignment display must never fail on optional geo.
 */
function parseCoordinates(value: unknown): AssignmentCoordinates | undefined {
  if (!isRecord(value)) return undefined;
  const primary = parseGpsPoint(value.primary);
  const rawWells = Array.isArray(value.wells) ? value.wells : [];
  const wells: AssignmentWellCoordinate[] = [];
  for (const raw of rawWells) {
    const point = parseGpsPoint(raw);
    if (point === undefined) continue;
    const wellId = isRecord(raw)
      ? firstString(raw, 'coordinates.wells', ['well_id', 'wellId', 'id'])
      : undefined;
    wells.push({ ...point, ...(wellId !== undefined ? { wellId } : {}) });
  }
  if (primary === undefined && wells.length === 0) return undefined;
  return { ...(primary !== undefined ? { primary } : {}), wells };
}

function parseGeofenceHints(value: unknown): AssignmentGeofenceHints | undefined {
  if (!isRecord(value)) return undefined;
  const radiusM =
    typeof value.radius_m === 'number' && Number.isFinite(value.radius_m)
      ? value.radius_m
      : undefined;
  const required = value.required === true;
  // The real Hub sends source: "" when there are no coordinates; tolerate it (never throw).
  const source =
    typeof value.source === 'string' && value.source.trim().length > 0
      ? value.source.trim()
      : undefined;
  if (radiusM === undefined && !required && source === undefined) return undefined;
  return {
    required,
    ...(radiusM !== undefined ? { radiusM } : {}),
    ...(source !== undefined ? { source } : {}),
  };
}

function withDetail<T extends keyof AssignmentDetails>(
  details: AssignmentDetails,
  key: T,
  value: AssignmentDetails[T] | undefined,
): void {
  if (value !== undefined) details[key] = value;
}

export function parseAssignmentDetails(
  entry: Record<string, unknown>,
): AssignmentDetails | undefined {
  const details: AssignmentDetails = {};
  withDetail(
    details,
    'requestNo',
    optionalString(entry.request_no ?? entry.requestNo, 'request_no'),
  );
  withDetail(details, 'status', parseStatus(entry.status));
  withDetail(details, 'customer', parseNamedRef(entry.customer, 'customer', ['customer_id', 'id']));
  withDetail(details, 'lease', parseNamedRef(entry.lease, 'lease', ['lease_id', 'id']));
  withDetail(details, 'wells', parseWells(entry.wells, 'wells'));
  withDetail(details, 'material', parseMaterial(entry.material, 'material'));
  withDetail(
    details,
    'disposalSite',
    parseDisposalSite(entry.disposal_site ?? entry.disposalSite, 'disposal_site'),
  );
  // The real Hub sends the driver-facing vehicle label as `truck_no` (e.g. "Truck 12"), not
  // `name`; prefer it so the driver sees the truck number instead of a falling-back-to-id UUID.
  withDetail(
    details,
    'vehicle',
    parseNamedRef(
      entry.vehicle,
      'vehicle',
      ['vehicle_id', 'id'],
      ['truck_no', 'name', 'label', 'display_name'],
    ),
  );
  withDetail(details, 'trailer', parseNamedRef(entry.trailer, 'trailer', ['trailer_id', 'id']));
  withDetail(
    details,
    'jobType',
    parseNamedRef(entry.job_type ?? entry.jobType, 'job_type', ['job_type_id', 'id']),
  );
  withDetail(details, 'coordinates', parseCoordinates(entry.coordinates));
  withDetail(
    details,
    'geofenceHints',
    parseGeofenceHints(entry.geofence_hints ?? entry.geofenceHints),
  );
  withDetail(
    details,
    'workflowRequirements',
    parseWorkflowRequirements(entry.workflow_requirements ?? entry.workflowRequirements),
  );
  return Object.keys(details).length > 0 ? details : undefined;
}

export function parseHubAssignmentEntry(entry: unknown, indexLabel = 'assignment'): HubAssignment {
  if (!isRecord(entry)) {
    throw new HubResponseError(`${indexLabel} is not an object`);
  }
  const serviceRequestId = optionalString(
    entry.service_request_id,
    `${indexLabel}.service_request_id`,
  );
  const snapshotHash = optionalString(entry.snapshot_hash, `${indexLabel}.snapshot_hash`);
  if (serviceRequestId === undefined || snapshotHash === undefined) {
    throw new HubResponseError(`${indexLabel} is missing service_request_id and/or snapshot_hash`);
  }
  const latestServerVersion = parseLatestServerVersion(
    entry.latest_server_version ?? entry.latestServerVersion,
    `${indexLabel}.latest_server_version`,
  );
  const details = parseAssignmentDetails(entry);
  return {
    serviceRequestId,
    snapshotHash,
    snapshot: entry.snapshot ?? null,
    ...(latestServerVersion !== undefined ? { latestServerVersion } : {}),
    ...(details !== undefined ? { details } : {}),
  };
}

function workflowRequirementsFromSnapshot(snapshot: unknown): fieldwork.WorkflowRequirements {
  const config =
    isRecord(snapshot) && snapshot.workflow_requirements !== undefined
      ? snapshot.workflow_requirements
      : snapshot;
  return fieldwork.parseWorkflowRequirements(config);
}

export function parseWorkflowRequirementsFromAssignments(
  assignments: readonly HubAssignment[],
  serviceRequestId?: string,
): fieldwork.WorkflowRequirements {
  const assignment =
    serviceRequestId !== undefined
      ? assignments.find((a) => a.serviceRequestId === serviceRequestId)
      : assignments[0];
  if (assignment?.details?.workflowRequirements !== undefined) {
    return assignment.details.workflowRequirements;
  }
  return workflowRequirementsFromSnapshot(assignment?.snapshot);
}

/**
 * Whether a job is a flowback job, by its SR `job_type` name. The customer signature is required
 * ONLY for flowback (item 6); every other job type neither shows nor requires it. Isolated here as
 * one small predicate so the flowback rule is trivial to tweak in one place.
 */
export const isFlowbackJob = (jobType?: string): boolean =>
  (jobType ?? '').toLowerCase().includes('flowback');
