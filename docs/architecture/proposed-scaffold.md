# Scaffold (Slice 0) — ✅ IMPLEMENTED 2026-06-08

> **Status: built.** The owner approved bootstrapping (printer deferred to a placeholder; iOS-only
> target; monorepo layout). The app now lives in **`apps/mobile`**; the proposal below is kept for
> the record. What was actually built differs from the original sketch in two ways:
>
> **Historical note:** this document predates the move to a bare React Native + Xcode-owned iOS
> workspace (no Expo as runtime/build tool) and an iOS-only target. The Expo/EAS toolchain and any
> Android-related framing below are retained only as a record of the original Slice 0 proposal.
>
> - **Layout:** a monorepo — `apps/mobile` (Expo app) + `packages/contracts` (shared pure-TS) —
>   _not_ `create-expo-app .` at the repo root. The app consumes `@fieldcapture/contracts` as a
>   workspace package; domain logic stays in `packages/contracts` (no `src/domain/` split).
> - **Test runners:** **both** — `jest-expo` for the app, Vitest for `packages/contracts` (its
>   32 tests untouched) — rather than picking one.
>
> Originally proposed (NOT how it shipped — see ADR-001): Expo SDK 56, React Native 0.85, React 19, TypeScript 6; `expo-dev-client`; `eas.json`
> channels `development`/`staging`/`production`; ESLint (eslint-config-expo flat) + Prettier;
> env-driven `app.config.ts` (`APP_ENV` → Hub URL). See the foundation plan, Slice 0.

---

The repo originally had **no app skeleton**. Bootstrapping an app is a large, opinionated,
hard-to-revert change, so per the task guardrails it was **not** done automatically. This
document is the original proposal that was reviewed before the bootstrap commands were run.

## What would be created

```
fieldcapture/
  package.json              # Expo + TypeScript
  app.json / app.config.ts  # Expo app config (dev/staging/prod via env)
  eas.json                  # EAS Build profiles + Update channels (staging, production)
  tsconfig.json
  babel.config.js
  .env.example              # OPS_HUB_URL_DEV / _STAGING / _PROD  (no secrets)
  src/
    domain/                 # pure contracts (printer, sync, fieldwork, budget)
    data/  runtime/  adapters/  features/
  __tests__/                # or co-located *.test.ts
  App.tsx
```

## Proposed toolchain

- **Expo SDK** (latest stable) with **TypeScript**, **prebuild / development-build** workflow
  (NOT Expo Go as the product runtime).
- **EAS** Build + Submit + Update; channels `staging` and `production`.
- **Test runner:** `jest-expo` for app/integration; optionally **Vitest** for pure-domain
  packages (`src/domain/**`) which have no native deps. Pick one to start — recommendation:
  `jest-expo` (one runner, RN-aware). Decision left to owner.
- **Lint/format:** ESLint + Prettier (Expo defaults).

## Bootstrap commands (to run ONLY after approval)

```bash
# from repo root, on branch feat/mobile-architecture-foundation
npx create-expo-app@latest . --template blank-typescript   # into existing dir
npx expo install expo-dev-client
npm i -D jest jest-expo @types/jest
# eas-cli configured separately; eas.json authored by hand to set channels
```

(Exact commands finalized at run time against the current Expo SDK.)

## Why ask first

- Bootstrapping writes dozens of files + a lockfile and pins an SDK version — a big diff that
  changes the repo's nature from "docs" to "app."
- Test-runner choice (Jest vs Vitest split) is a standing decision worth confirming.
- It commits to Expo concretely; the owner may want to eyeball the plan/ADRs first.

## Alternative if you want progress without bootstrapping the full app

Author the **pure-TypeScript contract packages** (Slices 3, 4, 6 and the Slice 1 printer
abstraction) as a tiny standalone TS package (just `package.json` + `tsconfig` + Vitest) under
`packages/contracts/`, with no Expo/native. This gives real, tested code now and folds into the
Expo app later. Lower blast radius than a full Expo bootstrap. Also offered as an option.
