/**
 * DVIR / JHA-JSA field-form contracts + the workflow-step gate (field-day-workflow.md):
 * pre-trip DVIR at day start, a JHA/JSA per Service Request BEFORE work, post-trip DVIR at day
 * end. Completed forms sync as APPEND-ONLY evidence (ADR 004 — never overwritten, never
 * auto-merged); Hub config decides which steps are REQUIRED before a field ticket may be
 * submitted. Pure types + validation — no storage, no network, no UI here.
 */

export class FieldFormError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "FieldFormError";
  }
}

export type FieldFormKind = "pre-trip-dvir" | "jha-jsa" | "post-trip-dvir";

export type InspectionResult = "ok" | "defect" | "not-applicable";

export interface InspectionItem {
  itemId: string;
  label: string;
  /** Unanswered items stay undefined — a draft is allowed to be incomplete; completion is not. */
  result?: InspectionResult;
  /** Required when result is "defect" — a defect with no description is unactionable. */
  note?: string;
}

/** Driver Vehicle Inspection Report (pre- or post-trip). */
export interface DvirForm {
  formId: string;
  kind: "pre-trip-dvir" | "post-trip-dvir";
  vehicleRef: string;
  odometer?: number;
  items: InspectionItem[];
  /**
   * Required (either value) once any item is a defect: the driver certifies the vehicle is
   * still safe to operate (true) or not (false). Never defaulted.
   */
  defectsCertifiedSafe?: boolean;
  /** Signature blob ids (capture flow). At least one required to complete. */
  signatureBlobIds: string[];
  signatures?: SignatureRecord[];
  completedAt?: string;
}

export interface JhaHazard {
  hazardId: string;
  description: string;
  mitigation: string;
}

/** Compliance metadata bound to a captured signature (ESIGN/UETA/FMCSA functional standard:
 * attribution, intent, consent, device/audit). The drawn artifact is the blob at `blobId`. */
export interface SignatureRecord {
  blobId: string;
  signerName: string;
  signerUserId?: string;
  /** Driver-facing role at signing time, e.g. Driver, Owner, Additional Crew. */
  signerRole?: string;
  /** ISO-8601 UTC. */
  signedAtUtc: string;
  /** The exact certification/intent statement the signer approved. */
  certificationText: string;
  /** Proof of consent to sign electronically (15 USC 7001(c)). Always true once captured. */
  consentToElectronicSignature: true;
  deviceInstanceId: string;
  appVersion: string;
}

export const DVIR_PRETRIP_CERTIFICATION_TEXT =
  'I confirm this pre-trip inspection is complete and accurate.';
export const DVIR_POSTTRIP_CERTIFICATION_TEXT =
  'I confirm this post-trip inspection is complete and accurate.';
export const JHA_CERTIFICATION_TEXT =
  'I confirm the hazards and controls for this job were reviewed.';

/** Job Hazard / Job Safety Analysis for one Service Request. */
export interface JhaForm {
  formId: string;
  kind: "jha-jsa";
  serviceRequestId: string;
  hazards: JhaHazard[];
  /** Signature blob ids (append-only evidence — ADR 004 signatures are never deleted). */
  signatureBlobIds: string[];
  /** Signature compliance records (one per signer); each blobId also appears in signatureBlobIds. */
  signatures?: SignatureRecord[];
  completedAt?: string;
}

export type FieldForm = DvirForm | JhaForm;

/**
 * Completion validation: the list of human-readable reasons a form may NOT be marked complete
 * (empty = completable). Drafts may violate all of these — the gate is at completion time.
 */
export function validateFormCompletion(form: FieldForm): string[] {
  const errors: string[] = [];
  if (!form.formId) errors.push("formId is required");
  if (form.kind === "jha-jsa") {
    if (!form.serviceRequestId) errors.push("JHA must reference a service request");
    if (form.hazards.length === 0) errors.push("JHA needs at least one hazard");
    for (const hazard of form.hazards) {
      if (!hazard.description) errors.push(`hazard ${hazard.hazardId} has no description`);
      if (!hazard.mitigation) errors.push(`hazard ${hazard.hazardId} has no mitigation`);
    }
    if (form.signatureBlobIds.length === 0) errors.push("JHA needs at least one signature");
  } else {
    if (!form.vehicleRef) errors.push("DVIR must reference a vehicle");
    if (form.items.length === 0) errors.push("DVIR needs at least one inspection item");
    for (const item of form.items) {
      if (item.result === undefined) errors.push(`inspection item ${item.itemId} is unanswered`);
      if (item.result === "defect" && (item.note === undefined || item.note.trim() === "")) {
        errors.push(`defect on ${item.itemId} needs a note`);
      }
    }
    const hasDefect = form.items.some((i) => i.result === "defect");
    if (hasDefect && form.defectsCertifiedSafe === undefined) {
      errors.push("defects present: safe-to-operate certification is required");
    }
    if (form.signatureBlobIds.length === 0) errors.push("DVIR needs the driver's signature");
  }
  return errors;
}

// ---- workflow-step gate (Hub-configured) ----

/**
 * Hub workflow step identifiers — the real Hub `SrWorkflowStep.step_type` values
 * (opshub `sync/workflow.py`, `sync/protocol.py`). Kept as the Hub's own strings so the
 * gate maps 1:1 to `workflow_requirements.required_steps[]` with no client-side translation.
 */
export type WorkflowStepType = "pre_trip_dvir" | "jha" | "post_trip_dvir";

const KNOWN_WORKFLOW_STEPS: readonly WorkflowStepType[] = [
  "pre_trip_dvir",
  "jha",
  "post_trip_dvir",
];

/**
 * Which steps Hub requires before a field ticket may be submitted. Hub is authoritative.
 * Mirrors the real Hub `workflow_requirements` wire shape (opshub `sync/snapshots.py`):
 * `{ clock_in_required: bool, required_steps: string[] }`. The clock-in gate is enforced
 * separately from Hub session-status truth, so `clockInRequired` here is informational only.
 */
export interface WorkflowRequirements {
  clockInRequired: boolean;
  requiredSteps: WorkflowStepType[];
}

/**
 * Parse Hub's `workflow_requirements` from an untyped snapshot/config blob. ABSENT or malformed
 * fields default to NOT required: the gate is a UX guard, Hub still authoritatively re-validates
 * every submit — inventing a requirement Hub never set would block legitimate work offline.
 * Unknown `required_steps` entries are ignored; legacy boolean keys (older snapshots, pre
 * `required_steps[]`) are tolerated so cached payloads still gate correctly.
 */
export function parseWorkflowRequirements(value: unknown): WorkflowRequirements {
  const rec =
    typeof value === "object" && value !== null && !Array.isArray(value)
      ? (value as Record<string, unknown>)
      : {};
  const rawSteps = Array.isArray(rec.required_steps) ? rec.required_steps : [];
  const present = new Set<unknown>(rawSteps);
  // Tolerate legacy boolean keys from snapshots that predate required_steps[].
  if (rec.require_pre_trip_dvir === true) present.add("pre_trip_dvir");
  if (rec.require_jha_per_sr === true) present.add("jha");
  if (rec.require_post_trip_dvir === true) present.add("post_trip_dvir");
  return {
    clockInRequired: rec.clock_in_required === true,
    requiredSteps: KNOWN_WORKFLOW_STEPS.filter((step) => present.has(step)),
  };
}

/** The steps a worker has completed so far (form ids of COMPLETED forms). */
export interface CompletedWorkflowSteps {
  preTripDvirFormId?: string;
  /**
   * True when the completed pre-trip DVIR certified the vehicle NOT safe to operate
   * (`defectsCertifiedSafe === false`). Drives the unsafe-vehicle rule below.
   */
  preTripVehicleUnsafe?: boolean;
  /** serviceRequestId → completed JHA formId. */
  jhaFormIdByServiceRequest: Readonly<Record<string, string>>;
}

export type TicketSubmitGate =
  | { allowed: true }
  | { allowed: false; missing: FieldFormKind[] };

/**
 * May a field ticket for `serviceRequestId` be submitted? Blocks ONLY on steps Hub requires
 * that are not complete. (Post-trip DVIR gates the END of day, not ticket submission.)
 */
export function checkTicketSubmitAllowed(
  requirements: WorkflowRequirements,
  completed: CompletedWorkflowSteps,
  serviceRequestId: string,
): TicketSubmitGate {
  const missing: FieldFormKind[] = [];
  if (
    requirements.requiredSteps.includes("pre_trip_dvir") &&
    completed.preTripDvirFormId === undefined
  ) {
    missing.push("pre-trip-dvir");
  }
  if (
    requirements.requiredSteps.includes("jha") &&
    completed.jhaFormIdByServiceRequest[serviceRequestId] === undefined
  ) {
    missing.push("jha-jsa");
  }
  return missing.length === 0 ? { allowed: true } : { allowed: false, missing };
}

/** Whether a DVIR certified the vehicle NOT safe to operate (a defect the driver did not clear). */
export function dvirCertifiesUnsafe(form: DvirForm): boolean {
  return form.defectsCertifiedSafe === false;
}

export type VehicleSafetyGate =
  | { safe: true }
  | { safe: false; reason: "pre-trip-dvir-unsafe"; reviewRequired: true };

/**
 * The unsafe-vehicle rule (field-day-workflow): when the completed pre-trip DVIR certified the
 * vehicle NOT safe to operate, field work is blocked for the day and the SR must be escalated to
 * Hub review. The phone never overrides this locally — it is a hard safety gate, distinct from the
 * Hub-configured workflow-step gate. Captured at DVIR completion, enforced here.
 */
export function checkVehicleSafeToOperate(completed: CompletedWorkflowSteps): VehicleSafetyGate {
  return completed.preTripVehicleUnsafe === true
    ? { safe: false, reason: "pre-trip-dvir-unsafe", reviewRequired: true }
    : { safe: true };
}
