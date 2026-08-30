# Ream Architecture

This document maps the modules that make up Ream, what each is responsible for,
and — most importantly for contributors — **the seams that future features plug
into**. It reflects the shipped v0.1 (viewer, annotations, page operations,
convert/export, metadata + security); each phase in the
[roadmap](../README.md#roadmap) extends these seams rather than replacing them.

## High-level shape

```
┌──────────────────────────────────────────────────────────────────┐
│  Ream (app target)  —  SwiftUI + AppKit interop                   │
│                                                                   │
│   App/           ReamApp (@main, DocumentGroup) · AppDelegate     │
│                  ReamCommands · AnnotationCommands · FocusedValues│
│   Documents/     PDFReferenceDocument (+PageOps extension)        │
│                  InvertingPDFDocument / InvertingPDFPage          │
│   Annotations/   AnnotationController · AnnotationFactory         │
│                  ReamPDFView · FlattenService · XFDFService       │
│                  StampLibrary · InkSmoothing · CustomAnnotations  │
│   Views/         PDFDocumentView · PDFKitView · InspectorSidebar  │
│                  Thumbnail/Outline/Search sidebars · page-op and  │
│                  conversion sheets · CommandPaletteView           │
│   ViewModels/    DocumentWindowModel · DocumentViewModel          │
│   Services/      PDFViewCoordinator · SearchService               │
│                  PageOperations · PageOpsController               │
│                  ConversionCoordinator · DarkContentInverter      │
│                  PDFMetadata/Security/Stats/XMPService            │
│                  RecentDocumentStore · SessionTracker             │
│                  DocumentPreferencesStore                         │
│                  CommandPaletteService  (⌘K registry)             │
│   Resources/     Info.plist · Ream.entitlements · Assets          │
└───────────────────────────┬───────────────────────────────────────┘
                            │  depends on
                            ▼
┌──────────────────────────────────────────────────────────────────┐
│  ReamCore (Swift package)  —  UI-free, portable                   │
│    Conversion/   CompressionEngine · ImagesToPDFConverter         │
│                  PDFToImagesExporter · PDFBuilder · ZipWriter     │
│                  PDFPageRasterizer · ImageEncoding                │
│    TextReflow · PlainTextSearch · DocumentMetadata                │
│    DocumentPermissions · PDFDescriptor (model seam)               │
│    → seam for the CLI (`pdfx`) and the v1.0 editing engine        │
└──────────────────────────────────────────────────────────────────┘
```

## Modules

### `Ream` — the app target

A **document-based SwiftUI app**. The app-level building blocks:

| File | Responsibility |
|------|----------------|
| `App/ReamApp.swift` | `@main`. Declares a `DocumentGroup(viewing:)` bound to `PDFReferenceDocument` — this gives tabs, multiple windows, Finder open, drag-onto-dock, and Autosave/Versions for free. Installs `ReamCommands`. |
| `App/AppDelegate.swift` | Lifecycle hooks SwiftUI doesn't expose: suppresses the blank untitled window (Ream is a viewer) and reopens the last document on relaunch if the system didn't restore windows. |
| `App/ReamCommands.swift` | Menu-bar `Commands`: the ⌘K palette toggle, File-menu page ops + convert/export + metadata/security, the Find items, and the View menu (sidebar, dark content, layouts, navigation, zoom). Everything targets the **focused** window via `@FocusedValue`. Sections are wrapped in `Group`s — `@CommandsBuilder` silently drops past ten direct children. |
| `App/AnnotationCommands.swift` | The Annotations menu (markup shortcuts, XFDF import/export, flatten). |
| `App/FocusedValues.swift` | The `@FocusedValue` keys exposing the key window's `DocumentWindowModel`, `PDFViewCoordinator`, `PDFReferenceDocument`, `DocumentActionsModel`, `AnnotationController`, `PageOpsController` and `ConversionCoordinator` to app-level menu commands. |
| `Documents/PDFReferenceDocument.swift` | The document model. Uses `ReferenceFileDocument` (reference type) because `PDFKit.PDFDocument` is a class and features mutate it in place. `snapshot(contentType:)` is the byte-stable no-op save seam. See “document replacement” below. |
| `Documents/PDFReferenceDocument+PageOps.swift` | Undoable page mutations (rotate / delete / duplicate / move / insert), all funnelled through one snapshot-and-restore primitive so undo and redo ping-pong indefinitely. |
| `Documents/InvertingPDFDocument.swift` | The `PDFDocument`/`PDFPage` subclasses behind content-aware dark mode. Inversion happens in `PDFPage.draw`, so it is render-only and never reaches the saved bytes. |
| `Annotations/` | Annotation authoring: the controller (tools, style, selection, undo), the factory, the `PDFView` subclass that routes mouse events, flatten, XFDF, stamps, ink smoothing, and the `PDFAnnotation` subclasses PDFKit has no native class for (Squiggly / Polygon / PolyLine). |
| `Views/PDFKitView.swift` | `NSViewRepresentable` wrapping AppKit's `PDFView` — the Metal-backed renderer. Configures the view, restores the saved reading position, and reports scroll/zoom changes back so they can be persisted. |
| `Views/PDFDocumentView.swift` | Per-window root view: composes the toolbar, inspector, renderer, palette overlay, progress panel and every sheet, and publishes the window's models as focused scene values. The four `.sheet(item:)` bindings deliberately sit on **different** views — SwiftUI hosts one sheet per view. |
| `Views/CommandPaletteView.swift` | The ⌘K overlay UI (search field + results list) bound to `CommandPaletteService`. |
| `ViewModels/DocumentWindowModel.swift` | The per-window hub the menu bar drives: owns the coordinator, the search service, inspector state and dark content, and re-derives them when the document is replaced. |
| `Services/PDFViewCoordinator.swift` | The one place that talks to `PDFView`. Menus, toolbar and palette all drive it through the `PDFViewAction` vocabulary; it also owns view modes, reading-state capture/restore, search highlighting and presentation mode. |
| `Services/SearchService.swift` | Full-text search over the open document: caches page text, matches via `ReamCore/PlainTextSearch` off the main actor, and republishes results plus a hit cursor for ⌘G / ⌘⇧G. |
| `Services/PageOperations.swift` · `PageOpsController.swift` | Pure page/document operations (merge, split, extract, blank/image page construction) and the controller that runs them off the main thread with progress + cancellation. |
| `Services/ConversionCoordinator.swift` | Drives the `ReamCore` conversion engines (compress, images→PDF, PDF→images) from the focused window, with progress and cancellation. |
| `Services/RecentDocumentStore.swift` · `SessionTracker.swift` | Persist **security-scoped bookmarks** for the last session so reopen-on-relaunch works under the App Sandbox. |
| `Services/DocumentPreferencesStore.swift` | Per-document reading state (page, scroll point, zoom, layout, dark content), keyed by file URL. |
| `Services/CommandPaletteService.swift` | See below — the primary extension seam. |

### `ReamCore` — the portable core

A standalone SwiftPM library that **must not import any UI framework** (no
AppKit, SwiftUI, or PDFKit-UI — CoreGraphics/ImageIO are fine). What lives there
today:

| Area | Contents |
|------|----------|
| `Conversion/` | `CompressionEngine` (quality presets, manual downsampling, and a binary search over resolution × quality to hit a **target file size**), `ImagesToPDFConverter`, `PDFToImagesExporter`, `PDFBuilder`, `PDFPageRasterizer`, `ImageEncoding` (PNG/JPEG/TIFF), `ZipWriter`. |
| Text | `TextReflow` (line-break de-hyphenation + paragraph joining for copy), `PlainTextSearch` (match ranges + windowed previews, with case / whole-word / regex options). |
| Models | `DocumentMetadata`, `DocumentPermissions`, `PDFDescriptor`. |

Everything here is headless-testable, and the package has its **own test target**
that the app scheme does not include — `xcodebuild test` and ⌘U do not run it.
CI and `scripts/test.sh` run `swift test --package-path ReamCore` separately; do
the same locally when you touch the core.

Its reason to exist is also forward-looking: it is the seam that the **CLI**
(`pdfx`) and the **v1.0 fidelity-preserving editing engine** attach to. Because
it is UI-free, that engine (whether it wraps PDFium/MuPDF or grows into a
pure-Swift PDF object library) can be developed and pixel-diff tested
independently of the app.

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

- Commands that act on a *window* (viewer, page ops, annotations, conversion) are
  re-registered / re-targeted when that window becomes key, so ⌘K always drives
  the focused document rather than whichever opened last.

> **Known limitation:** the palette *overlay* renders inside a document window,
> so it currently needs an open PDF to appear on screen (the ⌘K menu command is
> always present). A future change should host the palette at the scene/app
> level so it works from a bare launch too.

### 2. The document model — `PDFReferenceDocument`

Phase 2 features mutate `pdfDocument` (a `PDFKit.PDFDocument`) in place and rely
on `snapshot(contentType:)` for saving. For an untouched document `snapshot`
still returns the original bytes unchanged (the byte-stable no-op round-trip);
it only diverges when the user explicitly edits. Editing features must preserve
that fidelity contract and add round-trip tests.

The **metadata + security** feature extends this model with:

- `updateMetadata(_:undoManager:)` — mutate the Info dictionary in place.
- `setEncryption(_:undoManager:)` — stage an in-memory `EncryptionSettings`;
  `snapshot()` then emits encrypted bytes at save time. **Passwords live only in
  memory** (never persisted anywhere but the encrypted PDF itself), honoring the
  "store nothing" rule.
- `stripAllMetadata(undoManager:)` / `removePassword(undoManager:)` — replace
  `pdfDocument` with a page-rebuilt copy (a fresh `PDFDocument` starts with an
  empty catalog, the only reliable way to drop an existing `/Encrypt` dict or XMP
  `/Metadata` stream — PDFKit otherwise carries both forward across a plain
  re-serialize).

All are undoable via `UndoManager`. The PDFKit-touching logic lives in
`Services/PDF{Metadata,Security,Stats,XMP}Service`; portable value types
(`DocumentMetadata`, `DocumentPermissions`, `EncryptionSettings`) live in
`ReamCore` (Foundation-only).

> **Encryption strength:** the native writer (`dataRepresentation(options:)` →
> `CGPDFContext`) emits **AES-128** (`/V 4 /R 4 /CFM /AESV2`) — the strongest
> algorithm reachable without a third-party engine. True AES-256 (`/V 5 /R 6
> /AESV3`, PDF 2.0) is a tracked follow-up for when the `ReamCore` PDF object
> model lands; it requires a native dependency (qpdf/PDFium) that is out of v0.1
> scope.

### 2a. Per-window action seams — focused values

Menu commands and ⌘K palette entries drive the **focused** window through
`@FocusedValue`. `PDFDocumentView` publishes seven focused scene values:
`documentModel` (the `DocumentWindowModel`), `pdfCoordinator`,
`pdfReferenceDocument`, `documentActions` (a `DocumentActionsModel` owning the
`.sheet(item:)` state for the Document Properties / Encrypt / Strip / Unlock
dialogs), `annotationController`, `pageOps` and `conversionCoordinator`. A locked
(encrypted) document auto-presents the unlock prompt on appear.

Menu items whose *title* or checkmark depends on model state (Hide/Show Sidebar,
Invert/Restore Page Content, the active layout) cannot read `@FocusedValue`
directly — a `Commands` body does not re-evaluate when the model publishes.
Extract those into a small `@ObservedObject` helper `View` inside the
`CommandGroup`, as `ReamCommands` does.

### 3. PDF view actions — `PDFViewCoordinator` / `PDFViewAction`

Anything that needs to drive the on-screen `PDFView` should extend
`PDFViewAction` and route through the coordinator rather than reaching into
`PDFView` directly. Today: `zoomIn/Out`, `actualSize`, `fitWidth`, `fitPage`,
`setViewMode`, `goToPage`, `nextPage`, `previousPage`, `togglePresentation`,
`reload`.

Two things the coordinator knows that callers should not have to:

- **`reload` is not free.** Forcing PDFKit to re-lay-out after a page mutation
  means swapping the document out and back, which resets layout mode and zoom
  and can drop `currentPage`. The coordinator restores all three (clamping the
  page, since the one the reader was on may have just been deleted).
- **`currentPageIndex` is `nil` for a detached page.** `PDFDocument.index(for:)`
  answers `NSNotFound` — a large *positive* number — for a page that was removed,
  so a `>= 0` check is not enough.

### 4. Page mutations — `.reamPagesDidChange` + `pageGeneration`

Every in-place page edit funnels through `PDFReferenceDocument+PageOps`, which
bumps `pageGeneration` and posts `.reamPagesDidChange`. Views observe the
generation to invalidate derived state (the thumbnail cache), and the window
view reacts to the notification by relaying out the `PDFView` and telling the
window model that the page list changed — which drops the search service's
cached page text and rebuilds the outline. **Anything that caches per-page state
must hook one of those two.**

### 5. Document replacement — the invariant

Strip All Metadata, Remove Password and Flatten Annotations do **not** mutate the
open document: they rebuild it and assign a new `PDFDocument` to
`PDFReferenceDocument.pdfDocument`. Two rules follow, and both have bitten:

1. **Producers of a replacement must return an `InvertingPDFDocument` carrying
   `AnnotationDocumentDelegate.shared`.** Dark content keys off the document's
   type and custom annotation subtypes key off the delegate; a plain
   `PDFDocument` silently disables both for the rest of the session.
2. **Anything caching the document must follow the swap.** Subscribe to
   `document.$pdfDocument` (`.dropFirst()`), and read the new document from the
   sink's *value* — `@Published` fires in `willSet`, so the property still holds
   the old one at that point. `DocumentWindowModel` re-attaches search and
   rebuilds the outline this way; `AnnotationController` drops its selection and
   undo stacks, which name pages of the discarded document.

Related: **dark content is render-only**. Inversion lives in `PDFPage.draw`, so
any operation that *rasterizes* a page (flatten, thumbnails, export-as-image)
must disable it for the duration or it gets baked into the output.

### 6. The editing engine — `ReamCore`

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
