//
//  FieldTicketScreens.swift
//  Ported from apps/mobile/src/screens/FieldTicketScreens.tsx
//
//  Field Ticket pages (GUI Master §11 / screens 44-52) — the digital field ticket flow a driver
//  fills out after the JHA/JSA: Overview -> Job Info -> Times -> Load/Tank 1 -> Load/Tank 2 ->
//  Barrels & Line Items -> Evidence & Signature -> Review -> Submitted.
//
//  Self-managing form surfaces: every control owns its selected/typed state internally (seeded from
//  the matching optional prop) so it visibly responds on tap, and still calls the host's optional
//  callback when one is supplied. Required navigation callbacks (onBegin/onNext/onReview/onSubmit/...)
//  are driven by the app and pass through untouched. Driver-facing language only — no UUIDs,
//  payloads, queues, or env strings (GUI Master §20). Realistic sample fallbacks fill any absent
//  props so the screens are legible in isolation.
//

import SwiftUI

// MARK: - Shared driver-facing status vocabulary (GUI Master §20)

/// Evidence capture state — the small set an evidence row can be in.
enum EvidenceState: String {
    case notStarted = "Not Started"
    case captured = "Captured"
    case pendingSync = "Pending Sync"
    case synced = "Synced"
}

private let evidenceTone: [EvidenceState: Tone] = [
    .notStarted: .neutral,
    .captured: .info,
    .pendingSync: .warning,
    .synced: .success,
]

/// Ticket capture mode (GUI Master §44 selector).
enum TicketMode: String {
    case digital = "Digital"
    case paper = "Paper"
    case hybrid = "Hybrid"
}

private let ticketModes: [TicketMode] = [.digital, .paper, .hybrid]

// MARK: - Small presentational building blocks (local to this file)

/// A labelled read-only key/value row used by the Review summary.
private struct SummaryRow: View {
    var theme: Theme
    var label: String
    var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label)
                .font(.system(size: typeScale.caption, weight: .semibold))
                .foregroundStyle(theme.textMuted)
            Text(value)
                .font(.system(size: typeScale.body, weight: .bold))
                .foregroundStyle(theme.text)
        }
        .padding(.vertical, 6)
    }
}

/// A single labelled, self-managing text field. Holds its own value in state (seeded from the
/// initial value) so typing always shows; reports changes via the optional onChange.
private struct Field: View {
    var theme: Theme
    var label: String
    var placeholder: String
    var keypad: Bool
    var onChange: ((String) -> Void)?
    var testID: String?

    // Named distinctly from the `value` prop it's seeded from: the TS source shadows the prop name
    // with the local `useState` binding, which Swift can't do for two stored properties on one struct.
    @State private var text: String

    init(
        theme: Theme,
        label: String,
        value: String,
        placeholder: String = "",
        keypad: Bool = false,
        onChange: ((String) -> Void)? = nil,
        testID: String? = nil
    ) {
        self.theme = theme
        self.label = label
        self.placeholder = placeholder
        self.keypad = keypad
        self.onChange = onChange
        self.testID = testID
        _text = State(initialValue: value)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: spacing.xs) {
            Text(label)
                .font(.system(size: typeScale.label, weight: .semibold))
                .foregroundStyle(theme.textMuted)
            TextField(
                "",
                text: $text,
                prompt: Text(placeholder).foregroundColor(theme.textMuted)
            )
            .keyboardType(keypad ? .numberPad : .default)
            .font(.system(size: typeScale.body))
            .foregroundStyle(theme.text)
            .padding(.horizontal, spacing.md)
            .frame(minHeight: sizing.minTouchTarget)
            .background(theme.cardMuted)
            .overlay(
                RoundedRectangle(cornerRadius: sizing.radius)
                    .stroke(theme.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: sizing.radius))
            .onChange(of: text) { next in
                onChange?(next)
            }
            .accessibilityIdentifier(ifPresent: testID)
        }
    }
}

/// A paired feet / inches numeric input for gauge readings (GUI Master §47). Self-managing.
private struct FeetInchesField: View {
    var theme: Theme
    var label: String
    var onChangeFeet: ((String) -> Void)?
    var onChangeInches: ((String) -> Void)?
    var testID: String?

    // Named distinctly from the `feet` / `inches` props they're seeded from: the TS source shadows
    // both prop names with local `useState` bindings, which Swift can't do on the same struct.
    @State private var feetText: String
    @State private var inchesText: String

    init(
        theme: Theme,
        label: String,
        feet: String,
        inches: String,
        onChangeFeet: ((String) -> Void)? = nil,
        onChangeInches: ((String) -> Void)? = nil,
        testID: String? = nil
    ) {
        self.theme = theme
        self.label = label
        self.onChangeFeet = onChangeFeet
        self.onChangeInches = onChangeInches
        self.testID = testID
        _feetText = State(initialValue: feet)
        _inchesText = State(initialValue: inches)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: spacing.xs) {
            Text(label)
                .font(.system(size: typeScale.label, weight: .semibold))
                .foregroundStyle(theme.textMuted)
            HStack(spacing: spacing.sm) {
                HStack(spacing: spacing.xs) {
                    TextField(
                        "",
                        text: $feetText,
                        prompt: Text("0").foregroundColor(theme.textMuted)
                    )
                    .keyboardType(.numberPad)
                    .font(.system(size: typeScale.body))
                    .foregroundStyle(theme.text)
                    .padding(.horizontal, spacing.md)
                    .frame(minHeight: sizing.minTouchTarget)
                    .background(theme.cardMuted)
                    .overlay(
                        RoundedRectangle(cornerRadius: sizing.radius)
                            .stroke(theme.border, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: sizing.radius))
                    .onChange(of: feetText) { next in onChangeFeet?(next) }
                    .accessibilityIdentifier(ifPresent: testID.map { "\($0)-ft" })
                    Text("ft")
                        .font(.system(size: typeScale.label, weight: .bold))
                        .foregroundStyle(theme.textMuted)
                        .frame(width: 22)
                }
                .frame(maxWidth: .infinity)
                HStack(spacing: spacing.xs) {
                    TextField(
                        "",
                        text: $inchesText,
                        prompt: Text("0").foregroundColor(theme.textMuted)
                    )
                    .keyboardType(.numberPad)
                    .font(.system(size: typeScale.body))
                    .foregroundStyle(theme.text)
                    .padding(.horizontal, spacing.md)
                    .frame(minHeight: sizing.minTouchTarget)
                    .background(theme.cardMuted)
                    .overlay(
                        RoundedRectangle(cornerRadius: sizing.radius)
                            .stroke(theme.border, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: sizing.radius))
                    .onChange(of: inchesText) { next in onChangeInches?(next) }
                    .accessibilityIdentifier(ifPresent: testID.map { "\($0)-in" })
                    Text("in")
                        .font(.system(size: typeScale.label, weight: .bold))
                        .foregroundStyle(theme.textMuted)
                        .frame(width: 22)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

/// A capture/preview placeholder frame (real camera/signature pad is wired elsewhere).
private struct CaptureFrame: View {
    var theme: Theme
    var caption: String

    var body: some View {
        Text(caption)
            .font(.system(size: typeScale.label))
            .multilineTextAlignment(.center)
            .foregroundStyle(theme.textMuted)
            .padding(spacing.md)
            .frame(maxWidth: .infinity, minHeight: 96)
            .background(theme.cardMuted)
            .overlay(
                RoundedRectangle(cornerRadius: sizing.radius)
                    .strokeBorder(theme.border, style: StrokeStyle(lineWidth: 1, dash: [4]))
            )
    }
}

/// A small inline confirmation line — visible feedback for actions not yet fully wired.
private struct FeedbackLine: View {
    var theme: Theme
    var text: String
    var testID: String?

    var body: some View {
        Text(text)
            .font(.system(size: typeScale.label, weight: .bold))
            .foregroundStyle(theme.success)
            .accessibilityIdentifier(ifPresent: testID)
    }
}

/// A confirm modal overlay (presentational; no native modal dep).
private struct ConfirmOverlay<Content: View>: View {
    var theme: Theme
    var title: String
    /// TS prop name is `body`; renamed here to avoid clashing with SwiftUI's `View.body`.
    var bodyText: String
    var cancelLabel: String
    var confirmLabel: String
    var onCancel: () -> Void
    var onConfirm: () -> Void
    @ViewBuilder var children: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing.sm) {
            Text(title)
                .font(.system(size: typeScale.heading, weight: .heavy))
                .foregroundStyle(theme.text)
            Text(bodyText)
                .font(.system(size: typeScale.body))
                .foregroundStyle(theme.text)
            children()
            FieldButton(label: confirmLabel, onPress: onConfirm, testID: "ticket-confirm-yes", theme: theme)
            FieldButton(
                label: cancelLabel,
                onPress: onCancel,
                variant: .secondary,
                testID: "ticket-confirm-cancel",
                theme: theme
            )
        }
        .padding(spacing.lg)
        .background(theme.card)
        .overlay(
            RoundedRectangle(cornerRadius: sizing.cardRadius)
                .stroke(theme.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: sizing.cardRadius))
        .padding(.top, spacing.sm)
        .accessibilityIdentifier("ticket-confirm-overlay")
    }
}

extension ConfirmOverlay where Content == EmptyView {
    init(
        theme: Theme,
        title: String,
        bodyText: String,
        cancelLabel: String,
        confirmLabel: String,
        onCancel: @escaping () -> Void,
        onConfirm: @escaping () -> Void
    ) {
        self.init(
            theme: theme,
            title: title,
            bodyText: bodyText,
            cancelLabel: cancelLabel,
            confirmLabel: confirmLabel,
            onCancel: onCancel,
            onConfirm: onConfirm,
            children: { EmptyView() }
        )
    }
}

// MARK: - 44. Field Ticket Overview

struct FieldTicketOverviewScreen: View {
    /// When false, the ticket is locked behind the JHA/JSA.
    var jhaComplete: Bool
    var srNumber: String?
    var customer: String?
    var lease: String?
    var onSelectMode: ((TicketMode) -> Void)?
    var onBegin: () -> Void
    var theme: Theme?

    // Named distinctly from the `mode` prop it's seeded from: the TS source shadows the prop name
    // with the local `useState` binding, which Swift can't do for two stored properties on one struct.
    @State private var selectedMode: TicketMode

    init(
        jhaComplete: Bool,
        srNumber: String? = nil,
        customer: String? = nil,
        lease: String? = nil,
        mode: TicketMode? = nil,
        onSelectMode: ((TicketMode) -> Void)? = nil,
        onBegin: @escaping () -> Void,
        theme: Theme? = nil
    ) {
        self.jhaComplete = jhaComplete
        self.srNumber = srNumber
        self.customer = customer
        self.lease = lease
        self.onSelectMode = onSelectMode
        self.onBegin = onBegin
        self.theme = theme
        _selectedMode = State(initialValue: mode ?? .digital)
    }

    @Environment(\.fieldTheme) private var envTheme

    var body: some View {
        let t = theme ?? envTheme
        let sr = srNumber ?? "SR 2026-000001"
        let customerName = customer ?? "Acme Energy"
        let leaseName = lease ?? "Northfield Lease"

        if !jhaComplete {
            VStack(alignment: .leading, spacing: spacing.md) {
                Text("Field Ticket")
                    .font(.system(size: typeScale.title, weight: .heavy))
                    .foregroundStyle(t.text)

                Card(title: "Field Ticket Locked", testID: "ticket-locked", theme: t) {
                    StatusBadge(label: "Locked", tone: .neutral)
                    Text("Complete the JHA/JSA before starting the field ticket.")
                        .font(.system(size: typeScale.body))
                        .foregroundStyle(t.text)
                }
            }
            .padding(spacing.lg)
        } else {
            VStack(alignment: .leading, spacing: spacing.md) {
                Text("Field Ticket")
                    .font(.system(size: typeScale.title, weight: .heavy))
                    .foregroundStyle(t.text)

                Card(title: sr, tone: .highlight, testID: "ticket-overview-job", theme: t) {
                    Text("\(customerName) \u{00B7} \(leaseName)")
                        .font(.system(size: typeScale.body))
                        .foregroundStyle(t.text)
                    StatusBadge(label: "Not Started", tone: .neutral)
                }

                Card(title: "Ticket mode", theme: t) {
                    HStack(spacing: spacing.xs) {
                        ForEach(ticketModes, id: \.self) { m in
                            let selected = m == selectedMode
                            Button {
                                selectedMode = m
                                onSelectMode?(m)
                            } label: {
                                Text(m.rawValue)
                                    .font(.system(size: typeScale.label, weight: .bold))
                                    .foregroundStyle(selected ? t.onPrimary : t.textMuted)
                                    .frame(maxWidth: .infinity, minHeight: sizing.minTouchTarget)
                                    .padding(.horizontal, spacing.sm)
                                    .background(selected ? t.primary : Color.clear)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: sizing.radius)
                                            .stroke(selected ? t.primary : t.border, lineWidth: 1)
                                    )
                                    .clipShape(RoundedRectangle(cornerRadius: sizing.radius))
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("ticket-mode-\(m.rawValue)")
                        }
                    }
                }

                FieldButton(label: "Begin Ticket", onPress: onBegin, testID: "ticket-begin", theme: t)
            }
            .padding(spacing.lg)
        }
    }
}

// MARK: - 45. Field Ticket Job Info

struct FieldTicketJobInfoScreen: View {
    var ticketNo: String?
    var company: String?
    var date: String?
    var lease: String?
    var well: String?
    var rig: String?
    var driver: String?
    var orderedBy: String?
    var truckUnit: String?
    var trailerUnit: String?
    var onChangeField: ((String, String) -> Void)?
    var onNext: () -> Void
    var theme: Theme?

    @Environment(\.fieldTheme) private var envTheme

    var body: some View {
        let t = theme ?? envTheme

        VStack(alignment: .leading, spacing: spacing.md) {
            Text("Job Info")
                .font(.system(size: typeScale.title, weight: .heavy))
                .foregroundStyle(t.text)
            Text("We filled in what we already know. Check it and add anything missing.")
                .font(.system(size: typeScale.label))
                .foregroundStyle(t.textMuted)

            Card(title: "Ticket details", theme: t) {
                Field(
                    theme: t,
                    label: "Field Ticket No.",
                    value: ticketNo ?? "TKT-10488",
                    onChange: { onChangeField?("ticketNo", $0) }
                )
                Field(
                    theme: t,
                    label: "Company",
                    value: company ?? "Acme Energy",
                    onChange: { onChangeField?("company", $0) }
                )
                Field(
                    theme: t,
                    label: "Date",
                    value: date ?? "Jun 16, 2026",
                    onChange: { onChangeField?("date", $0) }
                )
                Field(
                    theme: t,
                    label: "Lease",
                    value: lease ?? "Northfield",
                    onChange: { onChangeField?("lease", $0) }
                )
                Field(
                    theme: t,
                    label: "Well #",
                    value: well ?? "114H",
                    onChange: { onChangeField?("well", $0) }
                )
                Field(
                    theme: t,
                    label: "Rig #",
                    value: rig ?? "\u{2014}",
                    onChange: { onChangeField?("rig", $0) }
                )
            }

            Card(title: "Crew and units", theme: t) {
                Field(
                    theme: t,
                    label: "Driver",
                    value: driver ?? "Truck 7 Driver",
                    onChange: { onChangeField?("driver", $0) }
                )
                Field(
                    theme: t,
                    label: "Ordered By",
                    value: orderedBy ?? "Acme Dispatch",
                    onChange: { onChangeField?("orderedBy", $0) }
                )
                Field(
                    theme: t,
                    label: "Truck Unit #",
                    value: truckUnit ?? "Truck 7",
                    onChange: { onChangeField?("truckUnit", $0) }
                )
                Field(
                    theme: t,
                    label: "Trailer Unit #",
                    value: trailerUnit ?? "Vacuum Trailer 19",
                    onChange: { onChangeField?("trailerUnit", $0) }
                )
            }

            FieldButton(label: "Next: Times", onPress: onNext, testID: "ticket-jobinfo-next", theme: t)
        }
        .padding(spacing.lg)
    }
}

// MARK: - 46. Field Ticket Times

enum TimeSlot: String {
    case yardArrival
    case timeIn
    case timeOut
}

/// A single time card that manages its own stamped value and edit state.
private struct TimeCard: View {
    var theme: Theme
    var slotKey: TimeSlot
    var label: String
    var onUseCurrentTime: ((TimeSlot) -> Void)?
    var onEditManually: ((TimeSlot) -> Void)?

    // Named distinctly from the `value` prop it's seeded from: the TS source shadows the prop name
    // with the local `useState` binding, which Swift can't do for two stored properties on one struct.
    @State private var currentValue: String
    @State private var editing = false

    init(
        theme: Theme,
        slotKey: TimeSlot,
        label: String,
        value: String,
        onUseCurrentTime: ((TimeSlot) -> Void)? = nil,
        onEditManually: ((TimeSlot) -> Void)? = nil
    ) {
        self.theme = theme
        self.slotKey = slotKey
        self.label = label
        self.onUseCurrentTime = onUseCurrentTime
        self.onEditManually = onEditManually
        _currentValue = State(initialValue: value)
    }

    /// A driver-readable current time stamp; deterministic-free (real clock is host-wired).
    private func stampNow() -> String {
        let now = Date()
        let calendar = Calendar.current
        let h = calendar.component(.hour, from: now)
        let m = calendar.component(.minute, from: now)
        let ampm = h >= 12 ? "PM" : "AM"
        let h12 = h % 12 == 0 ? 12 : h % 12
        return String(format: "%d:%02d %@", h12, m, ampm)
    }

    var body: some View {
        Card(title: label, testID: "ticket-time-\(slotKey.rawValue)", theme: theme) {
            if editing {
                TextField(
                    "",
                    text: $currentValue,
                    prompt: Text("8:30 AM").foregroundColor(theme.textMuted)
                )
                .font(.system(size: typeScale.body))
                .foregroundStyle(theme.text)
                .padding(.horizontal, spacing.md)
                .frame(minHeight: sizing.minTouchTarget)
                .background(theme.cardMuted)
                .overlay(
                    RoundedRectangle(cornerRadius: sizing.radius)
                        .stroke(theme.border, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: sizing.radius))
                .accessibilityIdentifier("ticket-time-input-\(slotKey.rawValue)")
            } else {
                Text(currentValue)
                    .font(.system(size: typeScale.heading, weight: .heavy))
                    .foregroundStyle(theme.text)
            }
            HStack(spacing: spacing.sm) {
                FieldButton(
                    label: "Use Current Time",
                    onPress: {
                        currentValue = stampNow()
                        editing = false
                        onUseCurrentTime?(slotKey)
                    },
                    testID: "ticket-time-now-\(slotKey.rawValue)",
                    theme: theme
                )
                FieldButton(
                    label: editing ? "Done" : "Edit Manually",
                    onPress: {
                        editing.toggle()
                        onEditManually?(slotKey)
                    },
                    variant: .secondary,
                    testID: "ticket-time-edit-\(slotKey.rawValue)",
                    theme: theme
                )
            }
        }
    }
}

struct FieldTicketTimesScreen: View {
    var yardArrival: String?
    var timeIn: String?
    var timeOut: String?
    /// Stamp the current time into a slot.
    var onUseCurrentTime: ((TimeSlot) -> Void)?
    var onEditManually: ((TimeSlot) -> Void)?
    var onNext: () -> Void
    var theme: Theme?

    @Environment(\.fieldTheme) private var envTheme

    var body: some View {
        let t = theme ?? envTheme
        let slots: [(key: TimeSlot, label: String, value: String)] = [
            (.yardArrival, "Yard Arrival Time", yardArrival ?? "6:05 AM"),
            (.timeIn, "Time In", timeIn ?? "8:14 AM"),
            (.timeOut, "Time Out", timeOut ?? "\u{2014}"),
        ]

        VStack(alignment: .leading, spacing: spacing.md) {
            Text("Times")
                .font(.system(size: typeScale.title, weight: .heavy))
                .foregroundStyle(t.text)

            ForEach(slots, id: \.key) { slot in
                TimeCard(
                    theme: t,
                    slotKey: slot.key,
                    label: slot.label,
                    value: slot.value,
                    onUseCurrentTime: onUseCurrentTime,
                    onEditManually: onEditManually
                )
            }

            FieldButton(label: "Next: Load / Tank 1", onPress: onNext, testID: "ticket-times-next", theme: t)
        }
        .padding(spacing.lg)
    }
}

// MARK: - 47 & 48. Field Ticket Load / Tank (shared body)

/// A feet/inches gauge value.
struct GaugeReading {
    var feet: String
    var inches: String
}

private let emptyGauge = GaugeReading(feet: "", inches: "")

/// Which half of a gauge reading changed — mirrors the TS `'feet' | 'inches'` string-literal union.
enum GaugePart: String {
    case feet
    case inches
}

private struct LoadTankBody: View {
    var theme: Theme
    /// Kept for parity with the TS prop surface; unused there too (never read in the render).
    var tankLabel: String
    var locationTime: String
    var tank: String
    var beginTotal: GaugeReading
    var beginWater: GaugeReading
    var beginCondensate: GaugeReading
    var endTotal: GaugeReading
    var endWater: GaugeReading
    var endCondensate: GaugeReading
    var waterPulled: GaugeReading
    var barrelsPulled: String
    var onChangeField: ((String, String) -> Void)?
    var onChangeGauge: ((String, GaugePart, String) -> Void)?

    var body: some View {
        Card(title: "Location", theme: theme) {
            Field(
                theme: theme,
                label: "Location Time",
                value: locationTime,
                placeholder: "8:30 AM",
                onChange: { onChangeField?("locationTime", $0) }
            )
            Field(
                theme: theme,
                label: "Tank",
                value: tank,
                placeholder: "Tank 1",
                onChange: { onChangeField?("tank", $0) }
            )
        }

        Card(title: "Beginning Gauge", theme: theme) {
            FeetInchesField(
                theme: theme,
                label: "Total Reading",
                feet: beginTotal.feet,
                inches: beginTotal.inches,
                onChangeFeet: { onChangeGauge?("beginTotal", .feet, $0) },
                onChangeInches: { onChangeGauge?("beginTotal", .inches, $0) },
                testID: "gauge-begin-total"
            )
            FeetInchesField(
                theme: theme,
                label: "Water Reading",
                feet: beginWater.feet,
                inches: beginWater.inches,
                onChangeFeet: { onChangeGauge?("beginWater", .feet, $0) },
                onChangeInches: { onChangeGauge?("beginWater", .inches, $0) },
                testID: "gauge-begin-water"
            )
            FeetInchesField(
                theme: theme,
                label: "Condensate",
                feet: beginCondensate.feet,
                inches: beginCondensate.inches,
                onChangeFeet: { onChangeGauge?("beginCondensate", .feet, $0) },
                onChangeInches: { onChangeGauge?("beginCondensate", .inches, $0) },
                testID: "gauge-begin-cond"
            )
        }

        Card(title: "Ending Gauge", theme: theme) {
            FeetInchesField(
                theme: theme,
                label: "Total Reading",
                feet: endTotal.feet,
                inches: endTotal.inches,
                onChangeFeet: { onChangeGauge?("endTotal", .feet, $0) },
                onChangeInches: { onChangeGauge?("endTotal", .inches, $0) },
                testID: "gauge-end-total"
            )
            FeetInchesField(
                theme: theme,
                label: "Water Reading",
                feet: endWater.feet,
                inches: endWater.inches,
                onChangeFeet: { onChangeGauge?("endWater", .feet, $0) },
                onChangeInches: { onChangeGauge?("endWater", .inches, $0) },
                testID: "gauge-end-water"
            )
            FeetInchesField(
                theme: theme,
                label: "Condensate",
                feet: endCondensate.feet,
                inches: endCondensate.inches,
                onChangeFeet: { onChangeGauge?("endCondensate", .feet, $0) },
                onChangeInches: { onChangeGauge?("endCondensate", .inches, $0) },
                testID: "gauge-end-cond"
            )
        }

        Card(title: "Result", theme: theme) {
            FeetInchesField(
                theme: theme,
                label: "Amount of Water Pulled",
                feet: waterPulled.feet,
                inches: waterPulled.inches,
                onChangeFeet: { onChangeGauge?("waterPulled", .feet, $0) },
                onChangeInches: { onChangeGauge?("waterPulled", .inches, $0) },
                testID: "gauge-water-pulled"
            )
            Field(
                theme: theme,
                label: "Barrels Pulled",
                value: barrelsPulled,
                placeholder: "0",
                keypad: true,
                onChange: { onChangeField?("barrelsPulled", $0) }
            )
        }
    }
}

struct FieldTicketLoadTank1Screen: View {
    var locationTime: String?
    var tank: String?
    var beginTotal: GaugeReading?
    var beginWater: GaugeReading?
    var beginCondensate: GaugeReading?
    var endTotal: GaugeReading?
    var endWater: GaugeReading?
    var endCondensate: GaugeReading?
    var waterPulled: GaugeReading?
    var barrelsPulled: String?
    var onChangeField: ((String, String) -> Void)?
    var onChangeGauge: ((String, GaugePart, String) -> Void)?
    var onNext: () -> Void
    var theme: Theme?

    @Environment(\.fieldTheme) private var envTheme

    var body: some View {
        let t = theme ?? envTheme
        VStack(alignment: .leading, spacing: spacing.md) {
            Text("Load / Tank 1")
                .font(.system(size: typeScale.title, weight: .heavy))
                .foregroundStyle(t.text)

            LoadTankBody(
                theme: t,
                tankLabel: "Tank 1",
                locationTime: locationTime ?? "",
                tank: tank ?? "Tank 1",
                beginTotal: beginTotal ?? emptyGauge,
                beginWater: beginWater ?? emptyGauge,
                beginCondensate: beginCondensate ?? emptyGauge,
                endTotal: endTotal ?? emptyGauge,
                endWater: endWater ?? emptyGauge,
                endCondensate: endCondensate ?? emptyGauge,
                waterPulled: waterPulled ?? emptyGauge,
                barrelsPulled: barrelsPulled ?? "",
                onChangeField: onChangeField,
                onChangeGauge: onChangeGauge
            )

            FieldButton(label: "Next: Load / Tank 2", onPress: onNext, testID: "ticket-tank1-next", theme: t)
        }
        .padding(spacing.lg)
    }
}

struct FieldTicketLoadTank2Screen: View {
    var onToggleNoSecondLoad: ((Bool) -> Void)?
    var locationTime: String?
    var tank: String?
    var beginTotal: GaugeReading?
    var beginWater: GaugeReading?
    var beginCondensate: GaugeReading?
    var endTotal: GaugeReading?
    var endWater: GaugeReading?
    var endCondensate: GaugeReading?
    var waterPulled: GaugeReading?
    var barrelsPulled: String?
    var onChangeField: ((String, String) -> Void)?
    var onChangeGauge: ((String, GaugePart, String) -> Void)?
    var onNext: () -> Void
    var theme: Theme?

    /// When true the driver marked there is no second load — fields collapse.
    @State private var noSecond: Bool

    init(
        noSecondLoad: Bool? = nil,
        onToggleNoSecondLoad: ((Bool) -> Void)? = nil,
        locationTime: String? = nil,
        tank: String? = nil,
        beginTotal: GaugeReading? = nil,
        beginWater: GaugeReading? = nil,
        beginCondensate: GaugeReading? = nil,
        endTotal: GaugeReading? = nil,
        endWater: GaugeReading? = nil,
        endCondensate: GaugeReading? = nil,
        waterPulled: GaugeReading? = nil,
        barrelsPulled: String? = nil,
        onChangeField: ((String, String) -> Void)? = nil,
        onChangeGauge: ((String, GaugePart, String) -> Void)? = nil,
        onNext: @escaping () -> Void,
        theme: Theme? = nil
    ) {
        self.onToggleNoSecondLoad = onToggleNoSecondLoad
        self.locationTime = locationTime
        self.tank = tank
        self.beginTotal = beginTotal
        self.beginWater = beginWater
        self.beginCondensate = beginCondensate
        self.endTotal = endTotal
        self.endWater = endWater
        self.endCondensate = endCondensate
        self.waterPulled = waterPulled
        self.barrelsPulled = barrelsPulled
        self.onChangeField = onChangeField
        self.onChangeGauge = onChangeGauge
        self.onNext = onNext
        self.theme = theme
        _noSecond = State(initialValue: noSecondLoad ?? false)
    }

    @Environment(\.fieldTheme) private var envTheme

    var body: some View {
        let t = theme ?? envTheme
        VStack(alignment: .leading, spacing: spacing.md) {
            Text("Load / Tank 2")
                .font(.system(size: typeScale.title, weight: .heavy))
                .foregroundStyle(t.text)

            Card(title: "Second load", theme: t) {
                HStack(alignment: .center, spacing: spacing.sm) {
                    Text(
                        noSecond
                            ? "Marked as no second load."
                            : "Record a second tank, or mark there isn\u{2019}t one."
                    )
                    .font(.system(size: typeScale.body))
                    .foregroundStyle(t.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if noSecond {
                        StatusBadge(label: "Saved on Phone", tone: .success)
                    }
                }
                FieldButton(
                    label: noSecond ? "Add second load" : "No second load",
                    onPress: {
                        let next = !noSecond
                        noSecond = next
                        onToggleNoSecondLoad?(next)
                    },
                    variant: noSecond ? .secondary : .destructive,
                    testID: "ticket-tank2-toggle",
                    theme: t
                )
            }

            if !noSecond {
                LoadTankBody(
                    theme: t,
                    tankLabel: "Tank 2",
                    locationTime: locationTime ?? "",
                    tank: tank ?? "Tank 2",
                    beginTotal: beginTotal ?? emptyGauge,
                    beginWater: beginWater ?? emptyGauge,
                    beginCondensate: beginCondensate ?? emptyGauge,
                    endTotal: endTotal ?? emptyGauge,
                    endWater: endWater ?? emptyGauge,
                    endCondensate: endCondensate ?? emptyGauge,
                    waterPulled: waterPulled ?? emptyGauge,
                    barrelsPulled: barrelsPulled ?? "",
                    onChangeField: onChangeField,
                    onChangeGauge: onChangeGauge
                )
            }

            FieldButton(
                label: "Next: Barrels and Line Items",
                onPress: onNext,
                testID: "ticket-tank2-next",
                theme: t
            )
        }
        .padding(spacing.lg)
    }
}

// MARK: - 49. Field Ticket Barrels and Line Items

/// A single billing line item. Rate/total are optional — hidden from drivers when sensitive.
struct LineItem {
    var key: String
    var description: String
    var quantity: String
    var rate: String?
    var total: String?
}

struct FieldTicketLineItemsScreen: View {
    var totalBarrelsPulled: String?
    var lineItems: [LineItem]?
    /// When false, Rate/Total columns are hidden (OpsHub calculates billing).
    var showRates: Bool?
    var grandTotal: String?
    var onNext: () -> Void
    var theme: Theme?

    @Environment(\.fieldTheme) private var envTheme

    var body: some View {
        let t = theme ?? envTheme
        let showRatesResolved = showRates ?? false
        let items =
            lineItems ?? [
                LineItem(
                    key: "l1", description: "Saltwater disposal", quantity: "120 bbl", rate: "$2.10", total: "$252.00"),
                LineItem(key: "l2", description: "Standby time", quantity: "0.5 hr", rate: "$95.00", total: "$47.50"),
            ]

        VStack(alignment: .leading, spacing: spacing.md) {
            Text("Barrels and Line Items")
                .font(.system(size: typeScale.title, weight: .heavy))
                .foregroundStyle(t.text)

            Card(title: "Total Barrels Pulled", tone: .highlight, theme: t) {
                Text(totalBarrelsPulled ?? "120 bbl")
                    .font(.system(size: typeScale.title, weight: .heavy))
                    .foregroundStyle(t.text)
            }

            Card(title: "Line items", theme: t) {
                HStack(spacing: spacing.sm) {
                    Text("Description")
                        .font(.system(size: typeScale.caption, weight: .bold))
                        .foregroundStyle(t.textMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("Qty")
                        .font(.system(size: typeScale.caption, weight: .bold))
                        .foregroundStyle(t.textMuted)
                        .frame(width: 64, alignment: .trailing)
                    if showRatesResolved {
                        Text("Rate")
                            .font(.system(size: typeScale.caption, weight: .bold))
                            .foregroundStyle(t.textMuted)
                            .frame(width: 64, alignment: .trailing)
                        Text("Total")
                            .font(.system(size: typeScale.caption, weight: .bold))
                            .foregroundStyle(t.textMuted)
                            .frame(width: 64, alignment: .trailing)
                    }
                }

                ForEach(items, id: \.key) { item in
                    HStack(spacing: spacing.sm) {
                        Text(item.description)
                            .font(.system(size: typeScale.label))
                            .foregroundStyle(t.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(item.quantity)
                            .font(.system(size: typeScale.label))
                            .foregroundStyle(t.text)
                            .frame(width: 64, alignment: .trailing)
                        if showRatesResolved {
                            Text(item.rate ?? "\u{2014}")
                                .font(.system(size: typeScale.label))
                                .foregroundStyle(t.text)
                                .frame(width: 64, alignment: .trailing)
                            Text(item.total ?? "\u{2014}")
                                .font(.system(size: typeScale.label))
                                .foregroundStyle(t.text)
                                .frame(width: 64, alignment: .trailing)
                        }
                    }
                    .accessibilityIdentifier("line-item-\(item.key)")
                }

                if showRatesResolved {
                    HStack {
                        Text("Grand Total")
                            .font(.system(size: typeScale.body, weight: .heavy))
                            .foregroundStyle(t.text)
                        Spacer()
                        Text(grandTotal ?? "$299.50")
                            .font(.system(size: typeScale.heading, weight: .heavy))
                            .foregroundStyle(t.text)
                    }
                } else {
                    Text("Billing rates are calculated by Ops Hub after you submit.")
                        .font(.system(size: typeScale.label))
                        .foregroundStyle(t.textMuted)
                }
            }

            FieldButton(
                label: "Next: Evidence and Signature",
                onPress: onNext,
                testID: "ticket-lineitems-next",
                theme: t
            )
        }
        .padding(spacing.lg)
    }
}

// MARK: - 50. Field Ticket Evidence and Signature

struct EvidenceItem {
    var key: String
    var label: String
    var required: Bool
    var state: EvidenceState
}

private func isSignatureKey(_ key: String) -> Bool {
    key.contains("signature")
}

/// One evidence row that manages its own captured state and shows inline feedback on tap.
private struct EvidenceCard: View {
    var theme: Theme
    var item: EvidenceItem
    var onCapture: ((String) -> Void)?

    @State private var state: EvidenceState
    @State private var justCaptured = false

    init(theme: Theme, item: EvidenceItem, onCapture: ((String) -> Void)? = nil) {
        self.theme = theme
        self.item = item
        self.onCapture = onCapture
        _state = State(initialValue: item.state)
    }

    private var done: Bool { state != .notStarted }
    private var isSig: Bool { isSignatureKey(item.key) }
    private var isGps: Bool { item.key == "gps-event" }
    private var captionVerb: String { isSig ? "Sign" : isGps ? "Stamp" : "Photo" }
    private var confirmText: String {
        isSig ? "Signature captured" : isGps ? "GPS stamped" : "Photo added \u{2014} saved on this phone"
    }

    private func capture() {
        state = .captured
        justCaptured = true
        onCapture?(item.key)
    }

    var body: some View {
        Card(title: item.label, testID: "evidence-\(item.key)", theme: theme) {
            HStack(alignment: .center, spacing: spacing.sm) {
                StatusBadge(label: item.required ? "Required" : "Optional", tone: item.required ? .warning : .neutral)
                StatusBadge(label: state.rawValue, tone: evidenceTone[state] ?? .neutral)
            }
            CaptureFrame(
                theme: theme,
                caption: done
                    ? "\(captionVerb) captured \u{2014} tap below to retake."
                    : "No \(item.label.lowercased()) yet."
            )
            HStack(spacing: spacing.sm) {
                FieldButton(
                    label: done ? "Retake" : isSig ? "Sign" : isGps ? "Capture GPS" : "Take Photo",
                    onPress: capture,
                    testID: "evidence-capture-\(item.key)",
                    theme: theme
                )
                if done {
                    FieldButton(
                        label: "Use Photo",
                        onPress: {
                            justCaptured = true
                            onCapture?(item.key)
                        },
                        variant: .secondary,
                        testID: "evidence-use-\(item.key)",
                        theme: theme
                    )
                }
            }
            if justCaptured {
                FeedbackLine(theme: theme, text: confirmText, testID: "evidence-feedback-\(item.key)")
            }
        }
    }
}

struct FieldTicketEvidenceScreen: View {
    var items: [EvidenceItem]?
    var onCapture: ((String) -> Void)?
    var onReview: () -> Void
    var theme: Theme?

    @Environment(\.fieldTheme) private var envTheme

    var body: some View {
        let t = theme ?? envTheme
        let resolvedItems =
            items ?? [
                EvidenceItem(key: "ticket-photo", label: "Ticket Photo", required: true, state: .captured),
                EvidenceItem(key: "disposal-photo", label: "Disposal Photo", required: true, state: .captured),
                EvidenceItem(key: "receipt-photo", label: "Receipt Photo", required: false, state: .notStarted),
                EvidenceItem(key: "customer-signature", label: "Customer Signature", required: true, state: .captured),
                EvidenceItem(key: "driver-signature", label: "Driver Signature", required: true, state: .notStarted),
                EvidenceItem(key: "gps-event", label: "GPS Event", required: true, state: .synced),
            ]

        VStack(alignment: .leading, spacing: spacing.md) {
            Text("Evidence and Signature")
                .font(.system(size: typeScale.title, weight: .heavy))
                .foregroundStyle(t.text)
            Text("Capture each required item. Anything you capture is saved on this phone right away.")
                .font(.system(size: typeScale.label))
                .foregroundStyle(t.textMuted)

            ForEach(resolvedItems, id: \.key) { item in
                EvidenceCard(theme: t, item: item, onCapture: onCapture)
            }

            FieldButton(label: "Review Ticket", onPress: onReview, testID: "ticket-evidence-next", theme: t)
        }
        .padding(spacing.lg)
    }
}

// MARK: - 51. Field Ticket Review

struct FieldTicketReviewScreen: View {
    var ticketNo: String?
    var srNumber: String?
    var customer: String?
    var lease: String?
    var well: String?
    var timeIn: String?
    var timeOut: String?
    var barrelsPulled: String?
    var photosAttached: Int?
    var signatureCaptured: Bool?
    var submitting: Bool?
    var onSubmit: () -> Void
    var theme: Theme?

    @Environment(\.fieldTheme) private var envTheme
    @State private var confirming = false

    var body: some View {
        let t = theme ?? envTheme
        let ticketNoResolved = ticketNo ?? "TKT-10488"
        let sr = srNumber ?? "SR 2026-000001"
        let photos = photosAttached ?? 2
        let signed = signatureCaptured ?? true
        let submittingResolved = submitting ?? false

        VStack(alignment: .leading, spacing: spacing.md) {
            Text("Review")
                .font(.system(size: typeScale.title, weight: .heavy))
                .foregroundStyle(t.text)

            Card(title: "Review Field Ticket", testID: "ticket-review-card", theme: t) {
                SummaryRow(theme: t, label: "Ticket No.", value: ticketNoResolved)
                SummaryRow(theme: t, label: "Customer", value: customer ?? "Acme Energy")
                SummaryRow(theme: t, label: "Lease", value: lease ?? "Northfield Lease")
                SummaryRow(theme: t, label: "Well", value: well ?? "Northfield 06H")
                SummaryRow(theme: t, label: "Time In", value: timeIn ?? "8:14 AM")
                SummaryRow(theme: t, label: "Time Out", value: timeOut ?? "10:42 AM")
                SummaryRow(theme: t, label: "Barrels Pulled", value: barrelsPulled ?? "120 bbl")
                SummaryRow(theme: t, label: "Photos", value: "\(photos) attached")
                SummaryRow(
                    theme: t,
                    label: "Signature",
                    value: signed ? "Customer signature captured" : "Not captured"
                )
            }

            FieldButton(
                label: submittingResolved ? "Submitting\u{2026}" : "Submit Field Ticket",
                onPress: { confirming = true },
                disabled: submittingResolved,
                testID: "ticket-review-submit",
                theme: t
            )

            if confirming {
                ConfirmOverlay(
                    theme: t,
                    title: "Submit field ticket?",
                    bodyText: "This will submit \(ticketNoResolved) for \(sr).",
                    cancelLabel: "Cancel",
                    confirmLabel: "Submit Ticket",
                    onCancel: { confirming = false },
                    onConfirm: {
                        confirming = false
                        onSubmit()
                    }
                ) {
                    Text("If offline, it will be saved on this phone and synced later.")
                        .font(.system(size: typeScale.label))
                        .foregroundStyle(t.textMuted)
                }
            }
        }
        .padding(spacing.lg)
    }
}

// MARK: - 52. Field Ticket Submitted

/// Sync state of the just-submitted ticket. Anonymous inline union in the TS source
/// (`'Saved on Phone' | 'Pending Sync' | 'Syncing' | 'Synced' | 'Submitted'`); named here since
/// Swift enums need a declared type.
enum FieldTicketSubmittedState: String {
    case savedOnPhone = "Saved on Phone"
    case pendingSync = "Pending Sync"
    case syncing = "Syncing"
    case synced = "Synced"
    case submitted = "Submitted"
}

struct FieldTicketSubmittedScreen: View {
    var ticketNo: String?
    var barrelsPulled: String?
    var state: FieldTicketSubmittedState?
    var onReviewJob: () -> Void
    var onPrint: (() -> Void)?
    var onStartNextJob: (() -> Void)?
    var theme: Theme?

    @Environment(\.fieldTheme) private var envTheme
    @State private var printed = false

    var body: some View {
        let t = theme ?? envTheme
        let resolvedState = state ?? .savedOnPhone
        let stateTone: Tone =
            (resolvedState == .synced || resolvedState == .submitted)
            ? .success
            : (resolvedState == .savedOnPhone ? .info : .warning)

        VStack(alignment: .leading, spacing: spacing.md) {
            Text("Field Ticket Submitted")
                .font(.system(size: typeScale.title, weight: .heavy))
                .foregroundStyle(t.text)

            Card(title: ticketNo ?? "TKT-10488", tone: .highlight, testID: "ticket-submitted-card", theme: t) {
                Text(barrelsPulled ?? "120 bbl")
                    .font(.system(size: typeScale.title, weight: .heavy))
                    .foregroundStyle(t.text)
                StatusBadge(label: resolvedState.rawValue, tone: stateTone)
                Text(
                    "Your ticket is safe on this phone. It will sync to Ops Hub automatically when you have a connection."
                )
                .font(.system(size: typeScale.body))
                .foregroundStyle(t.text)
            }

            FieldButton(label: "Review Job", onPress: onReviewJob, testID: "ticket-submitted-review", theme: t)

            HStack(spacing: spacing.sm) {
                FieldButton(
                    label: "Print Ticket",
                    onPress: {
                        printed = true
                        onPrint?()
                    },
                    variant: .secondary,
                    testID: "ticket-submitted-print",
                    theme: t
                )
                FieldButton(
                    label: "Start Next Job",
                    onPress: { onStartNextJob?() },
                    variant: .secondary,
                    testID: "ticket-submitted-next",
                    theme: t
                )
            }

            if printed {
                FeedbackLine(theme: t, text: "Sent to printer", testID: "ticket-submitted-print-feedback")
            }
        }
        .padding(spacing.lg)
    }
}
