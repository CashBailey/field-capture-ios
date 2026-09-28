# Signature Capture Wiring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make DVIR + JHA/JSA forms submittable by capturing the driver's drawn signature into the form as a blob plus a compliance metadata record, requiring a signature before completion.

**Architecture:** The signature pads already capture a serialized-vector signature but the screens keep it in local state. Thread that value up to App.tsx, persist it via the existing `CaptureFlow` blob pipeline, and build the form with the real blob id plus a `SignatureRecord` (signer identity, UTC timestamp, certification text, e-sign consent, device/audit). Keep the vector artifact (the law is format-neutral; PNG would force a native rebuild the pad deliberately avoids).

**Tech Stack:** bare React Native 0.85 / React 19, TypeScript, `@fieldcapture/contracts` (vitest), mobile app (jest).

**Repository:** `CashBailey/field-capture-ios`, maintained separately from `CashBailey/fieldcapture`.

## Global Constraints

- This plan adds no new native dependency (no SVG/canvas/native module — the pad stays dependency-free; artifact stays the serialized vector).
- Standard (verified, see spec appendix): a drawn signature is valid; the load-bearing requirement is METADATA bound to the form (identity, UTC timestamp, certification text, consent per 15 USC 7001(c), document binding, device/audit). No cryptographic signature.
- Signature blob `mimeType`: `application/octet-stream` (in the Hub's accepted attachment MIME set; the artifact is a JSON vector string).
- Capture `parentType`: `'sr'`, `parentId`: the form's `serviceRequestId` (the stable Hub entity). `attachmentKind`: `'signature'`.
- Mobile tests: `cd apps/mobile && CI=1 npx jest <file>`. Contracts tests: `cd packages/contracts && npx vitest run <file>`. Typecheck: `cd apps/mobile && npm run typecheck`. Lint: `cd apps/mobile && npx eslint <files>`.
- Commit trailer (verbatim, every commit):
  ```
  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01EccvDPVHxjfUbSs9ZWunhU
  ```

---

## File structure

- `packages/contracts/src/fieldwork/forms.ts` — add `SignatureRecord`, certification-text constants, optional `signatures?: SignatureRecord[]` on `JhaForm`/`DvirForm`. (Contract owner of types + canonical cert text.)
- `packages/contracts/src/fieldwork/forms.signature.test.ts` — new; contract-level tests.
- `apps/mobile/src/domain/fieldForms.ts` — builders take a `SignatureRecord`; add `buildSignatureRecord` + `signatureBytes` helpers. (Removes the placeholder.)
- `apps/mobile/__tests__/field-form-builders.test.ts` — update for the new builder signatures + helpers.
- `apps/mobile/src/runtime/wireAppRuntime.ts` — expose `deviceInstanceId` on the field workspace.
- `apps/mobile/src/screens/PreTripScreens.tsx`, `PostTripScreens.tsx`, `JhaScreens.tsx` — gate Complete on a signature; emit the captured signature + signer name; display a `certificationText` prop.
- `apps/mobile/App.tsx` — async submit handlers: capture the signature, build the record, build the form, submit; surface `completeForm`'s real error; pass cert text down + signature up.

---

### Task 1: Contract — `SignatureRecord`, cert text, optional `signatures`

**Files:**
- Modify: `packages/contracts/src/fieldwork/forms.ts`
- Test: `packages/contracts/src/fieldwork/forms.signature.test.ts` (create)

**Interfaces:**
- Produces: `SignatureRecord` interface; `DVIR_PRETRIP_CERTIFICATION_TEXT`, `DVIR_POSTTRIP_CERTIFICATION_TEXT`, `JHA_CERTIFICATION_TEXT` string constants; `JhaForm.signatures?: SignatureRecord[]`, `DvirForm.signatures?: SignatureRecord[]`.

- [ ] **Step 1: Write the failing test**

Create `packages/contracts/src/fieldwork/forms.signature.test.ts`:

```ts
import { describe, it, expect } from 'vitest';
import {
  validateFormCompletion,
  DVIR_PRETRIP_CERTIFICATION_TEXT,
  DVIR_POSTTRIP_CERTIFICATION_TEXT,
  JHA_CERTIFICATION_TEXT,
  type JhaForm,
  type SignatureRecord,
} from './forms';

const record: SignatureRecord = {
  blobId: 'blob-1',
  signerName: 'Alex Rivera',
  signerUserId: 'arivera',
  signedAtUtc: '2026-06-21T12:00:00.000Z',
  certificationText: JHA_CERTIFICATION_TEXT,
  consentToElectronicSignature: true,
  deviceInstanceId: 'device-1',
  appVersion: '1.0.0',
};

describe('signature contract', () => {
  it('certification text constants are non-empty', () => {
    expect(DVIR_PRETRIP_CERTIFICATION_TEXT.length).toBeGreaterThan(0);
    expect(DVIR_POSTTRIP_CERTIFICATION_TEXT.length).toBeGreaterThan(0);
    expect(JHA_CERTIFICATION_TEXT.length).toBeGreaterThan(0);
  });

  it('a JHA carrying a signature record + blob id is completable', () => {
    const form: JhaForm = {
      formId: 'jha-jsa-sr-1',
      kind: 'jha-jsa',
      serviceRequestId: 'sr-1',
      hazards: [{ hazardId: 'h1', description: 'H2S', mitigation: 'monitor' }],
      signatureBlobIds: [record.blobId],
      signatures: [record],
    };
    expect(validateFormCompletion(form)).toEqual([]);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd packages/contracts && npx vitest run src/fieldwork/forms.signature.test.ts`
Expected: FAIL — `DVIR_PRETRIP_CERTIFICATION_TEXT`/`SignatureRecord` not exported.

- [ ] **Step 3: Implement in `packages/contracts/src/fieldwork/forms.ts`**

Add after the `JhaHazard` interface (before `JhaForm`):

```ts
/** Compliance metadata bound to a captured signature (ESIGN/UETA/FMCSA functional standard:
 * attribution, intent, consent, device/audit). The drawn artifact is the blob at `blobId`. */
export interface SignatureRecord {
  blobId: string;
  signerName: string;
  signerUserId?: string;
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
```

In `interface JhaForm`, add after `signatureBlobIds`:

```ts
  /** Signature compliance records (one per signer); each blobId also appears in signatureBlobIds. */
  signatures?: SignatureRecord[];
```

In `interface DvirForm`, add after `signatureBlobIds`:

```ts
  signatures?: SignatureRecord[];
```

(`validateFormCompletion` is unchanged — it still requires `signatureBlobIds` non-empty; `signatures` is additive metadata.)

- [ ] **Step 4: Run test to verify it passes**

Run: `cd packages/contracts && npx vitest run src/fieldwork/forms.signature.test.ts`
Expected: PASS (2 tests).

- [ ] **Step 5: Run the full contracts suite (no regressions)**

Run: `cd packages/contracts && npx vitest run`
Expected: PASS (existing + 2 new).

- [ ] **Step 6: Commit**

```bash
git add packages/contracts/src/fieldwork/forms.ts packages/contracts/src/fieldwork/forms.signature.test.ts
git commit -m "feat(contracts): add SignatureRecord + certification-text constants

Optional signatures[] on JhaForm/DvirForm carries the e-signature compliance
metadata (signer identity, UTC timestamp, certification text, consent,
device/audit). Canonical certification strings for DVIR/JHA. validateFormCompletion
unchanged (signatureBlobIds remains the completion gate).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01EccvDPVHxjfUbSs9ZWunhU"
```

---

### Task 2: Domain builders take a `SignatureRecord` (+ helpers)

**Files:**
- Modify: `apps/mobile/src/domain/fieldForms.ts`
- Test: `apps/mobile/__tests__/field-form-builders.test.ts`

**Interfaces:**
- Consumes: `SignatureRecord` (Task 1).
- Produces:
  - `signatureBytes(serialized: string): Uint8Array`
  - `buildSignatureRecord(p: { blobId: string; signerName: string; signerUserId?: string; signedAtUtc: string; certificationText: string; deviceInstanceId: string; appVersion: string }): SignatureRecord`
  - `jhaJsaForm(serviceRequestId: string, signature: SignatureRecord): fieldwork.JhaForm`
  - `preTripDvirForm(serviceRequestId: string, vehicleRef: string, signature: SignatureRecord): fieldwork.DvirForm`
  - `postTripDvirForm(serviceRequestId: string, vehicleRef: string, signature: SignatureRecord): fieldwork.DvirForm`

- [ ] **Step 1: Rewrite the test** `apps/mobile/__tests__/field-form-builders.test.ts`:

```ts
import { fieldwork } from '@fieldcapture/contracts';

import {
  jhaJsaForm,
  preTripDvirForm,
  postTripDvirForm,
  buildSignatureRecord,
  signatureBytes,
} from '../src/domain/fieldForms';

function record(blobId: string): fieldwork.SignatureRecord {
  return buildSignatureRecord({
    blobId,
    signerName: 'Alex Rivera',
    signerUserId: 'arivera',
    signedAtUtc: '2026-06-21T12:00:00.000Z',
    certificationText: fieldwork.JHA_CERTIFICATION_TEXT,
    deviceInstanceId: 'device-1',
    appVersion: '1.0.0',
  });
}

describe('field-form builders carry the real signature', () => {
  it('buildSignatureRecord stamps consent=true and keeps fields', () => {
    const r = record('blob-1');
    expect(r).toMatchObject({ blobId: 'blob-1', consentToElectronicSignature: true });
  });

  it('signatureBytes encodes the serialized vector to bytes round-trippably', () => {
    const s = '{"v":1,"strokes":[[[1,2],[3,4]]]}';
    const bytes = signatureBytes(s);
    expect(bytes).toBeInstanceOf(Uint8Array);
    expect(Buffer.from(bytes).toString('utf8')).toBe(s);
  });

  it('jhaJsaForm carries the blob id + record and is completable', () => {
    const form = jhaJsaForm('sr-1', record('sig-jha'));
    expect(form.signatureBlobIds).toEqual(['sig-jha']);
    expect(form.signatures).toHaveLength(1);
    expect(fieldwork.validateFormCompletion(form)).toEqual([]);
  });

  it('preTripDvirForm carries the blob id + record and is completable', () => {
    const form = preTripDvirForm('sr-1', 'truck-7', record('sig-pre'));
    expect(form.signatureBlobIds).toEqual(['sig-pre']);
    expect(fieldwork.validateFormCompletion(form)).toEqual([]);
  });

  it('postTripDvirForm carries the blob id + record and is completable', () => {
    const form = postTripDvirForm('sr-1', 'truck-7', record('sig-post'));
    expect(form.signatureBlobIds).toEqual(['sig-post']);
    expect(fieldwork.validateFormCompletion(form)).toEqual([]);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/mobile && CI=1 npx jest __tests__/field-form-builders.test.ts`
Expected: FAIL — `buildSignatureRecord`/`signatureBytes` not exported; builders take wrong arity.

- [ ] **Step 3: Rewrite the builders block in `apps/mobile/src/domain/fieldForms.ts`**

Replace the current builder block (the comment + the three `export function ...Form` definitions added earlier) with:

```ts
/**
 * Field-form builders + signature helpers. The JHA/DVIR wizard screens are presentational, so the
 * durable record is assembled here. A form MUST carry at least one signature (the safety evidence
 * validateFormCompletion requires); the signature is the driver's captured artifact (blob) plus a
 * SignatureRecord of compliance metadata (ESIGN/UETA/FMCSA functional standard).
 */
export function signatureBytes(serialized: string): Uint8Array {
  // serializeSignature emits ASCII JSON; TextEncoder is available in Hermes (RN) and Node (jest).
  return new TextEncoder().encode(serialized);
}

export function buildSignatureRecord(p: {
  blobId: string;
  signerName: string;
  signerUserId?: string;
  signedAtUtc: string;
  certificationText: string;
  deviceInstanceId: string;
  appVersion: string;
}): fieldwork.SignatureRecord {
  return { ...p, consentToElectronicSignature: true };
}

export function jhaJsaForm(
  serviceRequestId: string,
  signature: fieldwork.SignatureRecord,
): fieldwork.JhaForm {
  return {
    formId: `jha-jsa-${serviceRequestId}`,
    kind: 'jha-jsa',
    serviceRequestId,
    hazards: [{ hazardId: 'h1', description: 'H2S exposure', mitigation: 'Monitor and ventilate' }],
    signatureBlobIds: [signature.blobId],
    signatures: [signature],
  };
}

export function preTripDvirForm(
  serviceRequestId: string,
  vehicleRef: string,
  signature: fieldwork.SignatureRecord,
): fieldwork.DvirForm {
  return {
    formId: `pre-trip-dvir-${serviceRequestId}`,
    kind: 'pre-trip-dvir',
    vehicleRef,
    items: [{ itemId: 'brakes', label: 'Brakes', result: 'ok' }],
    signatureBlobIds: [signature.blobId],
    signatures: [signature],
  };
}

export function postTripDvirForm(
  serviceRequestId: string,
  vehicleRef: string,
  signature: fieldwork.SignatureRecord,
): fieldwork.DvirForm {
  return {
    formId: `post-trip-dvir-${serviceRequestId}`,
    kind: 'post-trip-dvir',
    vehicleRef,
    items: [{ itemId: 'brakes', label: 'Brakes', result: 'ok' }],
    signatureBlobIds: [signature.blobId],
    signatures: [signature],
  };
}
```

Confirm `fieldForms.ts` imports `fieldwork` as a value where needed: change the existing `import type { fieldwork } from '@fieldcapture/contracts';` to `import { fieldwork } from '@fieldcapture/contracts';` only if a runtime member is referenced. (Here only types + the builders' object literals are used, so the existing `import type` is sufficient; `fieldwork.SignatureRecord` is a type. `TextEncoder` is a global — no import.)

- [ ] **Step 4: Run test to verify it passes**

Run: `cd apps/mobile && CI=1 npx jest __tests__/field-form-builders.test.ts`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add apps/mobile/src/domain/fieldForms.ts apps/mobile/__tests__/field-form-builders.test.ts
git commit -m "feat(mobile): builders take a real SignatureRecord (drop placeholder)

jhaJsaForm/preTripDvirForm/postTripDvirForm now require a SignatureRecord and set
signatureBlobIds + signatures from it — removing the placeholder signature id.
Adds buildSignatureRecord (stamps consent) and signatureBytes (serialized vector
-> bytes for the blob).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01EccvDPVHxjfUbSs9ZWunhU"
```

---

### Task 3: Expose `deviceInstanceId` on the field workspace

**Files:**
- Modify: `apps/mobile/src/runtime/wireAppRuntime.ts` (the `FieldRuntimeWorkspace` type ~line 73 and the `field` object ~line 205)

**Interfaces:**
- Consumes: `writeIdentity.deviceInstanceId` (existing getter ~line 164).
- Produces: `FieldRuntimeWorkspace.deviceInstanceId: string`.

- [ ] **Step 1: Add the field to the type**

In `wireAppRuntime.ts`, in the `FieldRuntimeWorkspace` interface (the block containing `workflow: FieldWorkflowService;` and `capture: CaptureFlow;`), add:

```ts
  /** Stable per-install device id, for signature/audit metadata. */
  deviceInstanceId: string;
```

- [ ] **Step 2: Populate it in the `field` object**

In the `const field: FieldRuntimeWorkspace = {` literal (the one with `workflow: new FieldWorkflowService({...})` and `capture: new CaptureFlow({...})`), add:

```ts
    deviceInstanceId: writeIdentity.deviceInstanceId,
```

- [ ] **Step 3: Typecheck**

Run: `cd apps/mobile && npm run typecheck`
Expected: PASS (no errors).

- [ ] **Step 4: Commit**

```bash
git add apps/mobile/src/runtime/wireAppRuntime.ts
git commit -m "feat(mobile): expose deviceInstanceId on the field workspace

App.tsx needs the device id to stamp signature audit metadata.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01EccvDPVHxjfUbSs9ZWunhU"
```

---

### Task 4: Signature screens — gate on signature, emit it, show cert text

**Files:**
- Modify: `apps/mobile/src/screens/PreTripScreens.tsx` (`PreTripSignatureScreen` ~line 491)
- Modify: `apps/mobile/src/screens/PostTripScreens.tsx` (post-trip signature screen ~line 570)
- Modify: `apps/mobile/src/screens/JhaScreens.tsx` (`JhaSignaturesScreen` ~line 1238)
- Test: `apps/mobile/__tests__/signature-screens.test.tsx` (create)

**Interfaces:**
- Consumes: `SignatureValue` (from `../design`), `DVIR_PRETRIP_CERTIFICATION_TEXT` etc. (Task 1, default values).
- Produces: each screen's completion callback now passes `{ signature: SignatureValue; signerName: string }`; each accepts an optional `certificationText?: string` prop. Names:
  - `PreTripSignatureScreen.onCompletePreTrip(payload: { signature: SignatureValue; signerName: string })`
  - post-trip screen `onComplete(payload: { signature: SignatureValue; signerName: string })`
  - `JhaSignaturesScreen.onContinue(payload: { signatures: { signature: SignatureValue; signerName: string }[] })` (carries each signer who signed; at minimum the driver)

- [ ] **Step 1: Write the failing test** `apps/mobile/__tests__/signature-screens.test.tsx`:

```tsx
import { render, fireEvent } from '@testing-library/react-native';
import { PreTripSignatureScreen } from '../src/screens/PreTripScreens';

describe('PreTripSignatureScreen', () => {
  it('Complete is disabled until a signature is captured, then emits it', () => {
    const onComplete = jest.fn();
    const { getByTestId } = render(
      <PreTripSignatureScreen driverName="Alex Rivera" onCompletePreTrip={onComplete} />,
    );
    // Drive the SignatureField onChange via its testID surface.
    fireEvent(getByTestId('pretrip-signature'), 'onChange', '{"v":1,"strokes":[[[1,2]]]}');
    // After signing, completing emits the captured value + signer name.
    fireEvent.press(getByTestId('signature-confirm-complete'));
    expect(onComplete).toHaveBeenCalledWith(
      expect.objectContaining({ signature: expect.any(String), signerName: 'Alex Rivera' }),
    );
  });
});
```

> Note: if the existing screen requires opening a confirm card before `signature-confirm-complete` is present, the test must first press the primary Complete control to reveal it. Inspect the current `PreTripSignatureScreen` confirm flow (the `confirming` state) and drive whichever testIDs gate the final press; keep the assertion (disabled-until-signed + emits `{signature, signerName}`).

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/mobile && CI=1 npx jest __tests__/signature-screens.test.tsx`
Expected: FAIL — `onCompletePreTrip` called with no args / signature not threaded.

- [ ] **Step 3: Edit `PreTripSignatureScreen`** (`PreTripScreens.tsx`)

- Change the prop type: `onCompletePreTrip: (payload: { signature: SignatureValue; signerName: string }) => void;` and add `certificationText?: string;`.
- The screen already holds `const [signature, setSignature] = useState<SignatureValue | null>(null);` and `const signed = signature !== null;`.
- Render the certification text from the prop with the canonical default:
  ```tsx
  <Text style={[styles.body2, { color: t.text }]}>
    {props.certificationText ?? DVIR_PRETRIP_CERTIFICATION_TEXT}
  </Text>
  ```
  (import `DVIR_PRETRIP_CERTIFICATION_TEXT` from `@fieldcapture/contracts`'s `fieldwork`.)
- Gate completion: the primary action that opens/confirms completion must be `disabled={!signed}`.
- On final confirm, emit the value:
  ```tsx
  onPress={() => {
    setConfirming(false);
    if (signature !== null) props.onCompletePreTrip({ signature, signerName: driverName });
  }}
  ```

- [ ] **Step 4: Edit the post-trip signature screen** (`PostTripScreens.tsx`)

- It already has `signed` + `disabled={!signed}` on the complete button (verify) and `const [signature, setSignature]`.
- Change `onComplete: () => void;` to `onComplete: (payload: { signature: SignatureValue; signerName: string }) => void;`, add `certificationText?: string;`, render `{props.certificationText ?? DVIR_POSTTRIP_CERTIFICATION_TEXT}`.
- Change the button handler to `onPress={() => signature !== null && props.onComplete({ signature, signerName: driverName })}` (keep `disabled={!signed}`). If the screen has no local `driverName`, thread it from a `driverName?: string` prop (add if missing).

- [ ] **Step 5: Edit `JhaSignaturesScreen`** (`JhaScreens.tsx`)

- The screen manages `people: JhaSigner[]` and per-signer `SignatureField`s. Track each signer's captured `SignatureValue` in state.
- Change `onContinue: () => void;` to `onContinue: (payload: { signatures: { signature: SignatureValue; signerName: string }[] }) => void;`, add `certificationText?: string;` (display `{props.certificationText ?? JHA_CERTIFICATION_TEXT}`).
- Gate: the continue/primary action is disabled until the driver row has a captured signature.
- On press, emit `{ signatures: signers.filter(s => s.signature !== null).map(s => ({ signature: s.signature!, signerName: s.name })) }` (driver first; at least one).

- [ ] **Step 6: Run test to verify it passes**

Run: `cd apps/mobile && CI=1 npx jest __tests__/signature-screens.test.tsx`
Expected: PASS.

- [ ] **Step 7: Run the existing screen suites (no regressions)**

Run: `cd apps/mobile && CI=1 npx jest __tests__/pretrip-dvir.test.tsx __tests__/jha-safety.test.tsx __tests__/signature-field.test.tsx`
Expected: PASS. Fix any callers in those tests that assumed the old no-arg callbacks.

- [ ] **Step 8: Commit**

```bash
git add apps/mobile/src/screens/PreTripScreens.tsx apps/mobile/src/screens/PostTripScreens.tsx apps/mobile/src/screens/JhaScreens.tsx apps/mobile/__tests__/signature-screens.test.tsx
git commit -m "feat(mobile): signature screens require + emit the drawn signature

Pre-trip, post-trip, and JHA signature screens now disable Complete until signed
and pass the captured signature(s) + signer name up to the host; certification
text is a prop defaulting to the canonical contract constant.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01EccvDPVHxjfUbSs9ZWunhU"
```

---

### Task 5: App.tsx — capture signature, build record, async submit

**Files:**
- Modify: `apps/mobile/App.tsx` — the three submit handlers (`submitPreTripInspection`, `submitPostTripInspection`, `submitJhaForm` ~lines 586–636), the flow components that mount the signature screens (`PreTripFlow` ~1159, `PostTripFlow` ~1209, `JhaFlow` ~1352), and the `field`/`appVersion`/`username` already in scope (`const { ..., field } = props.runtime;`, `appVersion` ~178, `username` state).

**Interfaces:**
- Consumes: `field.capture.capture(...)` → `CaptureResult`; `field.deviceInstanceId` (Task 3); `buildSignatureRecord`, `signatureBytes`, builders (Task 2); cert text constants (Task 1); `SignatureValue` type.
- Produces: async `submitPreTripInspection/submitPostTripInspection/submitJhaForm` taking the captured signature; flows await them.

- [ ] **Step 1: Add a signature-persistence helper inside the FieldWork component**

Near the submit handlers, add (uses `field`, `appVersion`, `username` already in scope):

```tsx
const persistSignature = async (
  serviceRequestId: string,
  certificationText: string,
  payload: { signature: SignatureValue; signerName: string },
): Promise<SignatureRecordResult> => {
  const result = await field.capture.capture({
    bytes: signatureBytes(payload.signature),
    mimeType: 'application/octet-stream',
    source: 'signature-pad',
    attachmentKind: 'signature',
    parentType: 'sr',
    parentId: serviceRequestId,
  });
  if (result.status === 'locked') return { status: 'locked', reason: result.reason };
  const record = buildSignatureRecord({
    blobId: result.record.blobId,
    signerName: payload.signerName,
    ...(username.length > 0 ? { signerUserId: username } : {}),
    signedAtUtc: new Date().toISOString(),
    certificationText,
    deviceInstanceId: field.deviceInstanceId,
    appVersion: appVersion ?? 'unknown',
  });
  return { status: 'ok', record };
};
```

Add the local type near the other helper types (e.g. by `SubmitResult`):

```tsx
type SignatureRecordResult =
  | { status: 'ok'; record: fieldwork.SignatureRecord }
  | { status: 'locked'; reason: string };
```

Update imports at the top of App.tsx:
- `import { fieldwork } from '@fieldcapture/contracts';` (re-add — needed for `fieldwork.SignatureRecord` and the cert constants; or import the named constants directly).
- `import { jhaJsaForm, postTripDvirForm, preTripDvirForm, buildSignatureRecord, signatureBytes } from './src/domain';`
- Add `SignatureValue` to the existing `./src/design` type import.

- [ ] **Step 2: Make the three submit handlers async + signature-driven**

Replace `submitPreTripInspection`:

```tsx
const submitPreTripInspection = async (
  payload: { signature: SignatureValue; signerName: string },
): Promise<SubmitResult> => {
  const sig = await persistSignature(
    effectiveSrId,
    fieldwork.DVIR_PRETRIP_CERTIFICATION_TEXT,
    payload,
  );
  if (sig.status === 'locked') return { ok: false, message: `Field work is locked: ${sig.reason}.` };
  const form = preTripDvirForm(effectiveSrId, vehicleRef, sig.record);
  field.workflow.saveDraft(form);
  const completed = field.workflow.completeForm(form.formId);
  if (completed.status !== 'ok') {
    bump();
    return workflowSubmitResult(completed, '');
  }
  const res = field.workflow.submitForm(form.formId);
  bump();
  return workflowSubmitResult(res, 'Pre-trip inspection completed and saved on this phone.');
};
```

Apply the same shape to `submitPostTripInspection` (use `postTripDvirForm`, `DVIR_POSTTRIP_CERTIFICATION_TEXT`, post-trip success message) and `submitJhaForm` (use `jhaJsaForm`, `JHA_CERTIFICATION_TEXT`, JHA success message). For JHA the screen emits `{ signatures: [...] }`; pass the first (driver) entry: `payload.signatures[0]` — and guard empty: if `payload.signatures.length === 0` return `{ ok: false, message: 'A signature is required.' }`.

(Surfacing `completeForm`'s real error: `workflowSubmitResult(completed, '')` maps `invalid` → `res.errors.join(', ')`, so the user now sees the real reason instead of the generic "(draft)".)

- [ ] **Step 3: Thread the signature through the flow components**

- `PreTripFlow`: its `onSubmit` prop type becomes `(payload: { signature: SignatureValue; signerName: string }) => Promise<SubmitResult>`; the mounted `PreTripSignatureScreen`'s `onCompletePreTrip` becomes `async (payload) => { const result = await props.onSubmit(payload); setMsg(result); if (result.ok) setR('complete'); }`. Pass `certificationText={fieldwork.DVIR_PRETRIP_CERTIFICATION_TEXT}`.
- `PostTripFlow`: same shape, `DVIR_POSTTRIP_CERTIFICATION_TEXT`, post-trip screen's `onComplete`.
- `JhaFlow`: `onSubmit` becomes `(payload: { signatures: {...}[] }) => Promise<SubmitResult>`; `JhaReviewScreen.onComplete` already calls `props.onSubmit()` — change `JhaSignaturesScreen.onContinue` to capture the signatures into `JhaFlow` state, and have the review `onComplete` pass them: `const r = await props.onSubmit({ signatures });`. Pass `certificationText={fieldwork.JHA_CERTIFICATION_TEXT}` to `JhaSignaturesScreen`.
- At the mount sites, the props passed to `PreTripFlow`/`PostTripFlow`/`JhaFlow` (`onSubmit={submitPreTripInspection}` etc.) now match the async signature-driven handlers.

- [ ] **Step 4: Typecheck**

Run: `cd apps/mobile && npm run typecheck`
Expected: PASS. Resolve any signature/type mismatches at the flow mount sites until clean.

- [ ] **Step 5: Lint**

Run: `cd apps/mobile && npx eslint App.tsx src/screens/PreTripScreens.tsx src/screens/PostTripScreens.tsx src/screens/JhaScreens.tsx src/domain/fieldForms.ts`
Expected: no errors.

- [ ] **Step 6: Commit**

```bash
git add apps/mobile/App.tsx
git commit -m "fix(mobile): capture the drawn signature into DVIR/JHA on submit

Submit handlers are async: persist the captured signature via CaptureFlow (blob),
build a SignatureRecord (signer identity, UTC timestamp, certification text,
consent, device/audit), build the form with it, then complete + submit. Surfaces
completeForm's real reason instead of the generic '(draft)'. Closes 'I can't
submit the JHA' with the driver's actual signature.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01EccvDPVHxjfUbSs9ZWunhU"
```

---

### Task 6: Full verification

**Files:** none (verification only).

- [ ] **Step 1: Full mobile suite**

Run: `cd apps/mobile && CI=1 npm test`
Expected: PASS (all suites; the field-form-builders + signature-screens tests included).

- [ ] **Step 2: Contracts suite**

Run: `cd packages/contracts && npx vitest run`
Expected: PASS.

- [ ] **Step 3: Typecheck + lint (whole app)**

Run: `cd apps/mobile && npm run typecheck`
Expected: PASS.

- [ ] **Step 4: Confirm no placeholder signature remains**

Run: `cd apps/mobile && grep -rn "signature\`\]" src/domain/fieldForms.ts || echo "no placeholder ids"`
Expected: `no placeholder ids` (builders derive ids from the captured blob).

- [ ] **Step 5: Push**

```bash
git push origin claude/integration-loop-2026-06-18
```

---

## Self-review

- **Spec coverage:** require-to-complete → Task 4 gating; emit signature → Task 4; persist artifact (vector blob) → Task 5 `persistSignature`; SignatureRecord metadata (identity/UTC/cert/consent/device) → Task 1 type + Task 2 `buildSignatureRecord` + Task 5 stamping; replace placeholder → Task 2; surface real error → Task 5 Step 2; all three forms → Tasks 4–5 cover pre/post/JHA; non-breaking to Hub → additive optional field (Task 1), confirmed Hub field-picks. Covered.
- **Placeholders:** none — every code step shows real code; the one screen-confirm-flow nuance (Task 4 Step 1 note) instructs inspecting the existing `confirming` testIDs and keeps the concrete assertion.
- **Type consistency:** `SignatureRecord` (Task 1) used by `buildSignatureRecord`/builders (Task 2) and `persistSignature` (Task 5); `field.deviceInstanceId` (Task 3) consumed in Task 5; cert constants (Task 1) used in Tasks 4–5; callback payload shape `{ signature, signerName }` consistent screens (Task 4) ↔ handlers (Task 5).
