# Ream Architecture

This document maps the modules that make up Ream, what each is responsible for,
and — most importantly for contributors — **the seams that future features plug
into**. It reflects the v0.1 foundation; each phase in the
[roadmap](../README.md#roadmap) extends these seams rather than replacing them.

## High-level shape

```
┌──────────────────────────────────────────────────────────────┐
│  Ream (app target)  —  SwiftUI + AppKit interop                │
│                                                                │
│   App/         ReamApp (@main, DocumentGroup) · AppDelegate    │
│                ReamCommands (menu bar) · FocusedValues         │
│   Documents/   PDFReferenceDocument  (ReferenceFileDocument)   │
│   Views/       PDFDocumentView · PDFKitView (NSViewRep.)       │
│                CommandPaletteView                              │
│   ViewModels/  DocumentViewModel                               │
│   Services/    PDFViewCoordinator · RecentDocumentStore        │
│                CommandPaletteService  (⌘K registry)            │
│   Resources/   Info.plist · Ream.entitlements · Assets         │
└───────────────────────────┬────────────────────────────────────┘
                            │  depends on
                            ▼
┌──────────────────────────────────────────────────────────────┐
│  ReamCore (Swift package)  —  UI-free, portable                │
│    ReamCore (namespace/version) · PDFDescriptor (model seam)   │
│    → seam for the CLI (`pdfx`) and the v1.0 editing engine     │
└──────────────────────────────────────────────────────────────┘
```

## Modules

### `Ream` — the app target

A **document-based SwiftUI app**. The app-level building blocks:

| File | Responsibility |
|------|----------------|
| `App/ReamApp.swift` | `@main`. Declares a `DocumentGroup(viewing:)` bound to `PDFReferenceDocument` — this gives tabs, multiple windows, Finder open, drag-onto-dock, and Autosave/Versions for free. Installs `ReamCommands`. |
| `App/AppDelegate.swift` | Lifecycle hooks SwiftUI doesn't expose: suppresses the blank untitled window (Ream is a viewer) and reopens the last document on relaunch if the system didn't restore windows. |
| `App/ReamCommands.swift` | Menu-bar `Commands`: the ⌘K palette toggle and the View-menu zoom items (⌘+, ⌘−, ⌘0, ⌘1, ⌘2). Zoom commands target the **focused** window's coordinator via `@FocusedValue`. |
| `App/FocusedValues.swift` | The `@FocusedValue` key that exposes the key window's `PDFViewCoordinator` to the app-level menu commands. |
| `Documents/PDFReferenceDocument.swift` | The document model. Uses `ReferenceFileDocument` (reference type) because `PDFKit.PDFDocument` is a class and Phase 2 features (annotations, page ops) mutate it in place. `snapshot(contentType:)` is the byte-stable no-op save seam. |
| `Views/PDFKitView.swift` | `NSViewRepresentable` wrapping AppKit's `PDFView` — the Metal-backed renderer. Configures continuous vertical scroll and hands the view to the coordinator. |
| `Views/PDFDocumentView.swift` | Per-window root view: composes the renderer with the ⌘K palette overlay and publishes the window's coordinator into the environment. |
| `Views/CommandPaletteView.swift` | The ⌘K overlay UI (search field + results list) bound to `CommandPaletteService`. Empty until features register commands. |
| `ViewModels/DocumentViewModel.swift` | View-facing derived state (page count, display title). Thin today; Phase 2 sidebars/search/annotation-list view models sit alongside it. |
| `Services/PDFViewCoordinator.swift` | The one place that talks to `PDFView` for zoom/fit. Menus, the future toolbar, and palette commands all drive the view through its small `PDFViewAction` vocabulary. |
| `Services/RecentDocumentStore.swift` | Persists a **security-scoped bookmark** to the last-opened document so reopen-on-relaunch works under the App Sandbox. |
| `Services/CommandPaletteService.swift` | See below — the primary extension seam. |

### `ReamCore` — the portable core

A standalone SwiftPM library that **must not import any UI framework** (no
AppKit, SwiftUI, or PDFKit-UI). In v0.1 it is intentionally near-empty:

- `ReamCore` — namespace + version metadata.
- `PDFDescriptor` — a lightweight, engine-agnostic value type marking where the
  real PDF object model will live.

Its reason to exist is forward-looking: it is the seam that the **CLI** (`pdfx`)
and the **v1.0 fidelity-preserving editing engine** attach to. Because it is
UI-free and headless-testable, that engine (whether it wraps PDFium/MuPDF or
grows into a pure-Swift PDF object library) can be developed and pixel-diff
tested independently of the app.

## Key seams (build against these)

### 1. The command palette — `CommandPaletteService`

The single registry for every user-invocable action, surfaced by **⌘K**. It is a
`@MainActor` `ObservableObject` singleton (`CommandPaletteService.shared`).

```swift
CommandPaletteService.shared.register(
    PaletteCommand(
        id: "page.rotateClockwise",       // stable, unique; re-registering replaces
        title: "Rotate Page Clockwise",
        category: "Pages",                 // optional grouping
        keyboardShortcut: "⌘⇧R"            // display hint only
    ) {
        // perform the action
    }
)
```

- Re-registering the same `id` **replaces** rather than duplicates, so views can
  register on appear safely.
- `unregister(id:)` when the owning document/window closes.
- `filtered(by:)` powers the palette's search.

> **v0.1 limitation:** the palette *overlay* renders inside a document window, so
> it currently needs an open PDF to appear on screen (the ⌘K menu command is
> always present). A future change should host the palette at the scene/app
> level so it works from a bare launch too.

### 2. The document model — `PDFReferenceDocument`

Phase 2 features mutate `pdfDocument` (a `PDFKit.PDFDocument`) in place and rely
on `snapshot(contentType:)` for saving. Today `snapshot` returns the original
bytes unchanged (a byte-stable no-op round-trip). Editing features must preserve
that fidelity contract and add round-trip tests.

### 3. PDF view actions — `PDFViewCoordinator` / `PDFViewAction`

Anything that needs to drive the on-screen `PDFView` (zoom, fit, and later:
scroll-to-page, selection, search highlighting) should extend `PDFViewAction`
and route through the coordinator rather than reaching into `PDFView` directly.

### 4. The editing engine — `ReamCore`

The v1.0 flagship (true in-place editing) lands as new types in `ReamCore`,
consumed by the app through models like `PDFDescriptor`. Keep engine work
UI-free so it stays portable and testable via the fidelity regression suite.

## Build & signing model

- The `.xcodeproj` is **generated** from `project.yml` via XcodeGen and is
  git-ignored. Change project structure in `project.yml`, not in Xcode.
- Targets sign **ad-hoc** (`CODE_SIGN_IDENTITY = "-"`, no team) by default so the
  app builds on CI runners (which have no signing identity) and for any
  contributor. Locally, Xcode/`xcodebuild` can override with a real Apple
  Development identity — required to run `ReamUITests` (bundle injection needs a
  signing identity).
- App Sandbox + hardened-runtime-ready entitlements; `com.adobe.pdf` is
  registered as the document type.
