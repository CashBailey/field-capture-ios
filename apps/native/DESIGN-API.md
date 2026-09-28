# FieldCapture/Design — Swift API for screen ports

All in the app target (no import needed within FieldCapture target files).
Source parity: `apps/mobile/src/design`. Mount `.fieldThemeProvider()` once at root (done by shell).

```swift
// Tokens
palette.brandGreen/.forestGreen/.brandGreenBright/.skyBlue/.infoBlue/.saddleBrown/.safetyAmber/
        .errorRed/.cream/.fieldSand/.ink/.inkMuted/.warmGray/.surface/.surfaceMuted/.border/
        .onColor/.successText/.charcoal/.charcoalCard/.darkBorder/.lightText   // Color
typeScale.title/.heading/.body/.label/.caption   // semantic, Dynamic Type-aware font-size tokens
spacing.xs/.sm/.md/.lg/.xl                       // CGFloat
sizing.actionButtonHeight/.minTouchTarget/.radius/.cardRadius/.pillRadius
struct Theme { mode; background, card, cardMuted, primary, primaryDark, onPrimary, text,
               textMuted, border, info, success, warning, danger, highlight: Color }
let lightTheme: Theme, darkTheme: Theme, theme: Theme
enum Tone: String { neutral, info, success, warning, danger }
let toneColor: [Tone: Color]

// Theme access in a View:
@Environment(\.fieldTheme) private var t

// Components
Card(title: String? = nil, tone: Card.Tone = .default, testID: String? = nil,
     theme: Theme? = nil) { ...content }        // also EmptyView overload
FieldButton(label:onPress:variant:fullWidth:disabled:testID:theme:)  // variant: .primary/.secondary/.destructive
StatusBadge(label:tone:testID:)
AppHeader(title:subtitle:chips:theme:)          // HeaderChip {label, tone}
Logo(size:ring:testID:)                         // real brand PNG
SignatureField(theme:value:onChange:testID:)    // typealias SignatureValue = String (serialized strokes)
// helper:
.accessibilityIdentifier(ifPresent: testID)     // on any View
```

## Screen-port conventions

- Target: one Swift file per TS screens file, `FieldCapture/Screens/<SameBaseName>.swift`
  (e.g. `JobScreens.tsx` → `Screens/JobScreens.swift`). Filesystem-synced — just create the file.
- Every exported TS screen component → a `struct <Name>: View`. Props → `let`/closure properties
  with the SAME names; optional props → optionals with the same defaulting. Callbacks
  (`onPress`, `onOpenJob(record)`) → closures.
- Local state (`useState`) → `@State`. Keep the same state machine and initial values.
- `testID="x"` → `.accessibilityIdentifier("x")`. `accessibilityRole="button"` on Pressable →
  Button or `.onTapGesture` + `.accessibilityAddTraits(.isButton)`.
- Keep EVERY user-facing string byte-identical (labels, messages, placeholders, empty states).
  Keep list/menu order identical.
- RN layout → SwiftUI: View w/ gap → VStack(spacing:), flexDirection row → HStack,
  ScrollView stays ScrollView, TextInput → TextField/SecureField (styled like the RN input:
  1px theme.border border, radius 8, padding 12, theme.card background), Pressable chips →
  the same pill styling (borderRadius 16, primary fill when selected).
- Exported pure helpers/types in a screens file (e.g. `buildWorkdayTimeline`, `SopFilter`,
  `evidenceRouteForMenuKey`, type unions) MUST also be ported (enum/struct/func, same names).
- TS string-literal unions → Swift enums with rawValue matching the literal exactly.
- `fieldwork.X` constants from `@fieldcapture/contracts` → `import FieldContracts`, same name X.
- Do NOT run xcodebuild (other files land concurrently). Syntax-check only:
  `xcrun swiftc -parse <yourfile> 2>&1 | head` — type errors about Design/FieldContracts
  symbols are EXPECTED and fine; fix only real syntax errors.
- Never modify files outside your assigned Screens/<file>.swift.
