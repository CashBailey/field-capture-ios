import { describe, it, expect } from "vitest";
import {
  PruningError,
  planEvidencePrune,
  type EvidencePruneCandidate,
  type EvidencePrunePolicy,
} from "../src/sync/index.js";

const DAY_MS = 24 * 60 * 60 * 1000;
const NOW = 100 * DAY_MS;

const POLICY: EvidencePrunePolicy = {
  retentionMs: 7 * DAY_MS,
  maxTotalBytes: 1_000,
};

function accepted(
  id: string,
  sizeBytes: number,
  ageDays: number,
  extra?: Partial<EvidencePruneCandidate>,
): EvidencePruneCandidate {
  return {
    id,
    status: "accepted",
    sizeBytes,
    acceptedAtMs: NOW - ageDays * DAY_MS,
    ...extra,
  };
}

describe("planEvidencePrune — safety invariants", () => {
  it("prunes nothing while total bytes are within budget", () => {
    const rows = [accepted("a", 400, 30), accepted("b", 400, 30)];
    const plan = planEvidencePrune(rows, POLICY, NOW);
    expect(plan.pruneIds).toEqual([]);
    expect(plan.freedBytes).toBe(0);
    expect(plan.remainingBytes).toBe(800);
  });

  it("NEVER prunes non-accepted work, no matter the pressure", () => {
    const protectedStatuses = [
      "pending",
      "in-flight",
      "retry",
      "blocked",
      "failed",
      "needs-review",
    ] as const;
    const rows: EvidencePruneCandidate[] = protectedStatuses.map((status, i) => ({
      id: `p${i}`,
      status,
      sizeBytes: 10_000, // way over budget
      acceptedAtMs: NOW - 90 * DAY_MS, // ancient — still protected
    }));
    const plan = planEvidencePrune(rows, POLICY, NOW);
    expect(plan.pruneIds).toEqual([]);
    // The planner reports it could not reach the budget rather than touching protected rows.
    expect(plan.shortfallBytes).toBe(60_000 - POLICY.maxTotalBytes);
  });

  it("never prunes accepted rows still inside the retention window", () => {
    const rows = [accepted("old", 600, 30), accepted("young", 600, 2)];
    const plan = planEvidencePrune(rows, POLICY, NOW);
    expect(plan.pruneIds).toEqual(["old"]);
  });

  it("never prunes an accepted row carrying an external protection reason", () => {
    const rows = [
      accepted("linked-pending", 900, 30, { protectedReasons: ["unlinked-attachment"] }),
      accepted("unprinted", 900, 30, { protectedReasons: ["unprinted-record"] }),
      accepted("free", 900, 30),
    ];
    const plan = planEvidencePrune(rows, POLICY, NOW);
    expect(plan.pruneIds).toEqual(["free"]);
    expect(plan.shortfallBytes).toBe(1_800 - POLICY.maxTotalBytes);
  });

  it("never prunes an accepted row with no acceptedAtMs — age unknowable means protected", () => {
    const rows: EvidencePruneCandidate[] = [
      { id: "no-stamp", status: "accepted", sizeBytes: 5_000 },
    ];
    const plan = planEvidencePrune(rows, POLICY, NOW);
    expect(plan.pruneIds).toEqual([]);
  });
});

describe("planEvidencePrune — eviction order and budget targeting", () => {
  it("prunes oldest-accepted first, only until back under budget", () => {
    const rows = [
      accepted("newest", 400, 10),
      accepted("oldest", 400, 50),
      accepted("middle", 400, 30),
    ];
    // total 1200 > 1000; freeing the single oldest row reaches 800 <= 1000.
    const plan = planEvidencePrune(rows, POLICY, NOW);
    expect(plan.pruneIds).toEqual(["oldest"]);
    expect(plan.freedBytes).toBe(400);
    expect(plan.remainingBytes).toBe(800);
    expect(plan.shortfallBytes).toBe(0);
  });

  it("keeps the N most recent accepted rows when minKeepAccepted is set", () => {
    const rows = [accepted("a", 600, 50), accepted("b", 600, 40), accepted("c", 600, 30)];
    const plan = planEvidencePrune(rows, { ...POLICY, minKeepAccepted: 2 }, NOW);
    expect(plan.pruneIds).toEqual(["a"]);
  });

  it("counts protected rows toward total pressure but only frees eligible ones", () => {
    const rows: EvidencePruneCandidate[] = [
      { id: "pending-heavy", status: "pending", sizeBytes: 900 },
      accepted("a", 300, 30),
      accepted("b", 300, 20),
    ];
    // total 1500; pruning both accepted rows gets to 900 <= 1000 — pending row untouched.
    const plan = planEvidencePrune(rows, POLICY, NOW);
    expect(plan.pruneIds).toEqual(["a", "b"]);
    expect(plan.remainingBytes).toBe(900);
  });

  it("rejects malformed policies and rows loudly", () => {
    expect(() => planEvidencePrune([], { retentionMs: -1, maxTotalBytes: 10 }, NOW)).toThrow(
      PruningError,
    );
    expect(() => planEvidencePrune([], { retentionMs: 0, maxTotalBytes: -1 }, NOW)).toThrow(
      PruningError,
    );
    expect(() =>
      planEvidencePrune(
        [{ id: "x", status: "accepted", sizeBytes: -5, acceptedAtMs: 0 }],
        POLICY,
        NOW,
      ),
    ).toThrow(PruningError);
    expect(() =>
      planEvidencePrune(
        [accepted("dup", 1, 1), accepted("dup", 1, 1)],
        POLICY,
        NOW,
      ),
    ).toThrow(PruningError);
  });
});
