//
//  Logo.swift
//  Ported from apps/mobile/src/design/Logo.tsx
//
//  Field Capture brand logo — the Acme Oilfield Services circular badge, clipped to a
//  circle. Used in the header, splash, and sign-in. Same raster artwork as the RN app
//  (assets/fieldLogo.png → Assets.xcassets/FieldLogo).
//

import SwiftUI

struct Logo: View {
    var size: CGFloat = 36
    var ring: Bool = false
    var testID: String?

    var body: some View {
        Image("FieldLogo")
            .resizable()
            .scaledToFill()
            .frame(width: size, height: size)
            .background(palette.surface)
            .clipShape(Circle())
            .overlay(
                Circle().strokeBorder(palette.skyBlue, lineWidth: ring ? 2 : 0)
            )
            .accessibilityLabel("Field Capture")
            .accessibilityIdentifier(ifPresent: testID)
    }
}

#Preview {
    HStack(spacing: 12) {
        Logo(size: 36)
        Logo(size: 48, ring: true)
    }
    .padding()
}
