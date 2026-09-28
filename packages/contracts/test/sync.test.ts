import { describe, it, expect } from "vitest";
import {
  buildIdempotencyKey,
  assertEnvelopeConsistent,
  OutboxError,
  canTransition,
  assertTransition,
  markInFlight,
  markForRetry,
  applyCommandResult,
  planDispatch,
  committedTokens,
  isTokenNewer,
  maxToken,
  advanceFrontier,
  ChangeTokenError,
  isBlobPurgeable,
  advanceBlob,
  assertLinkAllowed,
  purgeableBlobs,
  AttachmentError,
  localActionFor,
  isRejectionCode,
  REVIEW_TRIGGERS,
  type ChangeToken,
  type CommandResult,
  type OperationEnvelope,
  type OutboxItem,
  type OutboxItemState,
  type BlobRecord,
} from "../src/sync/index";

// ---- helpers ----

function env(
  over: Partial<OperationEnvelope> & { opId: string; localSeq: number },
): OperationEnvelope {
  return {
    kind: "command",
    type: "sr.edit",
    idempotencyKey: buildIdempotencyKey("devA", over.localSeq, over.opId),
    dependsOn: [],
    payload: {},
    ...over,
  };
}

function item(
  envelope: OperationEnvelope,
  state: OutboxItemState = "pending",
  extra: Partial<OutboxItem> = {},
): OutboxItem {
  return { envelope, state, retryCount: 0, ...extra };
}

const TOKEN: ChangeToken = { authorityEpoch: 1, commitSeq: 42 };

// ---- envelope consistency ----

describe("assertEnvelopeConsistent", () => {
  it("accepts a coherent command envelope", () => {
    expect(() => assertEnvelopeConsistent(env({ opId: "op1", localSeq: 1 }))).not.toThrow();
  });

  it("rejects a localSeq that disagrees with the idempotency key", () => {
    const e = env({ opId: "op1", localSeq: 1 });
    expect(() => assertEnvelopeConsistent({ ...e, localSeq: 2 })).toThrow(OutboxError);
  });

  it("rejects a self-dependency and duplicate dependsOn", () => {
    expect(() =>
      assertEnvelopeConsistent(env({ opId: "op1", localSeq: 1, dependsOn: ["op1"] })),
    ).toThrow(/depends on itself/);
    expect(() =>
      assertEnvelopeConsistent(env({ opId: "op1", localSeq: 1, dependsOn: ["a", "a"] })),
    ).toThrow(/duplicate dependsOn/);
  });

  it("rejects an immutable event that carries a precondition", () => {
    const e = env({ opId: "op1", localSeq: 1, kind: "event", precondition: { baseVersion: 3 } });
    expect(() => assertEnvelopeConsistent(e)).toThrow(/append-only/);
  });

  it("rejects a negative or non-integer localSeq", () => {
    // localSeq is validated before the key is parsed, so a hand-built envelope is enough.
    const e = env({ opId: "op1", localSeq: 0 });
    expect(() => assertEnvelopeConsistent({ ...e, localSeq: -1 })).toThrow(OutboxError);
  });
});

// ---- outbox state machine ----

describe("outbox state machine", () => {
  it("permits only the documented transitions", () => {
    expect(canTransition("pending", "in-flight")).toBe(true);
    expect(canTransition("in-flight", "accepted")).toBe(true);
    expect(canTransition("in-flight", "pending")).toBe(true);
    expect(canTransition("pending", "accepted")).toBe(false); // must dispatch first
    expect(canTransition("accepted", "pending")).toBe(false); // terminal
  });

  it("markInFlight then applyCommandResult(accepted) records the token", () => {
    const sent = markInFlight(item(env({ opId: "op1", localSeq: 1 })));
    expect(sent.state).toBe("in-flight");
    const result: CommandResult = { outcome: "accepted", opId: "op1", token: TOKEN };
    const done = applyCommandResult(sent, result);
    expect(done.state).toBe("accepted");
    expect(done.committedToken).toEqual(TOKEN);
  });

  it("accept cannot skip in-flight (pending -> accepted throws)", () => {
    const pending = item(env({ opId: "op1", localSeq: 1 }));
    const result: CommandResult = { outcome: "accepted", opId: "op1", token: TOKEN };
    expect(() => applyCommandResult(pending, result)).toThrow(/illegal outbox transition/);
  });

  it("rejected and needs-review fold in their reasons", () => {
    const sent = markInFlight(item(env({ opId: "op1", localSeq: 1 })));
    const rejected = applyCommandResult(sent, {
      outcome: "rejected",
      opId: "op1",
      rejectionCode: "stale_version",
    });
    expect(rejected.state).toBe("rejected");
    expect(rejected.rejectionCode).toBe("stale_version");
    const review = applyCommandResult(sent, {
      outcome: "needs-review",
      opId: "op1",
      reviewReason: "competing-work-start-evidence",
    });
    expect(review.state).toBe("needs-review");
  });

  it("markForRetry returns an item to pending and bumps retryCount", () => {
    const sent = markInFlight(item(env({ opId: "op1", localSeq: 1 })));
    const retried = markForRetry(sent);
    expect(retried.state).toBe("pending");
    expect(retried.retryCount).toBe(1);
    expect(() => markForRetry(item(env({ opId: "op2", localSeq: 2 })))).toThrow(); // pending->pending illegal
  });

  it("rejects a CommandResult whose opId does not match the item", () => {
    const sent = markInFlight(item(env({ opId: "op1", localSeq: 1 })));
    expect(() =>
      applyCommandResult(sent, { outcome: "accepted", opId: "other", token: TOKEN }),
    ).toThrow(/does not match/);
  });

  it("does not mutate its input", () => {
    const original = item(env({ opId: "op1", localSeq: 1 }));
    markInFlight(original);
    expect(original.state).toBe("pending");
  });

  it("applyCommandResult throws loudly on an unknown outcome (no silent undefined)", () => {
    const sent = markInFlight(item(env({ opId: "op1", localSeq: 1 })));
    expect(() =>
      applyCommandResult(sent, { outcome: "garbage", opId: "op1" } as unknown as CommandResult),
    ).toThrow(/unknown command outcome/);
  });
});

// ---- dispatch planning ----

describe("planDispatch", () => {
  it("returns dependency-free pending items in local_seq order", () => {
    const plan = planDispatch([
      item(env({ opId: "c", localSeq: 3 })),
      item(env({ opId: "a", localSeq: 1 })),
      item(env({ opId: "b", localSeq: 2 })),
    ]);
    expect(plan.ready.map((i) => i.envelope.opId)).toEqual(["a", "b", "c"]);
    expect(plan.waiting).toHaveLength(0);
    expect(plan.blocked).toHaveLength(0);
  });

  it("holds a dependent until its parent is accepted", () => {
    const parentPending = [
      item(env({ opId: "p", localSeq: 1 })),
      item(env({ opId: "child", localSeq: 2, dependsOn: ["p"] })),
    ];
    let plan = planDispatch(parentPending);
    expect(plan.ready.map((i) => i.envelope.opId)).toEqual(["p"]);
    expect(plan.waiting.map((i) => i.envelope.opId)).toEqual(["child"]);

    const parentAccepted = [
      item(env({ opId: "p", localSeq: 1 }), "accepted", { committedToken: TOKEN }),
      item(env({ opId: "child", localSeq: 2, dependsOn: ["p"] })),
    ];
    plan = planDispatch(parentAccepted);
    expect(plan.ready.map((i) => i.envelope.opId)).toEqual(["child"]);
  });

  it("treats a dependency in committedOpIds (already pruned) as satisfied", () => {
    const plan = planDispatch(
      [item(env({ opId: "child", localSeq: 2, dependsOn: ["gone"] }))],
      new Set(["gone"]),
    );
    expect(plan.ready.map((i) => i.envelope.opId)).toEqual(["child"]);
  });

  it("blocks on a dead dependency: a rejected parent or an absent parent", () => {
    const rejParent = planDispatch([
      item(env({ opId: "p", localSeq: 1 }), "rejected", { rejectionCode: "stale_version" }),
      item(env({ opId: "child", localSeq: 2, dependsOn: ["p"] })),
    ]);
    expect(rejParent.blocked).toHaveLength(1);
    expect(rejParent.blocked[0]?.reason).toBe("dead-dependency");
    expect(rejParent.blocked[0]?.deps).toEqual(["p"]);

    const absent = planDispatch([item(env({ opId: "child", localSeq: 2, dependsOn: ["ghost"] }))]);
    expect(absent.blocked[0]?.reason).toBe("dead-dependency");
    expect(absent.blocked[0]?.deps).toEqual(["ghost"]);
  });

  it("blocks every member of a dependency cycle", () => {
    const plan = planDispatch([
      item(env({ opId: "a", localSeq: 1, dependsOn: ["b"] })),
      item(env({ opId: "b", localSeq: 2, dependsOn: ["a"] })),
    ]);
    expect(plan.ready).toHaveLength(0);
    expect(plan.waiting).toHaveLength(0);
    expect(plan.blocked.map((b) => b.reason)).toEqual(["dependency-cycle", "dependency-cycle"]);
  });

  it("lets a pending item behind an IN-FLIGHT partner wait, not be declared a permanent cycle", () => {
    const plan = planDispatch([
      item(env({ opId: "a", localSeq: 1, dependsOn: ["b"] }), "in-flight"),
      item(env({ opId: "b", localSeq: 2, dependsOn: ["a"] })),
    ]);
    expect(plan.blocked).toHaveLength(0);
    expect(plan.waiting.map((i) => i.envelope.opId)).toEqual(["b"]);
  });

  it("reports both cycle members and dead parents in a blocked cycle's deps", () => {
    const plan = planDispatch([
      item(env({ opId: "a", localSeq: 1, dependsOn: ["b", "ghost"] })),
      item(env({ opId: "b", localSeq: 2, dependsOn: ["a"] })),
    ]);
    const a = plan.blocked.find((x) => x.item.envelope.opId === "a");
    expect(a?.reason).toBe("dependency-cycle");
    expect([...(a?.deps ?? [])].sort()).toEqual(["b", "ghost"]);
  });

  it("throws on a duplicate opId", () => {
    expect(() =>
      planDispatch([item(env({ opId: "dup", localSeq: 1 })), item(env({ opId: "dup", localSeq: 2 }))]),
    ).toThrow(/duplicate opId/);
  });

  it("committedTokens collects accepted items' tokens", () => {
    const tokens = committedTokens([
      item(env({ opId: "a", localSeq: 1 }), "accepted", { committedToken: TOKEN }),
      item(env({ opId: "b", localSeq: 2 })),
    ]);
    expect(tokens).toEqual([TOKEN]);
  });
});

// ---- change token frontier ----

describe("change-token frontier", () => {
  it("compares freshness and picks the max", () => {
    const older: ChangeToken = { authorityEpoch: 1, commitSeq: 10 };
    const newer: ChangeToken = { authorityEpoch: 1, commitSeq: 11 };
    expect(isTokenNewer(newer, older)).toBe(true);
    expect(isTokenNewer(older, newer)).toBe(false);
    expect(maxToken(older, newer)).toEqual(newer);
  });

  it("advances within an epoch and is a no-op on an equal token", () => {
    expect(advanceFrontier({ authorityEpoch: 1, commitSeq: 10 }, { authorityEpoch: 1, commitSeq: 11 })).toEqual({
      authorityEpoch: 1,
      commitSeq: 11,
    });
    expect(advanceFrontier({ authorityEpoch: 1, commitSeq: 11 }, { authorityEpoch: 1, commitSeq: 11 })).toEqual({
      authorityEpoch: 1,
      commitSeq: 11,
    });
  });

  it("accepts an epoch increment even when commitSeq restarts lower (authority cutover)", () => {
    expect(advanceFrontier({ authorityEpoch: 1, commitSeq: 9999 }, { authorityEpoch: 2, commitSeq: 1 })).toEqual({
      authorityEpoch: 2,
      commitSeq: 1,
    });
  });

  it("throws on a commitSeq regression within an epoch", () => {
    expect(() =>
      advanceFrontier({ authorityEpoch: 1, commitSeq: 11 }, { authorityEpoch: 1, commitSeq: 10 }),
    ).toThrow(ChangeTokenError);
  });

  it("throws on an epoch regression (stale authority)", () => {
    expect(() =>
      advanceFrontier({ authorityEpoch: 2, commitSeq: 1 }, { authorityEpoch: 1, commitSeq: 9999 }),
    ).toThrow(ChangeTokenError);
  });

  it("throws on a NaN or non-integer token instead of silently poisoning the frontier", () => {
    expect(() =>
      advanceFrontier({ authorityEpoch: 1, commitSeq: 5 }, { authorityEpoch: 1, commitSeq: NaN }),
    ).toThrow(ChangeTokenError);
    expect(() =>
      advanceFrontier({ authorityEpoch: 1, commitSeq: 5 }, { authorityEpoch: 1.5, commitSeq: 6 }),
    ).toThrow(ChangeTokenError);
  });
});

// ---- two-phase attachment ----

describe("two-phase attachment lifecycle", () => {
  function blob(over: Partial<BlobRecord> = {}): BlobRecord {
    return {
      blobId: "b1",
      sha256: "abc",
      byteLength: 100,
      state: "local-only",
      uploadConfirmed: false,
      linkConfirmed: false,
      ...over,
    };
  }

  it("is purgeable ONLY when linked with both confirmations", () => {
    expect(isBlobPurgeable(blob())).toBe(false);
    expect(isBlobPurgeable(blob({ state: "uploaded", uploadConfirmed: true }))).toBe(false);
    expect(
      isBlobPurgeable(blob({ state: "linked", uploadConfirmed: true, linkConfirmed: true })),
    ).toBe(true);
    // state says linked but a confirmation is missing -> still not purgeable (defensive triple-check)
    expect(isBlobPurgeable(blob({ state: "linked", uploadConfirmed: true }))).toBe(false);
  });

  it("walks local-only -> uploading -> uploaded -> linked and becomes purgeable", () => {
    let b = blob();
    b = advanceBlob(b, "upload-started");
    expect(b.state).toBe("uploading");
    b = advanceBlob(b, "upload-confirmed");
    expect(b).toMatchObject({ state: "uploaded", uploadConfirmed: true, linkConfirmed: false });
    expect(isBlobPurgeable(b)).toBe(false);
    b = advanceBlob(b, "link-confirmed");
    expect(b).toMatchObject({ state: "linked", uploadConfirmed: true, linkConfirmed: true });
    expect(isBlobPurgeable(b)).toBe(true);
  });

  it("short-circuits to uploaded on a dedupe (already-present) hit", () => {
    const b = advanceBlob(blob(), "already-present");
    expect(b).toMatchObject({ state: "uploaded", uploadConfirmed: true });
  });

  it("can expire mid-upload and resume from a local copy, keeping prior confirmations monotonic", () => {
    let b = advanceBlob(blob(), "upload-started");
    b = advanceBlob(b, "upload-expired");
    expect(b.state).toBe("upload-expired");
    b = advanceBlob(b, "upload-started");
    expect(b.state).toBe("uploading");
  });

  it("rejects an illegal transition", () => {
    expect(() => advanceBlob(blob(), "link-confirmed")).toThrow(AttachmentError); // can't link before upload
    expect(() => advanceBlob(blob({ state: "linked" }), "upload-started")).toThrow(AttachmentError); // terminal
  });

  it("assertLinkAllowed gates the link on a confirmed upload", () => {
    expect(() => assertLinkAllowed(blob())).toThrow(/before its upload is confirmed/);
    expect(() =>
      assertLinkAllowed(blob({ state: "uploaded", uploadConfirmed: true })),
    ).not.toThrow();
  });

  it("purgeableBlobs filters to fully-synced blobs only", () => {
    const ready = blob({ blobId: "ok", state: "linked", uploadConfirmed: true, linkConfirmed: true });
    const notReady = blob({ blobId: "no", state: "uploaded", uploadConfirmed: true });
    expect(purgeableBlobs([ready, notReady]).map((b) => b.blobId)).toEqual(["ok"]);
  });
});

// ---- conflict resolution ----

describe("conflict resolution mapping", () => {
  it("maps accepted -> commit with the token", () => {
    expect(localActionFor({ outcome: "accepted", opId: "op1", token: TOKEN })).toEqual({
      action: "commit",
      token: TOKEN,
    });
  });

  it("maps rejected -> mark-conflicted and ALWAYS pulls a fresh snapshot (never auto-merge)", () => {
    expect(
      localActionFor({ outcome: "rejected", opId: "op1", rejectionCode: "locked_sr" }),
    ).toEqual({ action: "mark-conflicted", rejectionCode: "locked_sr", pullSnapshot: true });
  });

  it("maps needs-review -> preserve evidence and freeze (work is never discarded)", () => {
    expect(
      localActionFor({ outcome: "needs-review", opId: "op1", reviewReason: "stale-finalization" }),
    ).toEqual({
      action: "preserve-evidence-and-flag",
      reviewReason: "stale-finalization",
      freeze: true,
    });
  });

  it("recognizes known rejection codes and the documented review triggers", () => {
    expect(isRejectionCode("stale_version")).toBe(true);
    expect(isRejectionCode("nonsense")).toBe(false);
    expect(REVIEW_TRIGGERS).toContain("offline-work-start-after-reassignment");
  });

  it("throws loudly on an unknown outcome instead of returning undefined (defense-in-depth)", () => {
    expect(() =>
      localActionFor({ outcome: "garbage", opId: "x" } as unknown as CommandResult),
    ).toThrow(/unknown command outcome/);
  });
});
