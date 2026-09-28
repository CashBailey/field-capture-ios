import { describe, it, expect } from "vitest";
import {
  checkTicketSubmitAllowed,
  checkVehicleSafeToOperate,
  dvirCertifiesUnsafe,
  parseWorkflowRequirements,
  validateFormCompletion,
  type DvirForm,
  type JhaForm,
  type WorkflowRequirements,
} from "../src/fieldwork/index.js";

function dvir(overrides?: Partial<DvirForm>): DvirForm {
  return {
    formId: "dvir-1",
    kind: "pre-trip-dvir",
    vehicleRef: "truck-7",
    items: [
      { itemId: "brakes", label: "Brakes", result: "ok" },
      { itemId: "lights", label: "Lights", result: "ok" },
    ],
    signatureBlobIds: ["sig-blob-1"],
    ...overrides,
  };
}

function jha(overrides?: Partial<JhaForm>): JhaForm {
  return {
    formId: "jha-1",
    kind: "jha-jsa",
    serviceRequestId: "sr-9",
    hazards: [{ hazardId: "h1", description: "H2S exposure", mitigation: "monitor + PPE" }],
    signatureBlobIds: ["sig-blob-2"],
    ...overrides,
  };
}

describe("validateFormCompletion — DVIR", () => {
  it("a fully answered, signed DVIR is completable", () => {
    expect(validateFormCompletion(dvir())).toEqual([]);
  });

  it("unanswered items block completion (drafts may stay incomplete)", () => {
    const form = dvir({ items: [{ itemId: "brakes", label: "Brakes" }] });
    expect(validateFormCompletion(form)).toContain("inspection item brakes is unanswered");
  });

  it("a defect requires a note AND a safe-to-operate certification", () => {
    const form = dvir({
      items: [{ itemId: "brakes", label: "Brakes", result: "defect" }],
    });
    const errors = validateFormCompletion(form);
    expect(errors).toContain("defect on brakes needs a note");
    expect(errors).toContain("defects present: safe-to-operate certification is required");

    const certified = dvir({
      items: [{ itemId: "brakes", label: "Brakes", result: "defect", note: "pads worn" }],
      defectsCertifiedSafe: false, // certifying NOT safe is a valid, complete answer
    });
    expect(validateFormCompletion(certified)).toEqual([]);
  });

  it("an unsigned DVIR is never complete", () => {
    expect(validateFormCompletion(dvir({ signatureBlobIds: [] }))).toContain(
      "DVIR needs the driver's signature",
    );
  });

  it("an empty checklist is never complete", () => {
    expect(validateFormCompletion(dvir({ items: [] }))).toContain(
      "DVIR needs at least one inspection item",
    );
  });
});

describe("validateFormCompletion — JHA/JSA", () => {
  it("a hazard-listed, signed JHA is completable", () => {
    expect(validateFormCompletion(jha())).toEqual([]);
  });

  it("requires at least one hazard with description and mitigation", () => {
    expect(validateFormCompletion(jha({ hazards: [] }))).toContain(
      "JHA needs at least one hazard",
    );
    expect(
      validateFormCompletion(
        jha({ hazards: [{ hazardId: "h1", description: "", mitigation: "" }] }),
      ),
    ).toEqual(
      expect.arrayContaining(["hazard h1 has no description", "hazard h1 has no mitigation"]),
    );
  });

  it("an unsigned JHA is never complete (signatures are the safety evidence)", () => {
    expect(validateFormCompletion(jha({ signatureBlobIds: [] }))).toContain(
      "JHA needs at least one signature",
    );
  });
});

describe("parseWorkflowRequirements", () => {
  it("reads the real Hub shape { clock_in_required, required_steps[] }", () => {
    expect(
      parseWorkflowRequirements({
        clock_in_required: true,
        required_steps: ["pre_trip_dvir", "jha", "post_trip_dvir"],
      }),
    ).toEqual({
      clockInRequired: true,
      requiredSteps: ["pre_trip_dvir", "jha", "post_trip_dvir"],
    });
  });

  it("ignores unknown steps and returns required_steps in canonical order", () => {
    expect(
      parseWorkflowRequirements({
        clock_in_required: true,
        required_steps: ["jha", "made_up_step", "pre_trip_dvir"],
      }),
    ).toEqual({
      clockInRequired: true,
      requiredSteps: ["pre_trip_dvir", "jha"],
    });
  });

  it("tolerates legacy boolean keys from snapshots predating required_steps[]", () => {
    expect(
      parseWorkflowRequirements({
        require_pre_trip_dvir: true,
        require_jha_per_sr: true,
      }),
    ).toEqual({
      clockInRequired: false,
      requiredSteps: ["pre_trip_dvir", "jha"],
    });
  });

  it("absent or malformed config means NOT required — Hub re-validates on submit anyway", () => {
    const none: WorkflowRequirements = {
      clockInRequired: false,
      requiredSteps: [],
    };
    expect(parseWorkflowRequirements(undefined)).toEqual(none);
    expect(parseWorkflowRequirements(null)).toEqual(none);
    expect(parseWorkflowRequirements("garbage")).toEqual(none);
    expect(parseWorkflowRequirements({ required_steps: "not-a-list" })).toEqual(none);
    expect(parseWorkflowRequirements({ require_pre_trip_dvir: "yes" })).toEqual(none);
  });
});

describe("checkTicketSubmitAllowed", () => {
  const ALL_REQUIRED: WorkflowRequirements = {
    clockInRequired: true,
    requiredSteps: ["pre_trip_dvir", "jha", "post_trip_dvir"],
  };

  it("blocks with the exact missing steps", () => {
    const gate = checkTicketSubmitAllowed(
      ALL_REQUIRED,
      { jhaFormIdByServiceRequest: {} },
      "sr-9",
    );
    expect(gate).toEqual({ allowed: false, missing: ["pre-trip-dvir", "jha-jsa"] });
  });

  it("a JHA for a DIFFERENT SR does not satisfy this SR", () => {
    const gate = checkTicketSubmitAllowed(
      ALL_REQUIRED,
      { preTripDvirFormId: "dvir-1", jhaFormIdByServiceRequest: { "sr-other": "jha-x" } },
      "sr-9",
    );
    expect(gate).toEqual({ allowed: false, missing: ["jha-jsa"] });
  });

  it("allows when every required step is complete (post-trip never gates tickets)", () => {
    const gate = checkTicketSubmitAllowed(
      ALL_REQUIRED,
      { preTripDvirFormId: "dvir-1", jhaFormIdByServiceRequest: { "sr-9": "jha-1" } },
      "sr-9",
    );
    expect(gate).toEqual({ allowed: true });
  });

  it("nothing required → always allowed", () => {
    expect(
      checkTicketSubmitAllowed(
        { clockInRequired: true, requiredSteps: [] },
        { jhaFormIdByServiceRequest: {} },
        "sr-9",
      ),
    ).toEqual({ allowed: true });
  });

  it("post-trip-only requirement never gates ticket submission", () => {
    expect(
      checkTicketSubmitAllowed(
        { clockInRequired: true, requiredSteps: ["post_trip_dvir"] },
        { jhaFormIdByServiceRequest: {} },
        "sr-9",
      ),
    ).toEqual({ allowed: true });
  });
});

describe("unsafe-vehicle rule", () => {
  it("dvirCertifiesUnsafe is true only when a defect was certified NOT safe", () => {
    expect(dvirCertifiesUnsafe(dvir({ defectsCertifiedSafe: false }))).toBe(true);
    expect(dvirCertifiesUnsafe(dvir({ defectsCertifiedSafe: true }))).toBe(false);
    expect(dvirCertifiesUnsafe(dvir())).toBe(false); // no certification → not unsafe
  });

  it("blocks field work and requires review when the pre-trip DVIR certified the vehicle unsafe", () => {
    expect(
      checkVehicleSafeToOperate({ preTripVehicleUnsafe: true, jhaFormIdByServiceRequest: {} }),
    ).toEqual({ safe: false, reason: "pre-trip-dvir-unsafe", reviewRequired: true });
  });

  it("is safe when the vehicle was not certified unsafe (absent or false flag)", () => {
    expect(checkVehicleSafeToOperate({ jhaFormIdByServiceRequest: {} })).toEqual({ safe: true });
    expect(
      checkVehicleSafeToOperate({ preTripVehicleUnsafe: false, jhaFormIdByServiceRequest: {} }),
    ).toEqual({ safe: true });
  });
});
