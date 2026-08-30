import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Raster image formats the app can export a PDF to.
///
/// WebP is intentionally represented so the UI can *offer* it, but ImageIO on
/// current macOS can decode WebP yet not encode it. ``isEncodable`` reflects the
/// live capability so the UI can disable it honestly (per the scope's "warn
/// honestly, don't pretend" principle) and it will light up automatically if a
/// future macOS adds the encoder.
public enum ImageFormat: String, CaseIterable, Sendable, Identifiable {
    case png
    case jpeg
    case tiff
    case webp

    public var id: String { rawValue }

    /// User-facing name.
    public var displayName: String {
        switch self {
        case .png: return "PNG"
        case .jpeg: return "JPEG"
        case .tiff: return "TIFF"
        case .webp: return "WebP"
        }
    }

    /// File extension (no dot).
    public var fileExtension: String {
        switch self {
        case .png: return "png"
        case .jpeg: return "jpg"
        case .tiff: return "tiff"
        case .webp: return "webp"
        }
    }

    /// Whether this format supports lossy quality control (affects the UI's
    /// quality slider visibility).
    public var isLossy: Bool { self == .jpeg || self == .webp }

    /// The uniform type identifier ImageIO uses for this format.
    public var utType: CFString {
        switch self {
        case .png: return UTType.png.identifier as CFString
        case .jpeg: return UTType.jpeg.identifier as CFString
        case .tiff: return UTType.tiff.identifier as CFString
        case .webp: return UTType.webP.identifier as CFString
        }
    }

    /// The set of destination UTIs ImageIO can actually write on this machine.
    private static let encodableUTIs: Set<String> = {
        let ids = (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
        return Set(ids)
    }()

    /// Whether ImageIO can encode this format on the current system.
    public var isEncodable: Bool {
        Self.encodableUTIs.contains(utType as String)
    }

    /// All formats the current system can actually export.
    public static var encodableCases: [ImageFormat] {
        allCases.filter { $0.isEncodable }
    }
}

/// Encodes `CGImage`s to compressed data / files via ImageIO.
public enum ImageEncoder {

    /// Encode an image to in-memory data.
    ///
    /// - Parameters:
    ///   - image: the bitmap to encode.
    ///   - format: destination format.
    ///   - quality: `0...1` lossy quality (ignored by lossless formats).
    ///   - dpi: resolution metadata to stamp into the file so downstream tools
    ///     (and re-imports) know the physical size.
    public static func encodedData(image: CGImage,
                                   format: ImageFormat,
                                   quality: CGFloat,
                                   dpi: CGFloat? = nil) throws -> Data {
        guard format.isEncodable else {
            throw ConversionError.unsupportedExportFormat(format.displayName)
        }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data as CFMutableData, format.utType, 1, nil
        ) else {
            throw ConversionError.unsupportedExportFormat(format.displayName)
        }

        var options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality
        ]
        if let dpi {
            options[kCGImagePropertyDPIWidth] = dpi
            options[kCGImagePropertyDPIHeight] = dpi
        }

        CGImageDestinationAddImage(dest, image, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw ConversionError.unsupportedExportFormat(format.displayName)
        }
        return data as Data
    }

    /// Encode an image directly to a file URL.
    public static func write(image: CGImage,
                             to url: URL,
                             format: ImageFormat,
                             quality: CGFloat,
                             dpi: CGFloat? = nil) throws {
        let data = try encodedData(image: image, format: format,
                                   quality: quality, dpi: dpi)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw ConversionError.cannotCreateOutput(url.path)
        }
    }

    /// JPEG-encode an image and return the byte count only — used by the
    /// compression binary search to measure a candidate without keeping the data.
    ///
    /// Throws on encode failure rather than reporting 0, so the search's size
    /// estimate can never silently undercount a page that the final render pass
    /// would fail on (or encode larger).
    public static func jpegByteCount(image: CGImage, quality: CGFloat) throws -> Int {
        try encodedData(image: image, format: .jpeg, quality: quality).count
    }
}
