import Foundation

/// Namespace + metadata for the portable Ream core.
///
/// `ReamCore` is deliberately minimal in v0.1. It exists so that the CLI and
/// the future fidelity-preserving editing engine (v1.0) have a UI-free library
/// to build on. Nothing here imports AppKit, SwiftUI, or PDFKit — keep it that
/// way so the core stays portable and headless-testable.
public enum ReamCore {
    /// Semantic version of the core library, kept in sync with the app.
    public static let version = "0.1.0"

    /// Human-readable name used in logs and CLI banners.
    public static let name = "ReamCore"
}
