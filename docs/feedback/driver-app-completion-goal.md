# GOAL: Complete the Field Capture driver-app punch-list

You are an autonomous engineer finishing the driver app. **Single source of truth:**
`docs/feedback/2026-06-17-driver-app-walkthrough.md`. Read it FULLY first — it lists
every defect with verified `file:line` refs and tags. **Done = every item in that file
implemented, verified, and checked off, with the test suite green.**

## Repo
- Bare React Native (RN 0.85) iOS app with an Xcode-owned workspace. **Before writing code,
  read `apps/mobile/AGENTS.md`** and follow the conventions it documents.
- Wiring: `apps/mobile/App.tsx` (state-driven shell, NOT react-navigation). Screens:
  `apps/mobile/src/screens/*.tsx`. Tokens: `apps/mobile/src/design/`. Tests:
  `apps/mobile/__tests__` (was 92/92 — keep green).

## 3 cross-cutting fixes (do first — ~half the file)
- **T1 Signatures:** build ONE finger-drawable canvas, full-screen landscape, with
  submit/cancel/back. Reuse in Pre-Trip, JHA, Post-Trip, Evidence. Replace every
  placeholder box; wire the no-op `onCaptureSignature` handlers.
- **T2 Remove in-app punch:** delete PunchInFlow/PunchOutFlow and the Day punch buttons.
  The app only DISPLAYS punched-in/out status (read from the Hub clock gate). Punching is
  NFC-terminal-only.
- **T3 Theme + Language:** add a real `ThemeContext`/`useTheme()` so dark mode actually
  applies + persists; wire the Theme selection through it. Language: wire i18n if feasible,
  else HIDE the toggle — never ship a control that does nothing.

## Decisions (already made — use these, do NOT stop to ask)
1. Tab bar → move to TOP, with safe-area handling.
2. "Sync Now" → make it a real manual kick for the sync/upload runners, with Hub status refresh.
3. "Add Evidence" → fold into the Evidence flow; remove the standalone stub.
4. "Capture GPS" → automatic/background; remove the manual button.
5. SOPs → collapse to ONE list (no "Emergency" category) and keep required procedures readable
   before sign-in from the local/offline SOP browser.

## Safety-critical (highest priority — compliance integrity)
- Pre-Trip DVIR: block Continue until every item is marked; show REAL checked/defect counts
  (today they're hardcoded "45/45, 0 defects"); render all items in one scroll; default
  every item to "Not Checked".
- Stop-work acknowledgement: state that ANYONE on site has stop-work authority, and that
  multiple people present must hold a tailgate meeting before proceeding.
- Pre-fill driver name from the signed-in account (don't make them type it).

## Truth-in-UI (no dead button may remain)
Wire or remove every dead control: View DVIR Form, View in Spanish, Directions, Dispatch
(Job menu), Call/Message dispatcher (Call must dial on-duty dispatcher via RN `Linking`),
"Other" PPE fill-in field. Rename "Midland Office" → "Field Dispatch". Enlarge Jobs status
filters to ≥48px tap targets. Make JHA crew roles configurable: drop the forced "Driver"
row, add "Owner". JSA copy reflects tank-battery/loading work, not driving.

## New capability
Dispatcher messaging + send-job-location for the dispatch build (driver ↔ on-duty dispatcher).

## Working rules
- Match existing patterns and altitude; minimal, surgical diffs.
- NEVER fake completion — the file flags hardcoded fake-success as the core sin. Verify by
  behavior, not assertion.
- After each item: run typecheck + tests, then check its box in the punch-list file.
- Commit per logical group on a feature branch. Do not claim done until the WHOLE file is
  complete and the suite is green. Finish with a final pass confirming zero dead handlers
  (`flowNoop`/`noop`) remain on user-facing buttons.
