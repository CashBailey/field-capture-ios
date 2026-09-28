import SwiftUI

@main
struct FieldCaptureApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

// Port of App.tsx's top-level `export default function App()` — mounts the theme provider once at
// the root, then the boot machine (AppRoot, in AppShell.swift). ScreenGallery.swift is left in
// place (a user-added debug gallery) but is no longer the mounted root.
struct RootView: View {
    var body: some View {
        Group {
            #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-ScreenGallery")
                    || UserDefaults.standard.string(forKey: "GalleryScreen") != nil
                {
                    ScreenGalleryView()
                } else {
                    AppRoot()
                }
            #else
                AppRoot()
            #endif
        }
        .fieldThemeProvider()
    }
}
