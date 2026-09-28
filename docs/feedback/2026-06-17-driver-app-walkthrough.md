# Field Capture — Driver App Walkthrough Feedback (2026-06-17)

Source: Cash's spoken walkthrough of the driver app. Each item below was verified
against the real screen source before being written down, so the "Today" line is
what the code actually does, not a guess. Code refs are `file:line`.

## How to read the tags

| Tag | Meaning |
|-----|---------|
| 🔴 **Broken / dead** | Looks functional, does nothing (wired to `flowNoop`/`noop`, or hardcoded output). A bug. |
| 🟠 **Policy / design** | Changes what the app is *allowed* to do or how a flow should work. A decision, not just a bug. |
| 🟢 **New capability** | Doesn't exist yet; you want it built. |
| 🔵 **Wording / content** | Naming, copy, or domain-accuracy fix. |
| ⚠️ **Safety / compliance** | Touches DVIR / JSA / stop-work integrity — gets priority. |

---

## Cross-cutting themes (fix once, lands in many places)

These three account for ~half the individual complaints. Worth treating as single
work items rather than per-screen patches.

### T1. Signatures are non-functional everywhere ⚠️ 🔴
You cannot draw a signature with your finger on **any** screen. Every signature
"pad" is a bordered placeholder box; tapping it just flips a label to "captured"
and the `onCaptureSignature` handler is a no-op.
- Pre-Trip: `PreTripScreens.tsx:489-505`, handler `flowNoop` at `App.tsx:1169`
- JHA/JSA: `JhaScreens.tsx:1197-1214` (88px box, sign() only toggles state)
- Evidence: `EvidenceScreens.tsx:805-812` (PlaceholderFrame)
- Post-Trip: same pattern
- **You want:** a real drawable canvas, opened **full-screen in landscape** so there's
  room to actually sign, with submit/cancel/back chrome. One component, reused in all
  four places.

### T2. Punch In / Punch Out must NOT happen in the app ⚠️ 🟠
Right now the app has fully working in-app Punch In and Punch Out flows
(`App.tsx:1086-1119` PunchInFlow, `App.tsx:1229-1255` PunchOutFlow), launched from
the Day dashboard (`DayScreens.tsx:131-155`).
- **Your rule:** punching happens **only** at the physical **Field Time Terminal** —
  weatherproof NFC reader + camera, driver taps their NFC badge, terminal photographs
  them. The app may **display** punched-in/out status (read-only) but must never
  perform the punch.
- **Why (your reasoning, kept on record):** forcing the punch to the yard terminal
  increases accountability and defeats GPS-spoofing — a driver can't clock in from
  anywhere by faking location. The friction is intentional and appropriate.
- **Change:** remove PunchInFlow/PunchOutFlow and the punch buttons; keep the status
  badge as a read-only mirror of the Hub clock gate. (There's even a code comment at
  `DayScreens.tsx:7-9` saying "TimeClock owns punching in" — the buttons contradict it.)

### T3. Theme and Language switches are fake 🔴
Both the dark-mode toggle and the Spanish/device-language toggle store your choice in
state that is **never read by anything**, so nothing changes.
- Theme: `theme` is a static `const` import (`theme.ts:98`); no context/provider, so
  a selection can't re-render the app. State set at `App.tsx:1643/1678`, never used.
- Language: `lang` state set at `App.tsx:1642/1677`, never used; all copy is hardcoded
  English. No i18n system exists.
- **Decision needed:** either (a) build it for real — a `ThemeContext` + `useTheme()`
  and an i18n provider (i18n-js) wrapping the app — or (b) hide both toggles until the
  infrastructure exists, so the app stops promising something it can't do.

---

## By screen (in the order you walked through it)

### 1. Bottom tab bar (Day / Jobs / SOPs / Sync / More) 🟠 layout
- **Today:** tab bar sits at the very bottom with only 8px padding and **no safe-area
  inset** (`App.tsx:1802-1808`; the shell hardcodes a 44px top inset but nothing on the
  bottom). On notched / gesture-bar phones it can be clipped or hard to reach. Matches
  your "so close to the edge I'm not sure it'd make it on some models."
- **You want:** either move the tabs to the **top**, or at minimum add a real bottom
  safe-area inset so they're never cut off. Either way, bigger / more identifiable.

### 2. Day dashboard 🟠
- Shows today's status, clocked-in time, next job, open jobs — **this part is correct**
  (`DayScreens.tsx:95-195`).
- The punch buttons living here are the problem → see **T2**. After T2 this screen
  becomes status-display + "go to your jobs," nothing punchable.

### 3. Pre-Trip Inspection (DVIR) ⚠️
- **"View DVIR Form" and "View in Spanish" are dead** 🔴 — both wired to `flowNoop`
  (`App.tsx:1144-1145`). Either wire them or remove them.
- **Engine oil & coolant default to "OK"** 🟠 wrong-default — `DEFAULT_SECTION_ITEMS`
  pre-sets `result:'ok'` (`PreTripScreens.tsx:695-701`). The three states (Not Checked /
  OK / Defect) already exist. **Your call:** default everything to **Not Checked**.
- **Only ~5 of 62 items show, and there's no scroll** 🔴 layout — only 5 seed items
  exist and the list isn't in a ScrollView (`PreTripScreens.tsx:166, 199-219, 695-701`).
  **You want:** all items on one scrollable page, Continue at the bottom.
- **Continue works with nothing checked** ⚠️ 🔴 missing-validation — Continue has no
  guard (`PreTripScreens.tsx:221`), and the review screen shows **hardcoded** "45/45,
  16/16, 0 defects" regardless of what you did (`PreTripScreens.tsx:379-383`). This is
  the most serious item: a DVIR can be "completed" without inspecting anything. Must
  block Continue until every item is marked, and the review must reflect real counts.
- **Signature** ⚠️ → see **T1**. Plus: **driver name should be pre-filled from the
  account**, not typed (`PreTripScreens.tsx:458,472-485` start empty).

### 4. Jobs tab 🟠 layout
- **Status filter buttons too small** — Not Started / In Progress / Blocked / Complete /
  Pending Sync render as ~12px chips with no `minHeight` (`JobScreens.tsx:1136-1145`).
  **You want:** large, obvious tap targets (mirror the 48px stop-work buttons already in
  the same file).

### 5. Job Overview 🟠
- **"Capture GPS" should be invisible** — it's a manual button today
  (`JobScreens.tsx:432-446`). **You want:** GPS captured automatically in the background,
  abstracted away from the driver (no button).
- **"Add Evidence" placement is unclear** — you weren't sure where it fits the flow.
  Currently a standalone "supporting action" stub. Decide whether it belongs inside the
  Evidence flow / ticket, or stays as a quick action.
- **Bonus found:** the "Directions" and "Dispatch" menu items are **dead** 🔴 — App.tsx
  doesn't handle those keys (`App.tsx:743-750`), so they do nothing.

### 6. JHA / JSA safety wizard ⚠️
- **Domain note (important):** the JSA/JHA is **not for driving** — it's for once the
  driver reaches the **tank battery and is loading from the source**. Copy and framing
  should reflect that (it currently reads like a generic pre-job check).
- **"Other" PPE has no fill-in field** 🔴 — selecting Other reveals no text input
  (`JhaScreens.tsx:621-666, 680`). Add a TextInput when Other is selected.
- **Stop-work acknowledgement is too narrow** ⚠️ 🔵 — current text only says "I have
  authority to stop work" (`JhaScreens.tsx:1117-1119`). **You want it to say:** *anyone*
  on site has stop-work authority (not just crew), and if multiple people are present
  they must hold a **tailgate meeting** so everyone understands the work before
  proceeding.
- **Crew/signature roles** 🟠 — hardcoded rows are Driver / Supervisor / Customer
  Representative / Additional Crew Member (`JhaScreens.tsx:1238-1264`). **You want:** drop
  the forced "Driver" row (the signed-in user *is* the driver), keep Additional Crew, and
  add **Owner** / other roles. Supervisor & Customer Rep usually aren't present.
- **Signatures** ⚠️ → see **T1** (boxes too small, can't sign, want landscape).
- **Pre-fill is fine** where the defaults are good (fit-for-duty, hours-of-service,
  route/weather). Keep, but make sure anything that must be driver-confirmed on-site
  isn't pre-checked.

### 7. SOPs tab 🔵 / 🟠
- **"Emergency SOPs" shouldn't be a category** 🔵 — there's a dedicated Emergency SOPs
  screen + button (`SopExtraScreens.tsx:229-279`, `App.tsx:1433`). **Your view:** SOPs are
  just SOPs — one plain list. Fold emergency procedures into the single list (tag them if
  needed).
- **SOPs should be viewable without signing in** 🟠 — today the SOPs tab only exists
  inside the authenticated shell (`App.tsx:843`). You want them readable pre-auth.
  (Needs Hub to serve SOPs without a session.)

### 8. Sync tab 🔴
- **"Sync Now" didn't sync your work** — it called `doRefresh()`, which only refreshed
  your Hub **session/gate state** (`App.tsx:854 → 494-510`); it did **not** flush the
  outbox / upload pending tickets. The label was a promise the button didn't keep.
  **Resolved:** it now refreshes Hub status and kicks the real sync/upload runners.
- **"View Pending Items" actually works** ✅ (`SyncScreens.tsx:155-161`).

### 9. More tab 🔵 / 🟢
- **"Midland Office" contact** 🔵 — there's a contact literally named "Midland Office"
  (`MoreScreens.tsx:734-744`). No such office — it's **Field Dispatch**. Remove/rename.
- **Call / Message are dead** 🔴 — `onCall`, `onMessage`, `onSendJobLocation` all wired
  to `noop` (`App.tsx:1701-1703`). **Call should dial the on-duty dispatcher** (RN
  `Linking`).
- **Messaging** 🟢 — you like dispatcher messaging; it belongs to the **dispatch version**
  of Field Capture (drivers ↔ on-duty dispatcher, send job location). New feature.
- Language / Theme → see **T3**.

### 10. Overall polish 🟠
Your closing note — "the rough line seems like it's getting there but it's still pretty
rough." Treat as a final visual-polish pass after the functional fixes land.

---

## Decisions that are yours to make (everything else is just "do it")

1. **Tabs: top or bottom?** (Bottom-with-safe-area is the smaller change; top is what you
   leaned toward.)
2. **Theme/Language:** build for real now, or hide the toggles until the infra exists?
3. **"Sync Now":** make it a real outbox flush, or rename to "Check Status" for now? **Resolved: wired to the real sync/upload runner kick.**
4. **"Add Evidence" on Job Overview:** keep as quick action, fold into Evidence flow, or
   drop?
5. **SOPs without sign-in** depends on the Hub serving them unauthenticated — in scope now
   or later?

## Suggested sequencing

1. **Safety-critical first:** pre-trip validation + real counts, signatures (T1),
   stop-work language. These are compliance integrity.
2. **Policy:** remove in-app punch (T2); make GPS background.
3. **Quick truth-in-UI wins:** kill/relabel dead buttons (View DVIR, View Spanish, Sync
   Now, Call/Message, Directions/Dispatch), Midland Office rename, default-not-checked,
   bigger filter + tab targets.
4. **Theme/Language (T3)** — build or hide.
5. **New:** dispatcher messaging + call.
6. **SOPs** restructure + pre-auth access.
7. **Polish pass.**

---

## Progress tracker (execution against `driver-app-completion-goal.md`)

Cross-cutting:
- [x] **T1** — Finger-drawable landscape `SignatureField` + stroke model (built, tested). Integrate into ↓
- [x] **T2** — Remove in-app Punch In/Out; status display-only (inspections gated behind punched-in; PunchScreens orphaned — delete in final sweep)
- [x] **T3a** — Real `ThemeContext` + dark mode applies app-wide + persists (SecureStore); every screen reads via `useResolvedTheme`
- [x] **T3b** — Language toggle hidden until i18n ships (no dead control); TODO left in MoreHomeScreen

Safety-critical:
- [x] Pre-Trip DVIR: default Not-Checked, 62 items in one scroll, gate Continue, REAL counts, prefill driver id, finger signature
- [x] JHA stop-work: anyone-has-authority + tailgate-meeting acknowledgement
- [x] JHA / Post-Trip / Evidence signatures use `SignatureField`

Truth-in-UI:
- [x] Pre-Trip "View DVIR Form" / "View in Spanish" removed (no real target; Spanish needs i18n)
- [x] Job menu "Directions" (maps) / "Dispatch" (tel) wired via `Linking`
- [x] More: Call/Message dispatcher via `Linking`; "Midland Office" removed → "Field Dispatch" (on-duty dispatcher)
- [x] JHA "Other" PPE fill-in field
- [x] JHA crew roles configurable (drop forced "Driver"/Supervisor/Customer rows, add "Owner")
- [x] Jobs status filters ≥48px tap targets
- [x] JSA copy = tank-battery/loading, not driving

Screens:
- [x] Job Overview: GPS automatic/background (removed button + note); "Add Evidence" navigates to Evidence flow (de-duped from menu)
- [x] SOPs: collapsed to one "SOPs" list + Search (no "Emergency" category/filter); pre-auth "View SOPs" entry uses the same readable offline SOP browser from the sign-in screen
- [x] Sync: "Sync Now" is truthful again — it refreshes Hub status and kicks the real sync/upload runners
- [x] Tab bar → top (user's lean), border-bottom + larger tap area

New:
- [x] Driver→dispatcher Call / Message / Send-job-location via the OS (`Linking`) to the on-duty dispatcher (ContactDispatch + Help). Full in-app *threaded* messaging = the separate dispatch build (needs Hub) — deferred TODO.

Final:
- [x] Zero `flowNoop`/`noop` on user-facing buttons (verified by grep); orphaned `PunchScreens.tsx` deleted; full suite green (463)
