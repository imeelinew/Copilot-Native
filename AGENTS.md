# Copilot Native

Copilot Native is a native macOS interview assistant built with Swift 6, SwiftUI, SwiftData, and AppKit where native macOS behavior is needed.

## Core mental model

- `Package` is the top-level library container and appears as a parent item in the sidebar.
- `Capsule` belongs to exactly one Package and appears as that Package's expandable child item.
- Every question-and-answer record belongs to exactly one Capsule.
- Preserve the Package → Capsule → question hierarchy across persistence, search scoping, editing, and import/export.
- Package and Capsule names are user-defined and editable.

## Project constraints

- Do not modify Xcode scheme settings or files under `Copilot Native.xcodeproj/xcshareddata/xcschemes`.
- Do not add, generate, modify, or run test code. Verify changes with Debug builds and focused manual checks.
- Prefer native SwiftUI and macOS controls. Use AppKit only where it provides necessary native behavior.
- Keep the app local-first. API keys belong in Keychain and library data belongs in SwiftData.

## Build verification

For application changes, run:

```sh
xcodebuild -project 'Copilot Native.xcodeproj' -scheme 'Copilot Native' -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```
