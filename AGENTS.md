# Copilot Native

Copilot Native is a native macOS interview assistant built with Swift 6, SwiftUI, SwiftData, and AppKit where native macOS behavior is needed.

## Core mental model

- `Package` is the top-level library container and appears as a parent item in the sidebar.
- `Capsule` belongs to exactly one Package and appears as that Package's expandable child item.
- `Stuff` is one complete question-and-answer record and belongs to exactly one Capsule.
- Preserve the Package → Capsule → Stuff hierarchy across persistence, search scoping, editing, moving, and import/export.
- Moving a Stuff uses a Package-grouped Capsule picker; the selected Capsule remains the Stuff's direct parent.
- Package and Capsule names are user-defined and editable.

## Project constraints

- If a user instruction conflicts with this file, stop and ask the user how to proceed. Do not resolve the conflict independently.
- Do not use visual inspection, screenshots, Computer Use, or other visual viewing tools. They are slow and not useful for this project.
- Only use builds to check for compilation errors. Do not launch the app yourself because it can interfere with an instance launched by the user.
- Do not modify Xcode scheme settings or files under `Copilot Native.xcodeproj/xcshareddata/xcschemes`.
- Do not add, generate, modify, or run test code. Verify changes with Debug builds and static inspection.
- Prefer native SwiftUI and macOS controls. Use AppKit only where it provides necessary native behavior.
- Keep the app local-first. API keys belong in Keychain and library data belongs in SwiftData.

## Build verification

For application changes, run:

```sh
xcodebuild -project 'Copilot Native.xcodeproj' -scheme 'Copilot Native' -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```
