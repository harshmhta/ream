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
> **Status: v0.1 alpha — "Better than Preview."** This is the foundation
> release: a fast, native PDFKit-based viewer with a document-based app shell,
> tabs, and the seams (command palette, portable core library) that the rest of
> the app is built on. Editing, annotations, and page operations are on the
> roadmap below.

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

## What works today (v0.1)

- Open PDFs via **File → Open**, drag-and-drop, or double-click in Finder.
- Fast rendering via **PDFKit** (`PDFView`) with continuous vertical scroll.
- Zoom: **In (⌘+) / Out (⌘−) / Actual Size (⌘0) / Fit Page (⌘1) / Fit Width (⌘2)**.
- Document-based architecture: multiple windows, tabs, Autosave/Versions, and
  reopen-last-document on relaunch.
- **⌘K command palette** shell — the registration surface every future feature
  plugs into.

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

Ream ships in phases. v0.1 is the foundation; each phase adds a chunk of the
scope described in [`pdf-editor-scope.md`](pdf-editor-scope.md).

| Phase    | Theme                    | Highlights |
|----------|--------------------------|------------|
| **v0.1** | _Better than Preview_ ✅  | Viewer (tabs, continuous scroll, zoom), document shell, ⌘K palette seam, portable core |
| v0.5     | _Cancel iLovePDF_        | Annotations, page management (merge/split/reorder/rotate), compress with target-size, images↔PDF, metadata editor, password add/remove |
| v0.9     | _Convert everything_     | OCR (Vision), batch ops, watermarks/page numbers, form filling, signature library, conversion suite (→Markdown/images/text), CLI, Quick Look |
| v1.0     | _Cancel Acrobat_ 🎯       | **True in-place text/image editing**, form creation, true redaction, document compare, sanitize, bookmarks editor, Shortcuts |
| v1.5     | _The AI Update_          | BYO-key provider layer, chat-with-PDF (cited), summarize/explain/translate, semantic search, AI form-fill, table extraction |
| v2.0     | _Power & Trust_          | Cryptographic signing + verification, multi-doc chat, data extraction pipelines, watch folders, plugin API |

## Architecture

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the module map and the
seams downstream features build against. In short:

- **`Ream/`** — the SwiftUI/AppKit app (viewer, document model, command palette).
- **`ReamCore/`** — a UI-free Swift package: the portable core the future CLI and
  the v1.0 content-stream editing engine plug into.

## Contributing

Contributions are welcome — see [`CONTRIBUTING.md`](CONTRIBUTING.md) for how to
build, coding style, and the PR checklist.

## License

Ream is licensed under the **GNU General Public License v3.0** — see
[`LICENSE`](LICENSE). (This is deliberate: the v1.0 editing engine may build on
copyleft PDF libraries; keeping the project GPL leaves that door open. See the
"Engine reality check" notes in the scope doc.)
