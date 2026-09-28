// Generate packages/contracts/src/_generated.ts from ../../contracts/triad-contract.json.
import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const manifestPath = resolve(here, "../../contracts/triad-contract.json");
const outPath = resolve(here, "src/_generated.ts");

const m = JSON.parse(readFileSync(manifestPath, "utf8"));
for (const k of ["version", "sync_op_types", "nfc_auth_methods"]) {
  if (!(k in m)) throw new Error(`triad-contract.json missing key: ${k}`);
}
const ops = [...m.sync_op_types].sort();
const auth = [...m.nfc_auth_methods].sort();
const lit = (a) => a.map((s) => JSON.stringify(s)).join(", ");
const out = `// GENERATED from contracts/triad-contract.json — do not edit; run make sync-contracts.
export const CONTRACT_VERSION = ${JSON.stringify(m.version)} as const;
export const SYNC_OP_TYPES = [${lit(ops)}] as const;
export type SyncOpType = (typeof SYNC_OP_TYPES)[number];
export const NFC_AUTH_METHODS = [${lit(auth)}] as const;
`;
writeFileSync(outPath, out);
console.log(`wrote ${outPath}`);
