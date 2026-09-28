# Persistent, Live-Reloading Dev Environment for Field Capture

> Historical React Native research. The shipping app is now the pure Swift project under
> `apps/native`; use [the native iPhone workflow](iphone-dev-workflow.md). This report remains only
> for comparing behavior against the legacy parity implementation.

**Goal of this report:** make the dev setup *stay open* and *take your edits as they come* — no manual
"rebuild / reopen / restart the app" step in the normal edit loop. You start a few long-lived
watchers **once**, then just edit code and watch it apply.

> **Status:** research report (no code changed). Backed by the official React Native docs — see
> [Sources](#sources). Tailored to this repo's actual config (`apps/mobile/metro.config.js`,
> `@fieldcapture/contracts`, the Swift `FieldPrinter` BLE module, and the Xcode-owned iOS workspace).
>
> 📱 **iOS-only app.** Field Capture is bare React Native with an Xcode-owned iOS workspace — there is no
> Android target. The Fast-Refresh model below (green/yellow/red zones) is what you live in day to day;
> only a *native* change forces a rebuild, and that rebuild happens in **Xcode** (plus
> `./scripts/install-ios-pods.sh` when pods change). For the iPhone install + Metro-connect flow, see
> [`iphone-dev-workflow.md`](./iphone-dev-workflow.md).

---

## 1. The one-paragraph answer

For **~95% of your edits — anything written in JavaScript/TypeScript** (every screen, the runtime
engines, the domain logic, *and the entire `@fieldcapture/contracts` package*) — you already get exactly
what you want: **Metro's Fast Refresh** pushes the change into a **build that stays open on the iPhone /
simulator**, with React state preserved where it's safe. You launch Metro once (`npm start`), keep the
app open, and never restart either for a code edit. The **one** thing no tool can make live is **native
code** — your Swift PT-210 printer module (`FieldPrinter.swift`), adding/removing a native dependency, or
changing a CocoaPods dependency. Those compile *into the app binary*, so they need **one** rebuild in
Xcode (and `./scripts/install-ios-pods.sh` first when a pod changed). That is a hard architectural
boundary, not a setting you can flip. The trick to "it just stays open" is therefore: **keep JS-only
changes JS-only**, and treat a native rebuild as a rare, deliberate event rather than part of the edit
loop.

---

## 2. Mental model: two layers, one boundary

| Layer | What lives here | How your edit lands | Do you touch anything? |
|---|---|---|---|
| **JS layer** (the bundle Metro serves) | All `.ts`/`.tsx`: screens, `src/runtime/*`, `src/domain/*`, `src/data/*`, `src/adapters/*`, **`packages/contracts/src/*`** | **Fast Refresh** (state-preserving) or, in some cases, an **automatic full reload** | **No.** Save the file. |
| **Native layer** (the compiled app binary) | `apps/mobile/ios/FieldCapture/FieldPrinter.swift` and other native Swift/Obj-C, native npm deps, anything under `ios/` (incl. `Podfile`) | **Rebuild** in Xcode | **Yes — one rebuild.** |

Everything below is just the detail of where that boundary sits and how to keep your watchers alive.

---

## 3. GREEN zone — applies live, keeps state, zero manual action

These are **Fast Refresh** (React Native's hot-reloading), enabled by default and served by Metro.
Verified rules from the official RN docs:

- **Editing a module that only exports React component(s)** → Fast Refresh updates *only that module* and
  re-renders the component. *"You can edit anything in that file, including styles, rendering logic, event
  handlers, or effects."* React state in the edited component is **preserved**.
- **React state preservation** holds **only for function components and Hooks** — `useState`/`useRef`
  keep their values as long as you don't change a Hook's arguments or the order of Hook calls. Class
  components do **not** preserve state.
- **`// @refresh reset`** — add this comment anywhere in a file to *force* a remount on every edit (useful
  for a screen whose mount-time effect you're iterating on).
- **Errors are recoverable in place** — a syntax error or a runtime error during render shows a redbox;
  **fix and save and the session continues** — no manual reload needed.

➡️ **This is the heart of "stay open and take the change."** For UI and logic work, you are already done.

### 3a. The `@fieldcapture/contracts` package is in the green zone too — and needs **no build step**

This is a tailored, important finding for your repo:

- `packages/contracts/package.json` sets `"main": "src/index.ts"` and `"types": "src/index.ts"` — i.e. it
  is consumed as **raw TypeScript source**, with **no `dist/` build**. (Confirmed: there is no `dist/`.)
- `apps/mobile/metro.config.js` watches the whole monorepo, so when you edit
  `packages/contracts/src/sync/outbox.ts`, **Metro sees it and transpiles the source directly** — the
  change Fast-Refreshes into the running app **with no compile step**.
- **Therefore you do *not* need `tsc --watch` on contracts for the app to pick up changes.** You only run
  a contracts watcher for *developer feedback* you care about while editing it:
  - **Type errors as you type:** `npm run typecheck --workspace @fieldcapture/contracts -- --watch`
    (i.e. `tsc --noEmit --watch`).
  - **Tests as you type:** `npm run test:watch --workspace @fieldcapture/contracts` (Vitest watch).
  - Both are *optional* feedback loops; neither is required for the app to live-reload.

> ⚠️ **Caveat — non-component exports cause a wider refresh (still automatic).** See the YELLOW zone: most
> `contracts` symbols are plain functions/values, not React components, so editing them re-runs importers
> and often triggers a **full reload** of the app. That's still hands-off (no rebuild), you just lose
> in-app navigation/JS state for that reload.

---

## 4. YELLOW zone — automatic *full reload* (hands-off, but loses JS state)

Fast Refresh sometimes can't do a surgical update and **falls back to a full JS reload by itself**. You
don't press anything — the app reloads from the current bundle in well under a second. You only "lose"
transient in-app state (which screen you were on, form input). Verified triggers:

- **Editing a module whose exports are *not* React components** → Fast Refresh re-runs that module **and
  every module importing it**. (e.g. editing a shared theme or a `contracts` helper updates all consumers.)
- **Editing a file imported by modules *outside* the React tree** → Fast Refresh **falls back to a full
  reload**. This is common for shared/non-component modules — which is exactly what most of
  `@fieldcapture/contracts`, `src/domain/*`, and `src/runtime/*` are.

**Implication for your workflow:** UI/screen edits = instant state-preserving refresh; domain/contract/
runtime edits = automatic full reload. Both are "stays open, takes the change." Neither needs a rebuild.

---

## 5. RED zone — the hard ceiling: changes that REQUIRE a rebuild

This is the only thing that breaks "just stay open." A change that touches the **native binary** requires
building a new copy of the app in Xcode; Metro and Fast Refresh only ever move JS and assets.

For **this repo** specifically, that means a rebuild is required when you:

1. **Edit the Swift PT-210 module** — `apps/mobile/ios/FieldCapture/FieldPrinter.swift` (the CoreBluetooth
   BLE GATT printer driver) or its bridging header / Obj-C glue. This is native code; Fast Refresh cannot
   touch it.
2. **Add/remove/upgrade a native dependency** (any npm package that ships native iOS code).
3. **Change a CocoaPods dependency** — anything in `apps/mobile/ios/Podfile` (or `Podfile.lock`).
4. **Change anything else under `ios/`** — Info.plist (permissions/usage strings), entitlements, app
   icons/launch screen, bundle id, build settings.

**The rebuild flow for this repo:**

```bash
# 1. If a pod / native dependency changed, reinstall pods first:
./scripts/install-ios-pods.sh

# 2. Then build + run from Xcode:
#    open apps/mobile/ios/FieldCapture.xcworkspace and hit Run (⌘R),
#    targeting the connected iPhone or a simulator.
```

The new build **auto-reconnects to your still-running Metro** — you do not restart Metro to rebuild the
app. If you only changed Swift/native code (no pods), you can skip step 1 and just rebuild in Xcode.

> The PT-210 thermal printer talks to the app over **iOS BLE GATT (CoreBluetooth)**, implemented in
> `apps/mobile/ios/FieldCapture/FieldPrinter.swift` and bridged to JS via
> `apps/mobile/src/adapters/printer/Pt210Module.ts`. The only `PrinterTransportKind` is `"ble-gatt"`.
> Editing the Swift driver requires a fresh Xcode build; editing the TS bridge/adapter is a JS change and
> Fast-Refreshes.

### 5a. What does NOT remove this limit (so you don't chase dead ends)

- **There is no "hot-reload native code" mode.** Native code is compiled into the app binary; the React
  Native architecture has no mechanism to swap it at runtime. Plan around it, don't fight it.
- **Reloading the JS bundle does nothing for native changes.** Shake → Reload, or any Metro reload, only
  re-runs the current JS bundle against the *already-installed* native binary.

### 5b. How to keep the RED zone rare (the real "stay open" strategy)

- **Do native work in batches.** When iterating on the PT-210 module, change the Swift, rebuild **once**,
  then do all the JS-side wiring/testing against that one build with Fast Refresh.
- **Keep the printer behind its JS seam.** This repo already routes printing through a TS abstraction
  (`PrinterTransport`/`PrinterService`) with the native module behind it — so most printer *logic*
  iteration is JS (green/yellow zone), and only genuine native-binding changes hit the red zone.
- **Rebuild with Metro still running** — after the Xcode build, the new app **auto-reconnects to your
  still-running Metro**. You do not restart Metro to rebuild the app; Metro is the stable anchor.

---

## 6. The exact persistent setup — what to launch once and leave running

Run these as **long-lived processes** (one more if you want type-checking). Start them once per work
session; after that you only edit files.

### Process 1 — Metro (the JS watcher/bundler) — **the one that makes the app live**
```bash
cd apps/mobile
npm start                      # the React Native dev server (already your start script)
```
- Leave it running all day. It watches your files and serves Fast Refresh.
- You restart Metro **only** for the cache/config cases in §8 — *not* for ordinary edits.

### Process 2 — the app, open on the iPhone / simulator
- Build/install it **once** from Xcode (open `apps/mobile/ios/FieldCapture.xcworkspace`, hit Run). This
  launches it and connects to Metro.
- After that, **keep the app open**. It holds the connection to Metro and applies Fast Refresh/reloads.
- If it ever disconnects (sleep, Wi-Fi blip), just reopen the app — it reconnects to the running Metro;
  no rebuild.

### Process 3 — the FastAPI Hub (`opshub`) on auto-reload
See §7. One command, leave running.

### Process 4 (optional) — contracts type/test feedback
```bash
# pick either or both; neither is required for the app to live-reload
npm run typecheck --workspace @fieldcapture/contracts -- --watch
npm run test:watch --workspace @fieldcapture/contracts
```

### Keep them all alive together
You want all of these supervised so a crash restarts them and you see combined logs. Options, simplest first:

- **A terminal multiplexer** (`tmux`) with one pane per process — zero new dependencies, survives SSH drops.
- **`concurrently`** (dev-dependency) to run them from one `npm run dev` script with prefixed logs.
- **`pm2`** if you want auto-restart-on-crash, log files, and `pm2 save`/`resurrect` across reboots —
  best fit for "I want these persistently running." Example:
  ```bash
  pm2 start "npm start" --name metro --cwd apps/mobile
  pm2 start "npm run test:watch --workspace @fieldcapture/contracts" --name contracts-test
  pm2 start "uvicorn app.main:app --reload --host 0.0.0.0 --port 8000" --name hub   # adjust to opshub
  pm2 save
  ```

---

## 7. The FastAPI Hub (`opshub`) — live API edits with `uvicorn --reload`

> Note: `opshub` is a **separate repo** (per project memory: FastAPI, `make up`, port 8000), not in this
> tree, so the exact module path is inferred — adjust `app.main:app` to its real entrypoint.

`uvicorn`'s `--reload` flag watches the source tree and restarts the worker on any `.py` change, so API
edits apply without you restarting anything:

```bash
uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
# narrow what it watches (faster, fewer false restarts):
uvicorn app.main:app --reload --reload-dir app --host 0.0.0.0 --port 8000
```

- **Bind `0.0.0.0`** so the phone/simulator can reach the Hub over LAN (matches your env-driven `hubUrl`).
  ⚠️ This exposes the Hub to your whole network, and the dev seed uses **password == username**
  (including an **ADMIN** superuser) — so only bind `0.0.0.0` on a network you control. Loopback
  (`127.0.0.1`) is the deliberate default. See `iphone-dev-workflow.md` §6 for the safer tunnel option.
- **If `make up` runs uvicorn in Docker:** `--reload` only works live if the source is **bind-mounted**
  into the container (a `volumes:` entry), otherwise the container has a frozen copy. Confirm the compose
  file mounts the source and that the uvicorn command includes `--reload`. Without the mount, you're back
  to rebuilding the image on each edit — the backend equivalent of the native-rebuild trap.
- **Reload caveat:** `--reload` restarts the *worker*, so in-memory state is lost on each edit and the
  first request after a reload pays a recompile cost. That's expected and fine for dev.

---

## 8. Gotchas, caches, and when a restart is genuinely unavoidable

**You DO have to act (restart Metro / clear cache / rebuild) in these cases — everything else is live:**

| Situation | Why | What to do |
|---|---|---|
| You **changed `metro.config.js`** (`watchFolders`/`resolver` config) | Metro caches resolved config | `npm start -- --reset-cache` once |
| **`tsconfig.json` path aliases** changed | Not picked up live by Metro | Restart Metro (`npm start`) |
| **Installed/removed an npm package** | New module map + possible native code | Restart Metro; **rebuild in Xcode** (and `./scripts/install-ios-pods.sh`) if the package ships native code |
| **Renamed/moved files** and Metro shows stale "module not found" | Stale Metro cache | `npm start -- --reset-cache` |
| **Anything under `ios/` (Swift, Podfile, Info.plist, entitlements)** changed | Native binary | `./scripts/install-ios-pods.sh` (if pods changed) + rebuild in Xcode (§5) |
| Fast Refresh "stopped working" / weird state | Bad cache or a non-Hook edit | Shake → **Reload**; if persistent, `npm start -- --reset-cache` |

**File-watcher tips:**
- Metro uses **Watchman** if installed (recommended; far fewer "too many open files" issues), else Node's
  watcher. Installing Watchman (`brew install watchman`) makes change-detection snappier across
  `watchFolders` and avoids most file-descriptor exhaustion in a large monorepo.

**Genuinely unavoidable full restarts (rare):** upgrading the React Native version; changing the JS
engine/Hermes config; corrupting `node_modules` (then `npm install` + `npm start -- --reset-cache` + a
clean Xcode rebuild).

---

## 9. Repo-specific action items (optional cleanups — still "no code logic" changes)

1. **Keep `apps/mobile/metro.config.js` lean.** It exists to teach Metro about the monorepo
   (`watchFolders`, resolver). If you change it, run `npm start -- --reset-cache` once so Metro picks up
   the new config.
2. **No `dist/` build needed for `contracts`** — keep consuming it as raw TS (`main: src/index.ts`). This is
   what makes contracts edits live with no build step; don't "fix" it by adding a build.
3. **Consider a one-shot `npm run dev`** at the repo root (via `concurrently`/`pm2`) that brings up Metro +
   contracts watch + Hub together, so "persistently running" is a single command.

---

## 10. Bottom line

- **JS/TS edits (incl. `contracts`): already live.** Start Metro once, keep the app open, edit, done.
  No rebuild, no reopen, no restart.
- **The only break is native code** (the Swift `FieldPrinter` PT-210 module, native deps, pods): **one**
  Xcode rebuild (run `./scripts/install-ios-pods.sh` first if pods changed), after which Metro/Fast
  Refresh resume. Batch native work so this is rare.
- **The Hub** stays live with `uvicorn --reload` (mount the source if Dockerized).
- **To keep it all "persistently running":** supervise Metro + contracts watch + uvicorn under `tmux`,
  `concurrently`, or `pm2`, and install Watchman for snappier file watching.

---

## Sources

Primary docs, re-fetched and verified on 2026-06-18 (the deep-research harness's automated verification
pass was invalidated by transient API rate-limiting — *not* by any source being wrong; the claims below
were re-confirmed directly):

- **React Native — Fast Refresh** (refresh-vs-reload rules, state preservation, `// @refresh reset`, error
  recovery): https://reactnative.dev/docs/fast-refresh
- **React Native — Running On Device** (build + run on a connected iPhone, Metro connection):
  https://reactnative.dev/docs/running-on-device
- **CocoaPods** (`pod install`, `Podfile.lock`, native dependency management):
  https://guides.cocoapods.org/using/pod-install-vs-update.html
- **Uvicorn** (`--reload`, `--reload-dir`): https://www.uvicorn.org/settings/

*Repo facts in this report were read directly from `apps/mobile/metro.config.js`, `apps/mobile/package.json`,
`packages/contracts/package.json`, `apps/mobile/ios/FieldCapture/FieldPrinter.swift`, and
`apps/mobile/src/adapters/printer/Pt210Module.ts`.*
