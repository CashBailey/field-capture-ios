import { describe, it, expect } from "vitest";
import {
  canEditSr,
  applyWorkStart,
  appendSignature,
  editDraftTicket,
  submitTicket,
  amendTicket,
  isActorAuthorized,
  assertActorAuthorized,
  reassignOwner,
  setAssistants,
  resolveWorkStart,
  appendAttachment,
  canPurgeAttachment,
  FieldworkRuleError,
  type ServiceRequest,
  type WorkStartEvent,
  type JhaJsaSignature,
  type FieldTicket,
  type PhotoAttachment,
} from "../src/fieldwork/index.js";

function sr(over: Partial<ServiceRequest> = {}): ServiceRequest {
  return {
    srId: "sr-1",
    version: 1,
    ownerRef: "emp-1",
    assistantRefs: [],
    lockState: "unlocked",
    workStartedAt: null,
    lockedByEventId: null,
    ...over,
  };
}

describe("SR lock invariant", () => {
  it("is editable while unlocked, not after lock", () => {
    const open = sr();
    expect(canEditSr(open)).toBe(true);

    const event: WorkStartEvent = {
      eventId: "ev-1",
      srId: "sr-1",
      kind: "jhajsa-signed",
      actorRef: "emp-1",
      occurredAt: "2026-06-07T12:00:00.000Z",
    };
    const locked = applyWorkStart(open, event);
    expect(locked.lockState).toBe("locked");
    expect(locked.workStartedAt).toBe(event.occurredAt);
    expect(locked.lockedByEventId).toBe("ev-1");
    expect(canEditSr(locked)).toBe(false);
  });

  it("the first work-start event locks; later events do not re-lock or change the locker", () => {
    const first = applyWorkStart(sr(), {
      eventId: "ev-1",
      srId: "sr-1",
      kind: "arrived",
      actorRef: "emp-1",
      occurredAt: "t1",
    });
    const second = applyWorkStart(first, {
      eventId: "ev-2",
      srId: "sr-1",
      kind: "field-ticket-started",
      actorRef: "emp-2",
      occurredAt: "t2",
    });
    expect(second.lockedByEventId).toBe("ev-1");
    expect(second.workStartedAt).toBe("t1");
  });

  it("does not mutate the input SR", () => {
    const open = sr();
    applyWorkStart(open, { eventId: "ev-1", srId: "sr-1", kind: "arrived", actorRef: "e", occurredAt: "t" });
    expect(open.lockState).toBe("unlocked");
  });

  it("rejects an event for a different SR", () => {
    expect(() =>
      applyWorkStart(sr(), { eventId: "ev", srId: "other", kind: "arrived", actorRef: "e", occurredAt: "t" }),
    ).toThrow(FieldworkRuleError);
  });
});

describe("JHA/JSA signatures are append-only", () => {
  const a: JhaJsaSignature = { signatureId: "s1", srId: "sr-1", signerRef: "e1", signatureBlobId: "b1", signedAt: "t1" };
  const b: JhaJsaSignature = { signatureId: "s2", srId: "sr-1", signerRef: "e2", signatureBlobId: "b2", signedAt: "t2" };

  it("appends multiple signers", () => {
    const list = appendSignature(appendSignature([], a), b);
    expect(list.map((s) => s.signatureId)).toEqual(["s1", "s2"]);
  });

  it("refuses to overwrite an existing signatureId", () => {
    expect(() => appendSignature([a], { ...a, signerRef: "hacker" })).toThrow(/append-only/);
  });
});

describe("field ticket draft/submit immutability", () => {
  const draft: FieldTicket = {
    fieldTicketId: "ft-1",
    srId: "sr-1",
    version: 1,
    state: "draft",
    createdAt: "t0",
    submittedAt: null,
    fields: { volume: 10 },
  };

  it("edits bump version while draft", () => {
    const edited = editDraftTicket(draft, { volume: 20, well: "W-7" });
    expect(edited.version).toBe(2);
    expect(edited.fields).toEqual({ volume: 20, well: "W-7" });
  });

  it("submitted tickets are immutable except via amendment", () => {
    const submitted = submitTicket(draft, "t1");
    expect(submitted.state).toBe("submitted");
    expect(() => editDraftTicket(submitted, { volume: 99 })).toThrow(/immutable/);
    expect(() => submitTicket(submitted, "t2")).toThrow(/already/);
  });
});

describe("ticket amendment (correction workflow)", () => {
  const submitted: FieldTicket = {
    fieldTicketId: "ft-1",
    srId: "sr-1",
    version: 2,
    state: "submitted",
    createdAt: "t0",
    submittedAt: "t1",
    fields: { volume: 20 },
  };

  it("amends a submitted ticket -> amended, bumps version, merges fields", () => {
    const amended = amendTicket(submitted, { volume: 25 }, "t2");
    expect(amended.state).toBe("amended");
    expect(amended.version).toBe(3);
    expect(amended.fields).toEqual({ volume: 25 });
  });

  it("allows re-amendment of an already-amended ticket", () => {
    const twice = amendTicket(amendTicket(submitted, { a: 1 }, "t2"), { b: 2 }, "t3");
    expect(twice.state).toBe("amended");
    expect(twice.version).toBe(4);
  });

  it("refuses to amend a draft (submit first)", () => {
    const draft: FieldTicket = { ...submitted, state: "draft", submittedAt: null };
    expect(() => amendTicket(draft, {}, "t2")).toThrow(/only submitted tickets/);
  });
});

describe("SR assignment + authorization", () => {
  it("authorizes the owner and assistants, rejects others", () => {
    const s = sr({ ownerRef: "owner", assistantRefs: ["asst"] });
    expect(isActorAuthorized(s, "owner")).toBe(true);
    expect(isActorAuthorized(s, "asst")).toBe(true);
    expect(isActorAuthorized(s, "stranger")).toBe(false);
    expect(() => assertActorAuthorized(s, "stranger")).toThrow(FieldworkRuleError);
  });

  it("reassigns owner / sets assistants only while unlocked, bumping version", () => {
    const open = sr({ version: 1 });
    expect(reassignOwner(open, "owner2")).toMatchObject({ ownerRef: "owner2", version: 2 });
    expect(setAssistants(open, ["a", "b"])).toMatchObject({
      assistantRefs: ["a", "b"],
      version: 2,
    });
    const locked = sr({ lockState: "locked" });
    expect(() => reassignOwner(locked, "x")).toThrow(/locked/);
    expect(() => setAssistants(locked, ["x"])).toThrow(/locked/);
  });
});

describe("resolveWorkStart escalation (ADR 004 / report 03)", () => {
  const event: WorkStartEvent = {
    eventId: "ev-1",
    srId: "sr-1",
    kind: "arrived",
    actorRef: "emp-1",
    occurredAt: "t1",
  };

  it("locks when an unlocked SR gets a work-start from a currently-authorized actor", () => {
    const out = resolveWorkStart(sr(), event, new Set(["emp-1"]));
    expect(out.decision).toBe("locked");
    if (out.decision === "locked") expect(out.sr.lockState).toBe("locked");
  });

  it("treats a work-start on an already-locked SR as evidence only", () => {
    const out = resolveWorkStart(
      sr({ lockState: "locked", lockedByEventId: "ev-0" }),
      event,
      new Set(["emp-1"]),
    );
    expect(out.decision).toBe("evidence-only");
  });

  it("escalates to needs-review when the actor is no longer authorized, NEVER locking", () => {
    const out = resolveWorkStart(sr({ ownerRef: "newOwner", assistantRefs: [] }), event, new Set(["newOwner"]));
    expect(out.decision).toBe("needs-review");
    if (out.decision === "needs-review") {
      expect(out.trigger).toBe("offline-work-start-after-reassignment");
      expect(out.sr.lockState).toBe("unlocked"); // the phone never retroactively wins authority
    }
  });

  it("rejects an event for a different SR", () => {
    expect(() => resolveWorkStart(sr(), { ...event, srId: "other" }, new Set(["emp-1"]))).toThrow(
      FieldworkRuleError,
    );
  });
});

describe("photo attachments are append-only + purge-gated", () => {
  const att = (over: Partial<PhotoAttachment> = {}): PhotoAttachment => ({
    attachmentId: "att-1",
    blobId: "b1",
    sha256: "abc",
    kind: "field-ticket-photo",
    parentType: "field-ticket",
    parentId: "ft-1",
    capturedAt: "t1",
    hubConfirmed: false,
    ...over,
  });

  it("appends distinct attachments, refuses a duplicate attachmentId", () => {
    const list = appendAttachment([], att());
    expect(list).toHaveLength(1);
    expect(() => appendAttachment(list, att({ blobId: "other" }))).toThrow(/append-only/);
  });

  it("is purgeable only once Hub confirms upload + link", () => {
    expect(canPurgeAttachment(att())).toBe(false);
    expect(canPurgeAttachment(att({ hubConfirmed: true }))).toBe(true);
  });
});
