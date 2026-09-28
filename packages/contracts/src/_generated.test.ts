import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { CONTRACT_VERSION, SYNC_OP_TYPES } from "./_generated";

const root = resolve(__dirname, "../../..");

describe("generated contract", () => {
  it("version matches the vendored manifest", () => {
    const m = JSON.parse(readFileSync(resolve(root, "contracts/triad-contract.json"), "utf8"));
    expect(CONTRACT_VERSION).toBe(m.version);
  });
  it("op types match the manifest (sorted)", () => {
    const m = JSON.parse(readFileSync(resolve(root, "contracts/triad-contract.json"), "utf8"));
    expect([...SYNC_OP_TYPES]).toEqual([...m.sync_op_types].sort());
  });
});
