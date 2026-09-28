# Deep-research prompt 2 — Field Capture framework / build / deploy

Paste into GPT deep research. Self-contained.

> NOTE: The PT-210 thermal printer is a NAMED hardware constraint in this prompt. The
> Android-first hardware spike (see `../docs/printer-pt210.md`) and its
> `PrinterDiagnosticReport` GATE the final framework choice.

```text
You are a senior mobile platform architect. Research and DECIDE the app framework and build/deploy strategy for a small-team, self-hosted field app, then justify the decision with cited evidence.

PROJECT CONTEXT:
"Field Capture" is the field app for an oilfield-services system.

The larger system has:
- Ops Hub: FastAPI + React/Vite server, self-hosted on an office Windows PC
- Field Time: Raspberry Pi NFC time-clock
- Field Capture: phone app for drivers, dispatchers, and managers

No third-party cloud host is being paid for the core server. Field Capture must talk to the locally-hosted Ops Hub server, likely through LAN/VPN/HTTPS.

The team is essentially one developer. The owner has an iPhone. Android development is supported through emulator and physical Android testing.

Field Capture requirements:
- Offline-first
- Role-specific data caching
- Must run well on low-end personal Android phones
- Direct thermal receipt/ticket printer integration
- Camera capture of field tickets and receipts
- JHA/JSA digital signatures
- Background sync
- Future NFC support may be needed
- Production-style app behavior, not a development-only workflow

NAMED PRINTER CONSTRAINT:
The first target printer is:

PT-210 58 mm portable handheld thermal receipt printer
Amazon ASIN: B0CL4853RB

Field Capture must print field tickets and JHA/JSA receipts directly from inside the app.

Forbidden workflow:
- Save ticket as an image
- Open a separate vendor/printer app
- Manually print from that other app

The PT-210 connection protocol is not yet verified. It may be one or more of:
- Bluetooth Classic SPP/RFCOMM
- Bluetooth Low Energy / BLE GATT
- USB OTG
- Vendor-app-only
- Raw ESC/POS-compatible
- A proprietary command protocol

The framework decision must be gated by an Android-first PT-210 hardware spike.

The spike must verify:
- Bluetooth Classic SPP/RFCOMM support
- BLE GATT support
- USB OTG support
- Raw ESC/POS support
- Whether a vendor app is required
- Printable dot width
- Character encodings/code pages
- Bitmap/signature support
- QR/barcode support
- Reconnect after app restart
- Reconnect after printer sleep
- Reconnect after disconnect/low battery

CRITICAL OWNER CONSTRAINT:
The owner does not want to be locked into a "development-only" workflow. They want the app to feel and function like a real production app, with:
- Real installable builds
- Real Apple TestFlight/App Store or internal deployment path
- Real Android deployment path
- Real over-the-air update path where allowed
- Not Expo Go forever

The owner is not refusing Expo. The owner wants to understand exactly how Expo, Apple developer accounts, Android distribution, OTA updates, and production deployment fit together.

ANDROID-FIRST RULE:
Android is the first proof of concept because low-cost receipt printers commonly expose Bluetooth Classic or USB paths that Android apps may access more directly.

Do not promise iPhone support until the PT-210 protocol is verified.

If the PT-210 is Bluetooth Classic SPP only, iOS support may be blocked or require Apple MFi / ExternalAccessory support.

If the PT-210 exposes BLE GATT correctly, iOS may be possible through Core Bluetooth.

DECISION REQUIRED:
Choose ONE primary path and justify it:

(a) Expo with EAS Build + EAS Update using managed/prebuild/dev-client
(b) Bare React Native with custom CI and OTA/update solution
(c) Native Swift + Kotlin
(d) Flutter
(e) Kotlin Multiplatform / KMP
(f) Another cross-platform alternative only if clearly superior

RESEARCH AND ANSWER:
1. Printer first:
   For each candidate path, evaluate proven ability to drive a handheld 58 mm ESC/POS-style thermal printer over:
   - Android Bluetooth Classic SPP/RFCOMM
   - Android BLE GATT
   - Android USB OTG
   - iOS Core Bluetooth
   - iOS ExternalAccessory/MFi if relevant

   Name concrete libraries, native modules, plugins, or required custom native code.

   Specifically answer:
   - Does Expo managed/prebuild/dev-client block Bluetooth Classic SPP on Android?
   - Would Expo require a custom native module?
   - Would Expo require config plugins?
   - Would Expo Go be insufficient?
   - Would bare React Native make this easier?
   - Would Flutter make this easier?
   - Would native Android/iOS make this easier enough to justify two codebases?

2. For each path, evaluate support for:
   - PT-210 printer integration
   - Future NFC
   - Background sync
   - Camera capture
   - Local SQLite or equivalent database
   - JHA/JSA signatures
   - App updates
   - Crash reporting/logging for a self-hosted environment

3. OTA update reality:
   Research and verify current status of:
   - EAS Update
   - CodePush or successor paths
   - React Native OTA limitations
   - Flutter OTA limitations
   - Apple rules on what OTA updates can and cannot change
   - Android rules/practical constraints
   - When App Store/Play Store review is required

4. Apple deployment for a solo developer/internal workforce app:
   Research:
   - Apple Developer Program
   - TestFlight
   - App Store public distribution
   - Apple Business Manager/custom apps
   - Ad hoc distribution
   - Enterprise distribution and why it may or may not apply
   - Whether an internal company app can avoid public App Store listing

5. Android deployment for internal/BYOD field workers:
   Recommend and compare:
   - Google Play internal testing
   - Google Play closed testing
   - Private app distribution
   - Managed Google Play
   - APK sideloading
   - MDM
   - Direct APK download
   Evaluate:
   - Ease for drivers
   - Update reliability
   - Security
   - User friction
   - Suitability for personal phones

6. Self-hosted backend implications:
   Evaluate framework friction for:
   - Production app pointing at LAN/VPN server
   - HTTPS/TLS requirements
   - Self-signed or private CA certificates
   - Certificate pinning or private CA installation
   - Switching dev/staging/production server URLs
   - Offline-first sync with intermittent connectivity

7. Solo-maintainer cost:
   Compare:
   - Build complexity
   - Native-module complexity
   - Long-term maintenance
   - Upgrade risk
   - Ejection/prebuild risk
   - Community support
   - Debugging hardware devices

DELIVERABLE:
Provide:

1. One recommended primary framework/build path.

2. Explicit reasoning tied to:
   - PT-210 printer transport support
   - Low-end Android phone support
   - Offline-first requirements
   - Production-feel requirement
   - OTA/update requirement
   - Apple deployment path
   - Android deployment path
   - Solo-maintainer burden

3. A concrete deployment pipeline:
   - Build
   - Sign
   - Distribute to Android testers/workers
   - Distribute to iOS testers/workers
   - OTA update flow
   - When a full store rebuild/review is required

4. The exact Apple account type and distribution method recommended.

5. The exact Android distribution method recommended.

6. A clear printer feasibility table:
   - Android Bluetooth Classic SPP
   - Android BLE
   - Android USB OTG
   - iOS BLE
   - iOS Classic/MFi
   - What each framework can support

7. A hardware-spike decision gate:
   - What PT-210 result confirms the recommendation
   - What PT-210 result changes the recommendation
   - What result makes iOS printing not feasible with this printer

8. Migration/escape hatch:
   - If Expo hits a wall
   - If bare RN hits a wall
   - If printer support forces native Android module
   - If iOS printing is blocked

Rules:
- Do not treat Expo Go as sufficient for this project.
- Do not promise iOS PT-210 support until the printer protocol is verified.
- Printer transport support is a first-class selection criterion.
- Prefer official Expo, React Native, Apple, Android, Flutter, and platform docs.
- Prefer sources from 2024-2026.
- Flag facts that changed recently.
- State confidence per claim.
```
