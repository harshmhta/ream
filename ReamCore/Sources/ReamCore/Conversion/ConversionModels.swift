import Foundation
import CoreGraphics

// MARK: - Progress & cancellation

/// A cooperative cancellation flag shared between a long-running conversion and
/// its caller (typically a SwiftUI sheet's "Cancel" button).
///
/// Deliberately tiny and UI-free so it lives in `ReamCore` alongside the engines
/// and can be reused by the future `pdfx` CLI. Thread-safe via an internal lock;
/// engines poll `isCancelled` at page boundaries.
public final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    /// Request cancellation. Safe to call from any thread (e.g. the main actor).
    public func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    /// Whether cancellation has been requested.
    public var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    /// Throw ``ConversionError/cancelled`` if cancellation was requested.
    public func checkCancellation() throws {
        if isCancelled { throw ConversionError.cancelled }
    }
}

/// A single progress update from a running conversion.
///
/// `fraction` is clamped to `0...1`. `message` is a short human-readable status
/// suitable for a progress sheet ("Compressing page 3 of 12…").
public struct ConversionProgress: Sendable, Equatable {
    public let fraction: Double
    public let message: String

    public init(fraction: Double, message: String) {
        self.fraction = min(max(fraction, 0), 1)
        self.message = message
    }
}

/// Progress callback signature. Engines call this on an arbitrary queue; UI code
/// is responsible for hopping to the main actor.
public typealias ProgressHandler = @Sendable (ConversionProgress) -> Void

// MARK: - Errors

/// Errors thrown by the conversion engines.
public enum ConversionError: Error, LocalizedError, Equatable {
    /// The operation was cancelled via a ``CancellationToken``.
    case cancelled
    /// The input PDF could not be parsed.
    case invalidPDF
    /// The PDF has zero pages.
    case emptyDocument
    /// No input images were provided (Images → PDF).
    case noImages
    /// An image file could not be decoded.
    case unreadableImage(String)
    /// A page could not be rasterized.
    case renderFailed(pageIndex: Int)
    /// The requested image format cannot be encoded on this system
    /// (e.g. WebP, which ImageIO can decode but not encode on current macOS).
    case unsupportedExportFormat(String)
    /// A destination could not be created (bad path, permissions).
    case cannotCreateOutput(String)

    public var errorDescription: String? {
        switch self {
        case .cancelled:
            return "The operation was cancelled."
        case .invalidPDF:
            return "The PDF could not be read."
        case .emptyDocument:
            return "The document has no pages."
        case .noImages:
            return "No images were provided."
        case .unreadableImage(let name):
            return "Could not read the image “\(name)”."
        case .renderFailed(let index):
            return "Could not render page \(index + 1)."
        case .unsupportedExportFormat(let name):
            return "The \(name) format can’t be written on this version of macOS."
        case .cannotCreateOutput(let path):
            return "Could not write to “\(path)”."
        }
    }
}

// MARK: - Byte formatting

/// Small helper so both the engines (for error messages) and the UI format byte
/// counts the same way, without pulling `ByteCountFormatter` (AppKit-adjacent).
public enum ByteFormat {
    /// Format a byte count as e.g. "1.9 MB" using base-1000 units (matches Finder
    /// and the "≤ 2 MB" mental model users have for upload limits).
    public static func string(fromBytes bytes: Int) -> String {
        let value = Double(bytes)
        if value < 1000 { return "\(bytes) bytes" }
        let units = ["KB", "MB", "GB", "TB"]
        var scaled = value / 1000
        var unitIndex = 0
        while scaled >= 1000 && unitIndex < units.count - 1 {
            scaled /= 1000
            unitIndex += 1
        }
        return String(format: "%.1f %@", scaled, units[unitIndex])
    }

    /// Convert megabytes (as shown in the UI) to a byte count. Clamps to a sane
    /// range so an extreme typed value can't overflow `Int` (a crash) or go
    /// non-positive.
    public static func bytes(fromMegabytes mb: Double) -> Int {
        let bytes = (mb.isFinite ? mb : 0) * 1000 * 1000
        let clamped = min(max(bytes, 1), 1_000_000_000_000) // 1 byte … 1 TB
        return Int(clamped.rounded())
    }
}

// MARK: - File naming

/// Helpers for turning arbitrary document titles / image stems into safe output
/// file names (no path separators, no reserved characters) and for keeping a set
/// of names unique.
public enum FileNaming {
    /// Strip path separators and other characters that are illegal or awkward in
    /// a file name, collapsing them to a single space. Falls back to `fallback`
    /// if nothing usable remains.
    public static func sanitized(_ raw: String, fallback: String = "Untitled") -> String {
        // Disallow path separators (/ and, on HFS+, :) plus control chars.
        let illegal = CharacterSet(charactersIn: "/\\:\u{0}").union(.controlCharacters)
        let cleaned = raw.components(separatedBy: illegal).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? fallback : cleaned
    }

    /// Return `desired` if unused, else append " (2)", " (3)", … before the
    /// extension until unique within `used`. Mutates `used` to record the result.
    public static func unique(_ desired: String, in used: inout Set<String>) -> String {
        let lower = desired.lowercased()
        if !used.contains(lower) {
            used.insert(lower)
            return desired
        }
        let ns = desired as NSString
        let ext = ns.pathExtension
        let stem = ns.deletingPathExtension
        var index = 2
        while true {
            let candidate = ext.isEmpty ? "\(stem) (\(index))" : "\(stem) (\(index)).\(ext)"
            if !used.contains(candidate.lowercased()) {
                used.insert(candidate.lowercased())
                return candidate
            }
            index += 1
        }
    }
}
