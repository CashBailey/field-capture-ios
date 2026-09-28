# Wire captured signatures into safety forms (DVIR + JHA/JSA) — to industry standard

**Date:** 2026-06-21 · **Repo:** field-capture-ios · **Status:** approved design (revised after standards research)

## Problem

Drivers cannot submit any safety form. Completing the pre-trip DVIR, post-trip DVIR, or JHA/JSA
wizard and tapping **Complete** shows `form <id> is not completed (draft)` — even though the driver
drew a test signature (sample driver "Alex Rivera", a hand-drawn signature, still
rejected).

### Root cause

`SignatureField` (`src/design/SignaturePad.tsx`) captures the signature, but the screens keep it in
**local state only** — `onCompletePreTrip` / post-trip / `JhaSignaturesScreen.onContinue` are no-arg
callbacks, so the value never reaches the host. App.tsx builds the form via `src/domain/fieldForms.ts`,
which produced `signatureBlobIds: []`. `fieldwork.validateFormCompletion` requires a signature, so
`completeForm` fails and the record stays `draft`; `submitForm` rejects the draft. A prior change
(commit `0db6976`) added a **placeholder** signature id — wrong for a safety record; this design
replaces it with the real captured signature.

## Industry / regulatory standard (deep research, 2026-06-21)

Verified against primary sources (49 CFR 390.5T, 390.32; FMCSA guidance; 15 USC 7001; ESIGN/UETA;
the Feb 2026 eDVIR final rule effective 2026-03-23). Findings:

- **The standard is functional and technology-neutral — NOT a file format.** A valid e-signature
  must establish (1) signer **identity/attribution**, (2) **intent/approval**, (3) be **bound to the
  record** (signature + document reproduce together), with **integrity, consent, and retrievable
  retention**. No cryptographic signature is required.
- **A drawn ("captured image") signature explicitly qualifies.** Rasterized **PNG** is the de facto
  vendor / RN-library default, but the law mandates **no format** — vector qualifies equally.
- **The legally load-bearing work is the METADATA bound to the signature**, not the pixels. RN
  signature widgets capture only the image; the **host app must bind**: signer identity, a **UTC
  timestamp**, the **exact certification/intent statement text** the signer approved, **proof of
  consent** to sign electronically (15 USC 7001(c)), the **document identity** it's bound to, and
  **device/audit** info — then retain it for accurate reproduction.

**Design consequences:**
1. Keep the **serialized-vector** artifact, not PNG. `SignaturePad` is deliberately dependency-free
   (no SVG / native modules) to avoid a native rebuild; PNG rendering would break that. Vector is
   legally valid (format-neutral), is bound to the record via the blob pipeline, and is
   re-rasterizable to PNG server-side for display/retention. (PNG render = noted follow-up.)
2. Add a **signature metadata record** to each form — this is the part that makes it standard.

## Approach (chosen)

**Screens emit the captured signature + the host binds the artifact and metadata.** Reuse the
existing capture pipeline: `CaptureFlow.capture()` (`src/runtime/captureFlow.ts`) computes SHA-256,
persists bytes via `FileBlobBytesSource`, registers a `BlobUploadRecord`, and the upload runner ships
the blob to the Hub (ADR-004 evidence) and links it to the form (binding-to-record). The host stamps
the metadata at completion time.

Rejected: (B) screens persist the blob themselves — breaks "presentational only"; (C) PNG artifact
now — forces a native rebuild for no legal gain; (D) cryptographic signature — not required by any
rule and far heavier.

## Components and changes (all field-capture-ios / mobile-side)

1. **Signature screens** — `PreTripSignatureScreen`, post-trip signature screen, `JhaSignaturesScreen`:
   - **Require a signature**: Complete / confirm-complete disabled until the pad holds ink.
   - **Emit the captured `SignatureValue`** up via the completion callback (replace no-arg signatures).
   - Show + carry the **certification text** already displayed ("I confirm this pre-trip inspection is
     complete and accurate." for DVIR; the JHA equivalent) so the host can bind the exact approved text.
   - Stay presentational (no domain/runtime imports added).

2. **Signature metadata type** — `packages/contracts/src/fieldwork/forms.ts`: add an optional
   `signatures` field to `JhaForm`/`DvirForm`, an array of:
   ```
   SignatureRecord {
     blobId: string;            // the captured-vector blob (also in signatureBlobIds)
     signerName: string;        // entered/prefilled driver name
     signerUserId?: string;     // authenticated session user — attribution
     signedAtUtc: string;       // ISO-8601 UTC timestamp
     certificationText: string; // exact intent statement the signer approved
     consentToElectronicSignature: true; // 15 USC 7001(c)
     deviceInstanceId: string;  // device/audit
     appVersion: string;        // device/audit
   }
   ```
   `signatureBlobIds` stays (the completion gate + binding). The Hub field-picks payload keys and
   ignores unknown ones, so this is **non-breaking** (`_handle_dvir`/`_handle_jhajsa` confirmed to
   ignore extra fields). `validateFormCompletion` continues to require `signatureBlobIds` non-empty;
   it may additionally require one well-formed `SignatureRecord`.

3. **App.tsx submit handlers** — `submitPreTripInspection` / `submitPostTripInspection` /
   `submitJhaForm` become **async** (the field-ticket flow already uses async `onSubmit`):
   - Persist the captured vector via `capture.capture({ bytes: utf8(serializedVector),
     attachmentKind: 'signature', mimeType: <Hub-accepted, e.g. application/octet-stream>,
     parentType, parentId })` → `blobId`.
   - Build the `SignatureRecord` (signerName from the screen; signerUserId/appVersion/deviceInstanceId
     from the runtime identity/session; `signedAtUtc = now().toISOString()`; certificationText from the
     screen; consent true).
   - Build the form with `signatureBlobIds: [blobId]` and `signatures: [record]`, then
     `saveDraft → completeForm → submitForm`.
   - Surface `completeForm`'s real reason on failure instead of the generic "(draft)" message.

4. **Form builders** — `src/domain/fieldForms.ts`: `jhaJsaForm` / `preTripDvirForm` / `postTripDvirForm`
   take `signatureBlobIds` (and the `signatures` record) as parameters — **removing the placeholder ids**.

5. **Tests**:
   - `field-form-builders.test.ts`: builders are completable only when given a real signature id +
     record, and mint no signature of their own.
   - New: capture-then-build yields `ok`, and the form carries the captured `blobId` plus a complete
     `SignatureRecord` (all required metadata fields present, UTC timestamp, certification text).
   - Gating: no captured signature ⇒ cannot complete.

## Data flow

```
draw → SignatureField.onChange(serializedVector) → screen state
tap Complete (enabled only when signed)
   → screen → host: serializedVector + certificationText + signerName
   → capture.capture({bytes, attachmentKind:'signature', parentType, parentId}) → blobId
   → SignatureRecord{blobId, signerName, signerUserId, signedAtUtc, certificationText,
                      consentToElectronicSignature:true, deviceInstanceId, appVersion}
   → form = builder(serviceRequestId, [blobId], [record])
   → saveDraft → completeForm → submitForm → upload runner ships signature blob + links to form
```

## Error handling

- **Locked clock gate**: `capture` returns `{status:'locked'}`; show the existing lock message, no submit.
- **No signature**: completion blocked before submit (gate).
- **Capture failure**: show saved-locally message, leave a draft, no partial submit.
- **Idempotency**: `capture` is idempotent on blob id (same bytes → same record); re-tapping Complete
  mints no duplicate blob.

## Out of scope (noted follow-ups)

- Rendering the signature to a PNG image (store the vector; server can rasterize). Avoids a native rebuild.
- Hub-side **structured** persistence/display of the signature metadata (today it rides in the evidence
  payload and is retained, but the Hub does not parse it into columns).
- Capturing the other wizard fields (hazards, inspection items) into the form — still representative.
- A formal one-time electronic-signing consent onboarding flow (per-form consent flag used for now).

## Acceptance

- Each form: cannot Complete without a signature; with one drawn, Complete → submit succeeds.
- The submitted form carries the **real captured signature blob** plus a complete `SignatureRecord`
  (signer identity, UTC timestamp, certification text, consent, device/audit).
- No placeholder signature ids remain in `fieldForms.ts`.
- `npm test`, `npm run typecheck`, lint all green.

---

## Appendix: research findings (verified 2026-06-21)

Deep-research run: 6 angles, 25 sources fetched, 114 claims extracted, 25 verified by 3-vote
adversarial check (2/3 refutes kills), 21 confirmed. Confidence below is the report's.

### Confirmed (adopt)

1. **E-signature is defined functionally** — two prongs: identify/authenticate the signer
   (attribution) AND indicate the signer's approval (intent). `49 CFR 390.5T` (GPEA-grounded),
   mirrored by ESIGN/UETA. *high, 3-0.*
2. **Technology-neutral artifact — no format mandated.** `49 CFR 390.32(c)(2)`: "An electronic
   signature may be made using any available technology that otherwise satisfies FMCSA's
   requirements." *high, 3-0.*
3. **A drawn ("captured image") touchscreen/stylus signature explicitly qualifies**, provided the
   signature and its document are electronically bound and reproducible together. FMCSA 2011
   guidance. Binding-to-record is the core *technical* requirement (not the sole requirement). *high, 3-0.*
4. **Defensibility = integrity, accuracy, accessibility, retention, accurate reproduction — NOT
   cryptographic signing.** `49 CFR 390.32(d)`; the codified rule never mentions PKI/certificates. *high, 3-0.*
5. **FMCSA authorizes e-signatures across 49 CFR parts 300–399, incl. DVIR (Part 396).**
   `49 CFR 390.32(c)(1)`; DVIRs are carrier-retained so they're in scope (390.32(a) only excludes
   docs submitted directly to FMCSA). *high, 3-0 / 2-1.*
6. **Validity is tied to ESIGN consent.** `49 CFR 390.32`: records must include "proof of consent to
   use electronically generated records or documents, as required by 15 U.S.C 7001(c)." *high, 3-0.*
7. **ESIGN/UETA four conditions:** intent to sign, consent to do business electronically, association
   of signature with the record, and retention capable of accurate reproduction; an e-signature/record
   may not be denied legal effect solely for being electronic (`15 USC 7001(a)(1)`, UETA §7). *high, 3-0 / 2-1.*
8. **Leading RN signature libraries output a rasterized image** (base64 data URL, **PNG by default**;
   JPEG/SVG optional) — not a vector model, not a cryptographic signature.
   (`react-native-signature-canvas`, `@equinor/react-native-skia-draw`, `react-native-signature-capture`.) *high, 3-0.*
9. **RN widgets capture NO compliance metadata** — no timestamp, identity, certification text, or
   audit info; they emit only the image. **The host app/backend must capture and bind all metadata.** *high, 3-0.*
10. **Electronic DVIRs permissible since the 2018 rule (`49 CFR 390.32`);** Feb 19 2026 final rule
    added explicit eDVIR language to `396.11`/`396.13` (effective **2026-03-23**) with **no** format or
    capture mandate. *high, 3-0.*
11. **Practical recommendation (synthesis):** capture the drawn signature as an image artifact and, at
    the app/backend layer, bind as immutable fields: authenticated signer identity, UTC timestamp,
    the exact certification/intent statement approved, proof of e-signing consent, the specific form
    identity (so signature + document reproduce together), and device/audit info; retain for accurate
    reproduction. *high (synthesis).*

> Our deviation from #8/#11: we store the **serialized vector** rather than PNG. The law is
> format-neutral (#2), the vector is bound to the record and re-rasterizable, and `SignaturePad` is
> deliberately native-dep-free (PNG render would force a native rebuild). Server-side PNG
> rasterization is a noted follow-up.

### Refuted (do NOT adopt)

- That all three DVIR signatures (driver, mechanic, next driver) must be captured together with
  timestamps as a `390.32` requirement. *0-3.*
- That GPS-location / geotagged-photo "proof the driver was at the vehicle" is the defensible eDVIR
  standard — it is a vendor value-add, not a regulatory requirement. *0-3.*
- That the 2025 eDVIR Federal Register notice itself grounds e-signatures in ESIGN's private-commerce
  framework — the ESIGN link flows through `390.32`'s `15 USC 7001(c)` cross-reference. *1-2.*

### Open questions (do not block this spec)

- Which signer-authentication method satisfies the "identifies and authenticates" prong on a shared
  device (app login vs. re-auth at signing). We bind the authenticated session user id; re-auth is out of scope.
- DVIR retention period / roadside-reproduction expectations (Part 396 ~3-month retention).
- JHA/JSA legal basis (OSHA/employer-driven, not FMCSA) — assumed to inherit the general ESIGN/UETA
  framework; not separately established.
- How named vendors (Samsara, Motive, Geotab) actually store the artifact/metadata — inferred, not
  directly evidenced.

### Primary sources

- FMCSA e-signature guidance — https://www.fmcsa.dot.gov/regulations/regulatory-guidance-concerning-electronic-signatures-and-documents
- 49 CFR 390.32 — https://www.law.cornell.edu/cfr/text/49/390.32
- 49 CFR 390.5T — https://www.law.cornell.edu/cfr/text/49/390.5T
- eDVIR rulemaking — https://www.federalregister.gov/documents/2025/05/30/2025-09717/electronic-driver-vehicle-inspection-reports
- ESIGN 15 USC 7001 — https://www.law.cornell.edu/uscode/text/15/7001
- ESIGN/UETA overview — https://www.docusign.com/learn/esign-act-ueta
- RN libs — https://github.com/YanYuanFE/react-native-signature-canvas · https://www.npmjs.com/package/@equinor/react-native-skia-draw
