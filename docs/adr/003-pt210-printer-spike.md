# ADR 003 — PT-210 Printer Hardware Spike

## Status

Accepted (foundation phase). Resolved after the iOS PT-210 spike: direct CoreBluetooth BLE GATT
printing to `PT-210_261D` is now proven and implemented behind the `FieldPrinter` iOS native
module (`apps/mobile/ios/FieldCapture/FieldPrinter.swift`, bridged via
`apps/mobile/src/adapters/printer/Pt210Module.ts`).

## Context

First target printer (hard hardware constraint #1):

- PT-210 58 mm portable handheld thermal receipt printer
- Amazon ASIN: `B0CL4853RB`

The app must print field tickets and JHA/JSA receipts **directly from inside Field Capture**.
Forbidden workflow: save ticket as image → open a separate vendor/printer app → manually
print. At the start of the spike the PT-210 protocol was **unknown** — it could have been
BLE GATT, raw ESC/POS, vendor-app-only, or proprietary. The spike verified that the PT-210
exposes a clean **BLE GATT** profile with printable characteristics, reachable directly from
iOS via Core Bluetooth. Full design in `docs/printer-pt210.md`.

## Decision

The **implementation slice is an iOS PT-210 hardware spike** behind a printer abstraction.
No screen-to-printer code. The spike resolves a `PrinterDiagnosticReport` and fills the
`unknown` fields of the PT-210 `PrinterProfile`. That report **gates** ADR 001:

- clean BLE GATT with printable characteristics → raw ESC/POS over CoreBluetooth from iOS.
  **This is the verified path** and is now implemented in `FieldPrinter`.
- vendor-app-only with no embeddable protocol/SDK → **printer fails the project; replace the
  printer**, do not contort the app.
- proprietary undocumented protocol → change the **hardware** choice first, not the framework.

The spike determined: BLE GATT transport, raw ESC/POS command set, printable dot width,
character encodings/code pages, bitmap/signature support, QR/barcode support, and reconnect
behavior after app restart, after printer sleep, and after disconnect/low battery.

Printer rules (must be explicit in the module):
- PT-210 is target printer #1; iOS BLE GATT (CoreBluetooth) is the sole supported transport.
- UID/card/NFC concerns are **not** part of the printer module.
- Printing is **not** source of truth — Ops Hub data is. Every print job/event is logged
  locally and syncable.

## Consequences

- Printer abstraction interfaces ship in Slice 1: `PrinterService`, `PrinterTransport`,
  `BleTransport` (the only `PrinterTransportKind` is `"ble-gatt"`), `EscPosEncoder`,
  `PrinterProfile`, `PrintJob`, `PrintJobQueue`, `PrintResult`, `PrinterDiagnosticReport`.
- Real printing was **not** claimed to work until hardware proved it. The transport started as a
  placeholder that threw `NotImplemented` until the `FieldPrinter` native module landed; it is
  now backed by CoreBluetooth and proven against a physical PT-210.
- CI must pass without a physical PT-210 — hardware tests are documented manual steps.
- Print job durability protected by ADR 002 (never silently evict unprinted/unsynced jobs).

## Rejected alternatives

- **Bluetooth Classic SPP / RFCOMM and USB-OTG transports** — out of scope; iOS reaches the
  PT-210 cleanly over BLE GATT, so these transports were never needed and are not supported.
- **Direct render-to-printer calls in screens** — unmaintainable, blocks new printers/transports.
- **Adopting a printer npm package as architecture** — spike tools only until protocol verified.

## Implementation impact

- Slice 1 (first code slice) implements the abstraction + iOS BLE GATT diagnostic + raw-byte and
  ESC/POS tests + reconnect tests + `PrinterDiagnosticReport`.
- Depends on Slice 0 (app skeleton) existing first — see plan.

## Open questions

- Actual PT-210 transport and command set (the whole point of the spike).
- Whether the unit ships an embeddable SDK or is vendor-app-only.

## Source report references

- `research/reports/02-framework-deployment-report.md` (printer feasibility matrix, decision gates)
- `docs/printer-pt210.md` (full printer requirement + spike test matrix)
