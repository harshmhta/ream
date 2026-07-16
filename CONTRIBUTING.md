# Contributing to Ream

Thanks for helping build a genuinely free, genuinely native PDF app for macOS.
This guide covers getting set up, house style, and what a good PR looks like.

## Getting set up

**Requirements:** macOS 14 (Sonoma)+, Xcode 15+.

```bash
git clone https://github.com/harshmhta/ream.git
cd ream
./scripts/bootstrap.sh   # installs XcodeGen (via Homebrew) if needed, generates Ream.xcodeproj
open Ream.xcodeproj
```

Press **⌘R** to run, **⌘U** to test.

### Why there's no `.xcodeproj` in git

The project is generated from [`project.yml`](project.yml) using
[XcodeGen](https://github.com/yonaskolb/XcodeGen). The generated
`Ream.xcodeproj` is `.gitignore`d so contributors never fight over its opaque
internal state. **If you need to add a file, target, build setting, or
dependency, edit `project.yml` and re-run `xcodegen generate`** (or
`./scripts/bootstrap.sh`) — don't hand-edit the project in Xcode expecting it to
persist.

## Project layout

```
Ream/            App target (SwiftUI + AppKit interop)
  App/           @main entry, AppDelegate, menu commands
  Documents/     PDF document model (ReferenceFileDocument)
  Views/         SwiftUI views + the PDFKit NSViewRepresentable
  ViewModels/    View-facing derived state
  Services/      PDFKit coordination, file IO, command palette
  Resources/     Info.plist, entitlements, Assets.xcassets
ReamCore/        Portable, UI-free Swift package (CLI + future editing engine)
ReamTests/       Unit tests (+ Fixtures/ sample PDFs)
ReamUITests/     UI smoke tests
scripts/         bootstrap.sh, test.sh
docs/            ARCHITECTURE.md and friends
```

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for how the pieces fit and
where new features plug in.

## Coding style

- Follow the [Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/).
- SwiftUI-first; drop to AppKit (via `NSViewRepresentable`) only where the
  framework demands it — as we do for `PDFView`.
- Keep **`ReamCore` free of any UI framework import** (no AppKit / SwiftUI /
  PDFKit-UI). It must stay portable and headless-testable.
- Prefer small, documented types. Public seams (protocols, services) deserve a
  doc comment explaining what downstream code should build against.
- SwiftLint / SwiftFormat are **optional for v0.1** — a `.swiftlint.yml` with
  sensible defaults is included. If you have SwiftLint installed, please run it;
  CI does not yet enforce it.

## Guardrails (from the product principles)

These are non-negotiable and a PR that violates them will be rejected:

- **No cloud, no accounts, no telemetry, no analytics, no auto-uploads.** Ever.
- **Fidelity is sacred.** A no-op open→save must be byte-stable for untouched
  content. Any editing feature needs a round-trip / snapshot test.
- **BYO AI keys only** — never bundle or proxy managed API keys.

## Running tests

```bash
./scripts/test.sh                                   # generate + build + all tests
# or, from Xcode: ⌘U
# or, unit tests only (what CI runs):
xcodebuild -scheme Ream -destination "platform=macOS" -only-testing:ReamTests test
```

> **Note on UI tests:** `ReamUITests` require a code-signing identity to inject
> their test bundle into the app, so they run locally (Xcode signs with your
> Apple Development identity automatically) but are **excluded from CI**, which
> builds ad-hoc on an unsigned runner. Keep behavioral coverage in `ReamTests`
> where possible.

## PR checklist

Before opening a pull request:

- [ ] `./scripts/test.sh` passes locally (build + tests green).
- [ ] New files are added via `project.yml`, and `xcodegen generate` was re-run.
- [ ] `ReamCore` still compiles without importing any UI framework.
- [ ] New public seams have doc comments.
- [ ] No cloud / telemetry / account / bundled-AI-key code was introduced.
- [ ] Editing/serialization changes include a fidelity (round-trip) test.
- [ ] PR description says **what shipped** and **what's stubbed**.
