<div align="center">

# Ream

**A free, open-source, fully native macOS PDF app** that views, edits, and
transforms PDFs entirely on-device — with true in-place editing that preserves
the document's exact appearance, and optional AI features powered by your own
API keys.

> _"Everything Acrobat Pro does. Nothing leaves your Mac. $0 forever."_

</div>

---

> [!NOTE]
> **Status: v0.1 alpha — "Better than Preview."** Everything in the v0.1
> milestone of [`pdf-editor-scope.md`](pdf-editor-scope.md) has landed: the
> viewer (tabs, content-aware dark mode, full-text search), annotations, page
> management, compress-to-target-size, images↔PDF, the metadata editor, and
> password add/remove. Milestone A of true in-place text editing is also live:
> supported text operands are changed through append-only PDF incremental
> updates. It is alpha software — expect rough edges — but it is no longer just
> a viewer.

## Screenshot

<!-- TODO: replace with a real screenshot once the viewer chrome is finalized. -->
<div align="center">
  <em>Screenshot coming soon.</em>
</div>

## Why Ream

- **Local-first, always.** No accounts, no cloud, no telemetry, no uploads. Every
  operation runs on your machine.
- **Fidelity is sacred.** Editing a PDF must never reflow or re-render anything
  you didn't touch. Open → edit one word → save → every other byte is stable.
- **Native or nothing.** Swift + SwiftUI with AppKit interop, Apple silicon
  first. No Electron.
- **Free means free.** No watermarks, no page limits, no "pro" tier, no nags.
- **BYO intelligence.** AI is opt-in, keys live in the macOS Keychain, and it
  works with fully local models for the privacy purists.

## What works today

**Reading**

- Open via **File → Open**, drag-and-drop, or double-click in Finder. Native
  window **tabs** (⌘T to open in a new tab, ⌘⇧] / ⌘⇧[ to cycle), Autosave and
  Versions, and reopen-last-session on relaunch — including each document's
  page, scroll position and zoom.
- **Content-aware dark mode (⌘⇧I)** — inverts white paper and black text without
  wrecking colour photos, applied per page at render time. It never touches the
  saved bytes.
- **Full-text search (⌘F, ⌘G / ⌘⇧G)** with whole-word, case-sensitive and regex
  toggles, and a results list showing the page and a one-line preview.
- Left inspector: **thumbnails**, **outline/bookmarks**, and **search results**.
- Layouts: single page, continuous, two-page spread, book (correct odd/even
  cover), full screen and presentation mode. Zoom **In (⌘+) / Out (⌘−) /
  Actual Size (⌘0) / Fit Page (⌘1) / Fit Width (⌘2)**.
- Copy de-hyphenates and re-joins wrapped lines, so pasted text is not full of
  line-break garbage.

**Annotating**

- Highlight (⌘⇧H), underline, strikethrough, squiggly; **ink** with smoothing
  and an eraser; rectangle, ellipse, line, arrow, polygon and polyline; sticky
  notes (⌘⇧N), free text and callouts; a stamp library with dynamic
  (date/name) stamps.
- Annotation inspector, ⌃1–⌃5 colour swatches, **flatten** (all or selected),
  and **XFDF import/export** for round-tripping with other readers.

**Editing**

- **Edit Text (⌃⌘E)** from the toolbar, Edit menu, or ⌘K palette. Hover an
  editable run, click it, type in place, press Return to commit or Esc to
  cancel. The original font, start position, kerning operators and every
  untouched source byte are preserved.
- Text-only saves return the original file plus an append-only incremental
  update verbatim. Repeated edits append further revisions, and Undo/Redo uses
  byte snapshots. If annotations/page/metadata changes are mixed in, PDFKit
  reserializes at save time (visual fidelity remains, byte stability does not).
- Milestone A rejects encrypted PDFs and characters the existing font/subset
  cannot encode, and explains why without applying a partial edit. Composite
  fonts without a trustworthy Unicode map are not exposed as editable text.
  Scanned or flattened pages correctly report that they have no editable text
  layer.

**Pages**

- **Manage Pages (⌘⇧M)** — a thumbnail grid with drag-reorder, rotate, delete,
  duplicate and extract.
- **Merge** several PDFs (including interleave, for duplex scans split across
  two files), **split** by page ranges / every N pages / bookmarks, and
  **insert** blank pages, pages from another PDF, or images.
- Every page operation is undoable (⌘Z).

**Convert & export**

- **Compress (⌃⌘C)** with quality presets or a **target file size** — a binary
  search over resolution and quality lands at or just under the size you ask
  for.
- **Images → PDF (⌥⌘I)** from HEIC/PNG/JPEG/TIFF, sized to the image or to
  US Letter / A4.
- **PDF → images (⌘⇧E)** as PNG/JPEG/TIFF at a chosen DPI, optionally zipped.

**Documents & security**

- **Document properties (⌘I)** — title/author/subject/keywords, plus file and
  page statistics.
- **Encrypt** with user/owner passwords and permission flags (AES-128, the
  strongest the native writer emits), **remove password**, and **strip all
  metadata** (Info dictionary, XMP, thumbnails, annotations, prior versions).

**Everywhere**

- **⌘K command palette** — every action above is registered and acts on the
  focused window.

## Building from source

**Requirements:** macOS 14 (Sonoma)+, Xcode 15+.

The Xcode project is generated from [`project.yml`](project.yml) with
[XcodeGen](https://github.com/yonaskolb/XcodeGen), so the `.xcodeproj` is not
checked in (no more merge conflicts over project internals).

```bash
git clone https://github.com/harshmhta/ream.git
cd ream
./scripts/bootstrap.sh      # installs XcodeGen if needed, generates Ream.xcodeproj
open Ream.xcodeproj         # then ⌘R in Xcode
```

Or headlessly:

```bash
./scripts/test.sh           # generate + build + test (mirrors CI)
```

## Roadmap

Ream ships in phases, following §15 of
[`pdf-editor-scope.md`](pdf-editor-scope.md). **v0.1 is complete**; the table
below tracks what is next.

| Phase    | Theme                    | Highlights |
|----------|--------------------------|------------|
| **v0.1** | _Better than Preview_ ✅  | Viewer (tabs, dark-content mode, search), annotations, page management (merge/split/reorder/rotate), compress with target-size, images↔PDF, metadata editor, password add/remove — plus the document shell, ⌘K palette and portable core they build on |
| v0.5     | _Cancel iLovePDF_        | OCR (Vision), batch operations, watermarks/page numbers/headers, form filling, signature library, →Markdown / →text export, CLI, Quick Look extension |
| v1.0     | _Cancel Acrobat_ 🎯       | **True in-place text editing Milestone A ✅**, then text fallback/layout controls, image editing, form creation, true redaction, document compare, sanitize, bookmarks editor, Shortcuts |
| v1.5     | _The AI Update_          | BYO-key provider layer, chat-with-PDF (cited), summarize/explain/translate, semantic search, AI form-fill, table extraction |
| v2.0     | _Power & Trust_          | Cryptographic signing + verification, multi-doc chat, data extraction pipelines, watch folders, plugin API |

## Architecture

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the module map and the
seams downstream features build against. In short:

- **`Ream/`** — the SwiftUI/AppKit app (viewer, document model, command palette).
- **`ReamCore/`** — a UI-free Swift package containing the portable PDF object
  model, content/text engine, and incremental-update writer used by the app and
  future CLI.

## Contributing

Contributions are welcome — see [`CONTRIBUTING.md`](CONTRIBUTING.md) for how to
build, coding style, and the PR checklist.

## License

Ream is licensed under the **GNU General Public License v3.0** — see
[`LICENSE`](LICENSE). (This is deliberate: the v1.0 editing engine may build on
copyleft PDF libraries; keeping the project GPL leaves that door open. See the
"Engine reality check" notes in the scope doc.)
