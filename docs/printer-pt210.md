# Field Capture — Printer Requirement (PT-210)

## Status

First target printer is a **specific, named device**. The printer requirement is no longer
generic. The iOS spike proved a direct BLE GATT + ESC/POS path for the PT-210; Field Capture now
includes an iOS `FieldPrinter` CoreBluetooth module behind the existing printer abstraction.

## Target hardware

- **Product:** Thermal Receipt Printer, PT-210 58mm Portable Thermal Printer — Handheld
  Ticket / Bill Printer (retail / restaurant / factory / logistics / small business).
- **Amazon ASIN:** `B0CL4853RB`
- **Class:** handheld, 58mm thermal, battery-powered.
- Treat as **printer #1** for Field Capture. Other printers may be added later behind the
  same abstraction (see Architecture).

## Hard rules

1. **Print directly from inside Field Capture** if the hardware allows it.
2. **Forbidden workflow:** save ticket as image → open image → switch to a printer/vendor
   app → print manually. This friction path is explicitly disallowed.
3. **Printing is an output artifact, not a source of truth.** Ops Hub + Field Capture
   data are authoritative. A printed ticket is a side effect. Every print is logged
   locally and later synced to Hub.
4. **Keep printer access behind the abstraction.** Feature code must still call the shared
   printer runtime/transport seam rather than the BLE module directly.
5. **No AirPrint or vendor-app path.** The verified iPhone path is CoreBluetooth BLE GATT, not
   AirPrint, Bluetooth Settings printer selection, or Bluetooth Classic serial.

## Hardware spike — critical facts

The iOS spike proved the items needed for direct iPhone printing:

| #   | Unknown                                                       | Why it matters                                                   |
| --- | ------------------------------------------------------------- | ---------------------------------------------------------------- |
| 1   | BLE GATT works from iOS                                       | Use CoreBluetooth directly.                                      |
| 2   | Preferred service / characteristic                            | `18F0` / `2AF1`.                                                 |
| 3   | Raw ESC/POS command support                                   | `EscPosEncoder` can drive receipts directly.                     |
| 4   | Printable dot width                                           | 384 dots / 48 mm.                                                |
| 5   | Bitmap/signature command                                      | GS `v 0` raster image bytes work.                                |
| 6   | Cutter support                                                | Omit cut commands; manual tear only.                             |
| 7   | Text encoding                                                 | Keep output ASCII-safe unless codepage handling is added.        |

Still to verify in production-style field runs: QR/barcodes, paper legibility for final ticket
layouts, reconnect after sleep/restart, low-battery behavior, and offline queued print drain.

## iOS path

- The PT-210 advertises as `PT-210_261D`.
- PIN, if pairing is requested: `0000`.
- Preferred service: `18F0`.
- Preferred characteristic: `2AF1`.
- Write type: with response.
- Payload format: ESC/POS.
- Paper: 58 mm.
- Printable width: 48 mm / 384 dots.
- Cut command: omit, manual tear only.

This is not AirPrint. It is direct BLE GATT writing from CoreBluetooth.

## Architecture — printer abstraction (not screen-to-printer code)

No direct render-to-printer calls anywhere. All printing flows through an abstraction so
new printers/transports drop in without touching feature code.

Required interfaces / components:

- **`PrinterService`** — top-level API used by features (print ticket, print JHA/JSA
  receipt). Owns the queue, selects profile + transport, returns `PrintResult`.
- **`PrinterTransport`** — interface for moving raw bytes to a device. The only
  `PrinterTransportKind` is `ble-gatt`:
  - **`BleTransport`** — BLE GATT over CoreBluetooth (the verified iPhone path).
- **`EscPosEncoder`** — builds raw ESC/POS byte streams (text, alignment, bold/size,
  separators, bitmap, QR/barcode) — only the subset the verified profile supports.
- **`PrinterProfile`** — capability descriptor per printer model (see PT-210 profile).
- **`PrintJobQueue`** — durable, offline-capable queue; survives app restart; retries.
- **`PrintResult`** — outcome of one job (success / failure + error code + diagnostics).
- **`PrinterDiagnosticReport`** — structured output of the hardware spike + runtime
  self-tests (what transport connected, what capabilities verified, failures).

## PT-210 PrinterProfile

```yaml
model_name: PT-210
paper_width_mm: 58
command_set: escpos
transport: ble-gatt
printable_width_dots: 384
supports_bitmap: true
supports_qr: unknown # MUST verify
supports_cut: false
supports_cash_drawer: irrelevant
requires_vendor_app: false
target_use: field ticket / receipt style printing
```

Profile values come from the iOS spike guide at an internal PT-210 iOS printing spike guide.

## Print job model

```yaml
print_job_id: # unique id
sr_id: # service request this print belongs to
field_ticket_id: # field ticket id
employee_id: # who triggered the print
printer_profile_id: # which profile/printer
created_at: # enqueue time
printed_at: # completion time (null until printed)
status: # queued | printing | printed | failed | canceled
retry_count: # attempts so far
error_code: # machine-readable failure code
raw_diagnostic_message: # raw transport/encoder error text
```

Every job is logged locally on creation and on each status change, then synced to Field
Hub. Hub stores the audit trail; the phone holds the queue.

## Hardware spike — test matrix

The spike is a **minimal proof**, not the full feature. It must print/exercise:

1. Plain text test
2. Bold / large text test
3. Left / center / right alignment test
4. Separator lines
5. Field ticket mock layout
6. JHA/JSA confirmation receipt
7. Signature bitmap test _(if `supports_bitmap` verified true)_
8. Reconnect after app restart
9. Reconnect after printer sleep
10. Offline queued print job (enqueue offline → flush on reconnect)

## Minimal proof — scope for first build (do NOT build full feature yet)

Build only enough to answer the protocol questions:

1. **Connect** to the PT-210 over BLE GATT via CoreBluetooth.
2. **Send raw bytes** over the BLE transport.
3. **Print one formatted test receipt** (plain + bold + alignment + separator).
4. **Report which command set works** (the verified profile is ESC/POS over `18F0` / `2AF1`).

Output of the proof = a populated `PrinterDiagnosticReport` + an updated PT-210
`PrinterProfile` with the `unknown` fields resolved. That report gates the framework
decision in Prompt 2.

## Native binding status

The shared JS binding path exists behind `FieldPrinter` and feeds the durable print runtime.

- **`Pt210NativeBinding`** (`apps/mobile/src/adapters/printer/Pt210Module.ts`) —
  seam: `discover / connect / disconnect / isConnected / status / reconnect / writeBytes`.
  Calls are time-bounded from JS, validate the native module shape, map native `ERR_PT210_*`
  failures to diagnostic domain codes, and return structured status/readiness. Native absence
  still resolves to `undefined`; `Pt210PrinterTransport` turns that into `NotImplementedError`,
  which the queue records as `printer-not-implemented`.
- **iOS native module** (`apps/mobile/ios/FieldCapture/FieldPrinter.swift`) — React Native module
  named `FieldPrinter`. It scans BLE without a service filter, returns PT-210 candidates first,
  connects with CoreBluetooth, discovers services/characteristics, selects the preferred
  `18F0` / `2AF1` write-with-response characteristic, writes chunks acknowledged by
  `didWriteValueFor`, reports status, reconnects within the current app session, and disconnects.
  Permission, Bluetooth-off, no-adapter, bad-device-id, connect, timeout, no-writable-characteristic,
  not-connected, reconnect, and write failures reject visibly.
- **`createEscPosEncoder`** (`packages/contracts/src/printer/escpos.ts`) — ESC/POS subset
  (reset / text / bold / align / separator / feed / GS `v 0` bitmap). `qr()` still throws until
  QR/barcode support is verified.
- **`createPt210TestReceipt`** — minimal ESC/POS diagnostic receipt generator used by the
  command and screen. It sends the same contract encoder bytes as the print runtime.
- **`PrintRuntime`** (`apps/mobile/src/runtime/printRuntime.ts`) — drives the durable
  `PrintJobQueue` (SQLite-backed, migration v5) and emits append-only `print.event`
  operations (queued/printed/failed/canceled) into the durable sync outbox. A job becomes
  Hub-durable (`markSynced` → purgeable) ONLY when its terminal event is ACCEPTED by Hub;
  nothing is removable before printed + synced.
- **Diagnostic paths** — `runPt210Diagnostic` is the command-level check; the Print panel also
  exposes `Pt210DiagnosticScreen` buttons for discover, connect, print test receipt, signature
  bitmap test, status, reconnect, and disconnect. Without a binding every check remains `untested` /
  `printer-not-implemented`; with hardware it records visible success/failure lines.

## iOS setup and permissions

Use an iOS development or release build installed on a physical iPhone. The Simulator cannot
prove Bluetooth hardware behavior.

1. Build/install an iOS dev/release binary from the Xcode-owned workspace after the
   `FieldPrinter` native code is present.
2. There is no system pairing step. The PT-210 is discovered directly as a BLE peripheral
   (`PT-210_261D`); do not select it in iOS Settings → Bluetooth.
3. Grant the Bluetooth permission when prompted. The app declares
   `NSBluetoothAlwaysUsageDescription` in `Info.plist`; CoreBluetooth prompts the user on first
   scan/connect.
4. Open Field Capture → Print panel → PT-210 Diagnostic.
5. Run the buttons in order: Discover → Connect → Test Receipt → Status → Reconnect →
   Disconnect. Record every visible line and photograph the paper output.

If the native module is missing, the diagnostic must show `printer-not-implemented`. If Bluetooth
is disabled, the permission is denied, the peripheral is not found, connect times out, or write
fails, the diagnostic must show an error and the print queue must retain the job.

Common diagnostic/domain codes:

| Native code | Visible domain code | Meaning |
| --- | --- | --- |
| `ERR_PT210_PERMISSION_DENIED` | `permission-denied` | The Bluetooth permission was denied. |
| `ERR_PT210_BLUETOOTH_UNAVAILABLE` | `bluetooth-unavailable` | The iPhone has no usable Bluetooth radio. |
| `ERR_PT210_BLUETOOTH_DISABLED` | `bluetooth-disabled` | Bluetooth is off. |
| `ERR_PT210_DISCOVERY_FAILED` | `discovery-failed` | The BLE scan did not start. |
| `ERR_PT210_BAD_DEVICE_ID` | `bad-device-id` | The selected peripheral identifier is invalid. |
| `ERR_PT210_CONNECT_FAILED` | `connect-failed` | The CoreBluetooth connection failed. |
| `ERR_PT210_WRITE_FAILED` | `write-failed` | ESC/POS bytes were not fully written/acknowledged. |
| `ERR_PT210_NOT_CONNECTED` | `not-connected` | Print/test receipt was requested without a connected peripheral. |
| `ERR_PT210_NO_DEVICE` | `no-prior-device` | Reconnect was requested before any successful connection. |
| `ERR_PT210_TIMEOUT` | `timeout` | The native operation exceeded its bounded timeout. |

## iOS status

iOS support is implemented for the verified BLE GATT path in `FieldPrinter.swift`. A physical
iPhone build can run the Print panel diagnostic against `PT-210_261D`; the Simulator cannot prove
Bluetooth hardware behavior.

## Known PT-210 limitations still unverified

- QR/barcode commands remain unverified; the encoder still refuses them.
- Paper legibility for final production ticket layouts, sleep/restart reconnect, and low-battery
  behavior remain manual checklist items.
- A successful native write is not enough to mark a print job removable; the terminal
  `print.event` still must be accepted by Hub.

## Manual hardware diagnostic runbook (hardware-only — cannot be automated)

Run on a real iPhone with a PT-210 and paper loaded. Record each outcome in the
`PrinterDiagnosticReport` fields named below. Use the BLE device named `PT-210_261D`;
pairing in Settings is not the print path.

1. **Required build type** — install a native development or release build created after the
   printer native code is present. The Simulator is invalid for this checklist and must show
   `printer-not-implemented`.
2. **Permission and discovery** — grant the Bluetooth permission, enable Bluetooth, load paper, and
   keep the printer awake. iOS discovers the BLE peripheral directly; there is no system pairing
   step.
3. **Automated command** — run `runPt210Diagnostic`; confirm discovery, connect, plain text,
   bold, alignment, separators, field-ticket mock, status, reconnect-after-disconnect, and
   disconnect produce the expected report fields.
4. **Screen diagnostic** — use the Print panel buttons in order: Discover, Connect, Test
   Receipt, Signature Test, Status, Reconnect, Disconnect. Record visible results and any native
   error codes.
5. **Paper legibility** — visually confirm every printed pattern
   (text, bold, alignment, separators, mock ticket) is legible at 58 mm. Checks:
   `plainText…fieldTicketMock` stay `pass` only if the PAPER output is right, not just the
   write call.
6. **`reconnectAfterRestart`** — print once, force-stop + relaunch the app, print again
   without re-pairing.
7. **`reconnectAfterSleep`** — let the printer auto-sleep (or power-cycle it), then print;
   confirm the transport reconnects rather than hanging.
8. **Failure cases** — record at least permission denied, Bluetooth disabled, wrong device id,
   printer off/out of range, and mid-print power-off. Each must show an explicit error and leave
   queued/failed print jobs protected.
9. **`offlineQueuedJob`** — enable airplane mode, enqueue a ticket print (job must persist as
   `queued`), restart the app, disable airplane mode, run the queue; confirm exactly ONE
   print and that the job reaches `printed` → (after Hub ack) `synced`.
10. **`signatureBitmap` / `qrBarcode`** — `signatureBitmap` should pass on the verified raster
   path; `qrBarcode` stays `untested` until the QR command is proven.
11. Update `PT210_PROFILE`'s `unknown` fields and the `gateOutcome` from the completed report.

“Hardware support verified” means a named iOS build, iPhone model/OS, and physical PT-210 pass
the full checklist above with photographed paper output and recorded diagnostic codes. A successful
native `writeBytes` call alone is not verification, and it never makes a production print job
purgeable until the Hub accepts the terminal `print.event`.
