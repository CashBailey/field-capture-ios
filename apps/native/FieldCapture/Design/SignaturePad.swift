//
//  SignaturePad.swift
//  Ported from apps/mobile/src/design/SignaturePad.tsx
//
//  SignatureField — the one finger-drawable signature surface, reused by Pre-Trip, Post-Trip, JHA,
//  and Evidence. Tapping the inline pad opens a full-screen LANDSCAPE modal (rotated 90° via a
//  transform rather than a native orientation lock, mirroring the RN source) with a real drag-gesture
//  canvas: the driver signs with their finger, edge to edge, then Done / Clear / Cancel.
//
//  Ink is the dense dot-cloud from `inkDots`; the captured signature is the serialized vector from
//  `serializeSignature`, which the host persists as the artifact.
//

import SwiftUI

/// The captured signature: the serialized vector, or nil when unsigned.
typealias SignatureValue = String

/// Renders a stroke set as a dot cloud, optionally scaled to fit the view's bounds (for previews).
private struct Ink: View {
    var strokes: [SigStroke]
    var color: Color
    var dotSize: CGFloat = 2.6
    var fit: Bool = false

    var body: some View {
        GeometryReader { geo in
            let dots = inkDots(strokes)
            let t = fitTransform(dots: dots, box: geo.size)

            ForEach(Array(dots.enumerated()), id: \.offset) { _, d in
                Circle()
                    .fill(color)
                    .frame(width: dotSize, height: dotSize)
                    .position(x: CGFloat(d.x) * t.scale + t.ox, y: CGFloat(d.y) * t.scale + t.oy)
            }
        }
        .allowsHitTesting(false)
    }

    /// Plain (non-ViewBuilder) helper: SwiftUI's `@ViewBuilder` closures can't host bare
    /// assignment/if statements that don't themselves resolve to a `View`, so the fit-scaling math
    /// lives here instead of inline in `body`.
    private func fitTransform(dots: [SigPoint], box: CGSize) -> (scale: CGFloat, ox: CGFloat, oy: CGFloat) {
        guard fit, !dots.isEmpty, box.width > 0, box.height > 0 else { return (1, 0, 0) }
        let xs = dots.map(\.x)
        let ys = dots.map(\.y)
        let minX = xs.min() ?? 0
        let minY = ys.min() ?? 0
        let w = max(1, (xs.max() ?? 0) - minX)
        let h = max(1, (ys.max() ?? 0) - minY)
        let pad: CGFloat = 8
        let scale = min((box.width - pad * 2) / CGFloat(w), (box.height - pad * 2) / CGFloat(h), 1)
        return (scale, pad - CGFloat(minX) * scale, pad - CGFloat(minY) * scale)
    }
}

/// Full-screen landscape drawing surface. Owns the in-progress strokes; reports them on Done.
private struct SignatureModal: View {
    var theme: Theme
    var initial: [SigStroke]
    var onDone: ([SigStroke]) -> Void
    var onCancel: () -> Void
    var testID: String?

    @State private var strokes: [SigStroke]
    @State private var isStrokeActive = false

    init(
        theme: Theme, initial: [SigStroke], onDone: @escaping ([SigStroke]) -> Void, onCancel: @escaping () -> Void,
        testID: String?
    ) {
        self.theme = theme
        self.initial = initial
        self.onDone = onDone
        self.onCancel = onCancel
        self.testID = testID
        _strokes = State(initialValue: initial.map { $0 })
    }

    var body: some View {
        let t = theme
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height

            ZStack {
                t.background.ignoresSafeArea()

                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: spacing.xs) {
                        Text("Sign below")
                            .font(.system(size: typeScale.heading, weight: .heavy))
                            .foregroundStyle(t.text)
                        Text("Turn the phone sideways and sign with your finger.")
                            .font(.system(size: typeScale.label))
                            .foregroundStyle(t.textMuted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, spacing.lg)
                    .padding(.top, spacing.md)

                    GeometryReader { canvas in
                        ZStack {
                            Ink(strokes: strokes, color: t.text)
                            // Baseline guide, same position as the RN `styles.baseline` (28% up from
                            // the bottom, inset by `spacing.xl` on each side).
                            Rectangle()
                                .fill(Color(hex: "#9AA7A0").opacity(0.5))
                                .frame(height: 1)
                                .padding(.horizontal, spacing.xl)
                                .position(x: canvas.size.width / 2, y: canvas.size.height * 0.72)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(t.card)
                    .overlay(RoundedRectangle(cornerRadius: sizing.radius).stroke(t.border, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: sizing.radius))
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let point = SigPoint(x: Double(value.location.x), y: Double(value.location.y))
                                if isStrokeActive {
                                    strokes[strokes.count - 1].append(point)
                                } else {
                                    isStrokeActive = true
                                    strokes.append([point])
                                }
                            }
                            .onEnded { _ in isStrokeActive = false }
                    )
                    .accessibilityIdentifier(ifPresent: testID.map { "\($0)-canvas" })
                    .padding(spacing.lg)

                    HStack(spacing: spacing.sm) {
                        Spacer()
                        FieldButton(
                            label: "Cancel",
                            onPress: onCancel,
                            variant: .secondary,
                            fullWidth: false,
                            testID: testID.map { "\($0)-cancel" }
                        )
                        FieldButton(
                            label: "Clear",
                            onPress: { strokes = [] },
                            variant: .secondary,
                            fullWidth: false,
                            testID: testID.map { "\($0)-clear" }
                        )
                        FieldButton(
                            label: "Done",
                            onPress: { onDone(strokes) },
                            fullWidth: false,
                            disabled: isEmpty(strokes),
                            testID: testID.map { "\($0)-done" }
                        )
                    }
                    .padding(.horizontal, spacing.lg)
                    .padding(.bottom, spacing.lg)
                }
                .frame(width: height, height: width)
                .rotationEffect(.degrees(90))
                .position(x: width / 2, y: height / 2)
            }
        }
        .ignoresSafeArea()
        .accessibilityIdentifier(ifPresent: testID)
    }
}

/// Inline signature field: a preview box + Sign / Clear, opening the landscape modal. `value` is the
/// serialized signature (or nil); `onChange(nil)` clears it.
struct SignatureField: View {
    var theme: Theme?
    var value: SignatureValue?
    var onChange: (SignatureValue?) -> Void
    var testID: String = "signature"

    @Environment(\.fieldTheme) private var envTheme
    @State private var isOpen = false

    var body: some View {
        let t = theme ?? envTheme
        let strokes = value.map(deserializeSignature) ?? []
        let captured = !isEmpty(strokes)

        VStack(alignment: .leading, spacing: spacing.sm) {
            Button {
                isOpen = true
            } label: {
                ZStack {
                    if captured {
                        Ink(strokes: strokes, color: t.text, fit: true)
                    } else {
                        Text("Tap to sign")
                            .font(.system(size: typeScale.body, weight: .semibold))
                            .foregroundStyle(t.textMuted)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: 140)
                .background(t.cardMuted)
                .overlay(
                    RoundedRectangle(cornerRadius: sizing.radius)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .foregroundStyle(captured ? t.primary : t.border)
                )
                .clipShape(RoundedRectangle(cornerRadius: sizing.radius))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(captured ? "Signature captured — tap to re-sign" : "Tap to sign")
            .accessibilityIdentifier("\(testID)-pad")

            HStack(spacing: spacing.sm) {
                FieldButton(
                    label: captured ? "Re-sign" : "Sign",
                    onPress: { isOpen = true },
                    variant: .secondary,
                    fullWidth: false,
                    testID: "\(testID)-capture"
                )
                FieldButton(
                    label: "Clear",
                    onPress: { onChange(nil) },
                    variant: .secondary,
                    fullWidth: false,
                    disabled: !captured,
                    testID: "\(testID)-clear"
                )
            }
        }
        .fullScreenCover(isPresented: $isOpen) {
            SignatureModal(
                theme: t,
                initial: strokes,
                onDone: { next in
                    isOpen = false
                    onChange(isEmpty(next) ? nil : serializeSignature(next))
                },
                onCancel: { isOpen = false },
                testID: "\(testID)-modal"
            )
        }
    }
}
