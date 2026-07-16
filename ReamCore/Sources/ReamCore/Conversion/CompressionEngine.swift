import Foundation
import CoreGraphics
import ImageIO

// MARK: - Presets & settings

/// Ghostscript-style quality presets. Each maps to a resolution cap and a JPEG
/// quality; higher presets keep more detail (and more bytes).
public enum QualityPreset: String, CaseIterable, Sendable, Identifiable {
    case screen    // smallest — on-screen viewing
    case ebook     // e-reader / email
    case printer   // desktop printing
    case prepress  // high-quality print

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .screen: return "Screen"
        case .ebook: return "eBook"
        case .printer: return "Printer"
        case .prepress: return "Prepress"
        }
    }

    /// Short explanation for the UI.
    public var detail: String {
        switch self {
        case .screen: return "72 DPI · smallest, for viewing on screen"
        case .ebook: return "150 DPI · good for email and e-readers"
        case .printer: return "300 DPI · sharp for desktop printing"
        case .prepress: return "300 DPI · highest quality for print shops"
        }
    }

    var dpi: CGFloat {
        switch self {
        case .screen: return 72
        case .ebook: return 150
        case .printer: return 300
        case .prepress: return 300
        }
    }

    var quality: CGFloat {
        switch self {
        case .screen: return 0.45
        case .ebook: return 0.6
        case .printer: return 0.72
        case .prepress: return 0.85
        }
    }
}

/// How a compression run should decide its resolution and quality.
public enum CompressionMode: Sendable {
    /// Fixed preset (resolution cap + quality).
    case preset(QualityPreset)
    /// Manual downsampling: explicit target DPI and JPEG quality.
    case downsample(dpi: CGFloat, quality: CGFloat)
    /// The killer feature: binary-search resolution + quality to land at or just
    /// under `targetBytes`, within `tolerance` (fraction, e.g. 0.05 == 5%).
    case targetSize(targetBytes: Int, tolerance: Double)
}

/// The outcome of a compression run.
public struct CompressionResult: Sendable {
    /// The compressed PDF bytes.
    public let data: Data
    public let originalBytes: Int
    public let compressedBytes: Int
    /// For target-size mode: whether the target was met within tolerance. Always
    /// `true` for preset/downsample modes.
    public let reachedTarget: Bool
    public let usedDPI: CGFloat
    public let usedQuality: CGFloat
    public let grayscale: Bool
    public let pageCount: Int

    /// Ratio of compressed to original size (e.g. 0.4 == 60% smaller).
    public var ratio: Double {
        guard originalBytes > 0 else { return 1 }
        return Double(compressedBytes) / Double(originalBytes)
    }

    /// A copy with `reachedTarget` overridden — used once the actual written size
    /// is known and compared to the target.
    func withReachedTarget(_ reached: Bool) -> CompressionResult {
        CompressionResult(data: data, originalBytes: originalBytes,
                          compressedBytes: compressedBytes, reachedTarget: reached,
                          usedDPI: usedDPI, usedQuality: usedQuality,
                          grayscale: grayscale, pageCount: pageCount)
    }
}

// MARK: - Engine

/// Compresses a PDF by rasterizing each page and re-encoding it as JPEG at a
/// chosen resolution and quality, then rebuilding the document with
/// ``PDFBuilder``.
///
/// **Why rasterize?** PDFKit exposes no content-stream editing API and there is
/// no PDF object model in v0.1 to surgically replace image XObjects, so the
/// scope's documented fallback — "use `CGPDFContext` to rebuild" — is the route
/// that actually guarantees a size reduction on an arbitrary PDF. The trade-off
/// is that text becomes part of the page image (no longer selectable); the UI
/// states this plainly. The v1.0 editing engine will enable XObject-only
/// recompression that preserves vector text.
///
/// The output size is **monotonic** in both DPI and JPEG quality, which is what
/// lets the target-size search converge deterministically.
public enum CompressionEngine {

    /// Absolute quality bounds for the target-size search. Below ~0.05 JPEG is
    /// unusable; above ~0.92 there is little size benefit.
    private static let qualityFloor: CGFloat = 0.05
    private static let qualityCeiling: CGFloat = 0.92

    /// DPI bounds for the target-size search. 300 is print-sharp; below ~36 text
    /// is unreadable. The search treats DPI as a *continuous* knob (not a fixed
    /// ladder) so it can spend the whole byte budget on resolution — a coarse
    /// ladder leaves "dead zones" where the output undershoots the target badly.
    private static let dpiFloor: CGFloat = 36
    private static let dpiCeiling: CGFloat = 300

    /// Reference point for the first size probe. Encoded size scales ~linearly
    /// with pixel count (i.e. with DPI²) and monotonically with quality, so one
    /// probe at this point lets us seed the DPI guess analytically.
    private static let probeDPI: CGFloat = 150
    private static let probeQuality: CGFloat = 0.7

    /// Cap on a single page's long edge in pixels, to keep memory bounded on
    /// pathological inputs (huge page × high DPI).
    private static let maxPagePixelEdge: CGFloat = 5000

    /// Approximate PDF structural overhead per page (page object, resources,
    /// content stream) on top of the embedded JPEG bytes. Measured empirically
    /// (~4 KB fixed + <1 KB/page); we subtract a small budget so many-page
    /// documents don't creep just over the target. Slightly conservative.
    private static let perPageOverheadBytes = 900
    private static let fixedOverheadBytes = 4000

    /// Compress `pdfData` per `mode`.
    ///
    /// - Parameters:
    ///   - pdfData: the source PDF bytes.
    ///   - mode: preset, manual downsample, or target size.
    ///   - progress: optional progress callback (called off the main actor).
    ///   - cancellation: optional cooperative cancel token, polled per page.
    public static func compress(pdfData: Data,
                                mode: CompressionMode,
                                progress: ProgressHandler? = nil,
                                cancellation: CancellationToken? = nil) throws -> CompressionResult {
        guard let provider = CGDataProvider(data: pdfData as CFData),
              let document = CGPDFDocument(provider) else {
            throw ConversionError.invalidPDF
        }
        let pageCount = document.numberOfPages
        guard pageCount > 0 else { throw ConversionError.emptyDocument }

        switch mode {
        case .preset(let preset):
            return try renderPass(document: document,
                                  originalBytes: pdfData.count,
                                  dpi: preset.dpi,
                                  quality: preset.quality,
                                  grayscale: false,
                                  reachedTarget: true,
                                  phase: "Compressing",
                                  progress: progress,
                                  cancellation: cancellation)
        case .downsample(let dpi, let quality):
            return try renderPass(document: document,
                                  originalBytes: pdfData.count,
                                  dpi: dpi,
                                  quality: quality,
                                  grayscale: false,
                                  reachedTarget: true,
                                  phase: "Compressing",
                                  progress: progress,
                                  cancellation: cancellation)
        case .targetSize(let targetBytes, let tolerance):
            return try compressToTarget(document: document,
                                        originalBytes: pdfData.count,
                                        targetBytes: targetBytes,
                                        tolerance: tolerance,
                                        progress: progress,
                                        cancellation: cancellation)
        }
    }

    // MARK: Target-size search

    private static func compressToTarget(document: CGPDFDocument,
                                         originalBytes: Int,
                                         targetBytes: Int,
                                         tolerance: Double,
                                         progress: ProgressHandler?,
                                         cancellation: CancellationToken?) throws -> CompressionResult {
        let pageCount = document.numberOfPages

        // The search measures the *sum of encoded JPEG bytes*; the final PDF adds
        // a little structural overhead per page. Aim the search at the JPEG
        // budget = target minus that overhead so the written file lands under the
        // target, not just over it.
        let overhead = fixedOverheadBytes + perPageOverheadBytes * pageCount
        let jpegBudget = max(1, targetBytes - overhead)
        // Accept the written file if it lands within tolerance of the target. The
        // small overhead cushion above means we normally land *under* target; this
        // ceiling covers the case where the overhead estimate was slightly low.
        let acceptCeiling = Int((Double(targetBytes) * (1 + tolerance)).rounded())

        // Finalize a candidate by writing the real PDF and deciding `reachedTarget`
        // from the *actual* bytes — never a hardcoded assumption.
        func finalize(dpi: CGFloat, quality: CGFloat, grayscale: Bool) throws -> CompressionResult {
            let out = try renderPass(document: document, originalBytes: originalBytes,
                                     dpi: dpi, quality: quality, grayscale: grayscale,
                                     reachedTarget: false, phase: "Writing compressed PDF",
                                     progress: progress, cancellation: cancellation)
            return out.withReachedTarget(out.compressedBytes <= acceptCeiling)
        }

        // Try color first; fall back to grayscale only if color can't get there.
        for grayscale in [false, true] {
            try cancellation?.checkCancellation()

            // 1) One probe at the reference DPI/quality to size the document.
            let probeCache = try PageRenderCache(document: document, dpi: probeDPI,
                                                 grayscale: grayscale, cancellation: cancellation)
            let probeSize = try probeCache.totalJPEGSize(quality: probeQuality,
                                                         progress: progress,
                                                         phaseFraction: grayscale ? 0.55 : 0.05,
                                                         label: "Analyzing document",
                                                         cancellation: cancellation)

            // 2) Seed a DPI guess: encoded size ∝ pixel count ∝ DPI². Solve for the
            //    DPI whose probe-quality size ≈ jpegBudget, clamped to sane bounds.
            //    (probeSize == 0 only on total encode failure, which would have
            //    thrown above; max(·,1) is a belt-and-braces guard.)
            let ratio = Double(jpegBudget) / Double(max(probeSize, 1))
            let seededDPI = clamp(probeDPI * CGFloat(ratio.squareRoot()),
                                  low: dpiFloor, high: dpiCeiling)

            // 3) At the seeded DPI, check the achievable range. If even the quality
            //    floor overshoots the budget, this color mode can't hit the target —
            //    move on (to grayscale, then to the absolute-floor fallback).
            let cache = try PageRenderCache(document: document, dpi: seededDPI,
                                            grayscale: grayscale, cancellation: cancellation)
            let floorSize = try cache.totalJPEGSize(quality: qualityFloor,
                                                    progress: progress,
                                                    phaseFraction: grayscale ? 0.7 : 0.2,
                                                    label: searchLabel(dpi: seededDPI, grayscale: grayscale),
                                                    cancellation: cancellation)
            guard floorSize <= jpegBudget else { continue }

            // 4) Spend the remaining budget on quality: bisect quality at this DPI
            //    for the highest quality whose sum stays within jpegBudget.
            let quality = try searchQuality(cache: cache, budget: jpegBudget,
                                            progress: progress,
                                            phaseFraction: grayscale ? 0.85 : 0.35,
                                            dpi: seededDPI, grayscale: grayscale,
                                            cancellation: cancellation)

            let candidate = try finalize(dpi: seededDPI, quality: quality, grayscale: grayscale)
            // Normally the estimate holds and the file is under target → done.
            // If a low overhead estimate pushed it just over, fall through to try
            // grayscale / the absolute floor for a genuinely smaller result.
            if candidate.reachedTarget { return candidate }
        }

        // Unreachable within our bounds: render at the *absolute* smallest settings
        // (lowest DPI, lowest quality, grayscale) — the true minimum this engine can
        // produce — and report the achieved size honestly. If even this lands within
        // tolerance, `reachedTarget` will (correctly) be true.
        return try finalize(dpi: dpiFloor, quality: qualityFloor, grayscale: true)
    }

    /// Binary-search JPEG quality in `[floor, ceiling]` for the highest quality
    /// whose total encoded size is `<= budget`. Size is monotonic in quality, so
    /// bisection converges. The caller guarantees the floor quality fits the
    /// budget, so `best` starts at the floor and only ever improves.
    private static func searchQuality(cache: PageRenderCache,
                                      budget: Int,
                                      progress: ProgressHandler?,
                                      phaseFraction: Double,
                                      dpi: CGFloat,
                                      grayscale: Bool,
                                      cancellation: CancellationToken?) throws -> CGFloat {
        // First check the ceiling: if the whole doc fits at top quality, take it.
        let ceilSize = try cache.totalJPEGSize(quality: qualityCeiling,
                                               progress: progress,
                                               phaseFraction: phaseFraction,
                                               label: searchLabel(dpi: dpi, grayscale: grayscale),
                                               cancellation: cancellation)
        if ceilSize <= budget { return qualityCeiling }

        var low = qualityFloor      // caller proved the floor fits the budget
        var high = qualityCeiling   // known to exceed
        var best = low

        // ~8 iterations narrows quality to <0.004 — plenty precise for byte sizing.
        for _ in 0..<8 {
            try cancellation?.checkCancellation()
            let mid = (low + high) / 2
            let size = try cache.totalJPEGSize(quality: mid,
                                               progress: progress,
                                               phaseFraction: phaseFraction,
                                               label: searchLabel(dpi: dpi, grayscale: grayscale),
                                               cancellation: cancellation)
            if size <= budget {
                best = mid       // fits — try to spend more of the budget
                low = mid
            } else {
                high = mid       // too big — back off
            }
        }
        return best
    }

    private static func clamp(_ value: CGFloat, low: CGFloat, high: CGFloat) -> CGFloat {
        min(max(value, low), high)
    }

    // MARK: Final render pass

    /// Render every page at `dpi`/`grayscale`, JPEG-encode at `quality`, and
    /// rebuild the PDF. This is the single pass whose bytes become the output.
    private static func renderPass(document: CGPDFDocument,
                                   originalBytes: Int,
                                   dpi: CGFloat,
                                   quality: CGFloat,
                                   grayscale: Bool,
                                   reachedTarget: Bool,
                                   phase: String,
                                   progress: ProgressHandler?,
                                   cancellation: CancellationToken?) throws -> CompressionResult {
        let pageCount = document.numberOfPages
        var builderPages: [PDFBuilder.Page] = []
        builderPages.reserveCapacity(pageCount)

        for index in 0..<pageCount {
            try cancellation?.checkCancellation()
            guard let page = document.page(at: index + 1) else {
                throw ConversionError.renderFailed(pageIndex: index)
            }
            let effectiveDPI = clampedDPI(dpi, for: page)
            try autoreleasepoolThrowing {
                guard let bitmap = PDFPageRasterizer.render(page: page,
                                                            dpi: effectiveDPI,
                                                            grayscale: grayscale) else {
                    throw ConversionError.renderFailed(pageIndex: index)
                }
                let jpeg = try ImageEncoder.encodedData(image: bitmap,
                                                        format: .jpeg,
                                                        quality: quality)
                guard let embeddable = PDFBuilder.image(fromEncoded: jpeg) else {
                    throw ConversionError.renderFailed(pageIndex: index)
                }
                let boxPoints = CGRect(origin: .zero,
                                       size: PDFPageRasterizer.displaySize(of: page))
                builderPages.append(PDFBuilder.Page(image: embeddable, boxPoints: boxPoints))
            }
            progress?(ConversionProgress(
                fraction: Double(index + 1) / Double(pageCount),
                message: "\(phase)… page \(index + 1) of \(pageCount)"
            ))
        }

        let data = try PDFBuilder.makePDF(pages: builderPages)
        return CompressionResult(data: data,
                                 originalBytes: originalBytes,
                                 compressedBytes: data.count,
                                 reachedTarget: reachedTarget,
                                 usedDPI: dpi,
                                 usedQuality: quality,
                                 grayscale: grayscale,
                                 pageCount: pageCount)
    }

    // MARK: Helpers

    /// Reduce the requested DPI if it would blow past the per-page pixel cap.
    /// Shared by the render pass and the size-search cache so both agree on the
    /// effective resolution (otherwise the search's estimate wouldn't match the
    /// written file). `internal` so `PageRenderCache` can reuse it.
    static func clampedDPI(_ dpi: CGFloat, for page: CGPDFPage) -> CGFloat {
        let size = PDFPageRasterizer.displaySize(of: page)
        let longestEdgePoints = max(size.width, size.height)
        guard longestEdgePoints > 0 else { return dpi }
        let maxDPI = maxPagePixelEdge / (longestEdgePoints / 72.0)
        return min(dpi, maxDPI)
    }

    private static func searchLabel(dpi: CGFloat, grayscale: Bool) -> String {
        "Searching (\(Int(dpi)) DPI\(grayscale ? ", grayscale" : ""))"
    }
}

// MARK: - Page render cache

/// Renders a document's pages at a fixed DPI/color mode and measures JPEG sizes
/// at arbitrary qualities, without re-rasterizing on every quality probe when
/// memory allows caching the bitmaps.
///
/// Memory policy: if the estimated total bitmap size is within a budget, decoded
/// bitmaps are cached (fast repeated probes). Otherwise bitmaps are rendered on
/// demand and released immediately (bounded memory, at the cost of re-rendering
/// each probe). Either way peak memory stays sane on large documents.
private final class PageRenderCache {
    private let document: CGPDFDocument
    private let dpi: CGFloat
    private let grayscale: Bool
    private let pageCount: Int
    private var cache: [CGImage?]?

    /// Cache bitmaps only when their estimated footprint stays under this.
    private static let cacheBudgetBytes: Double = 800 * 1000 * 1000

    init(document: CGPDFDocument,
         dpi: CGFloat,
         grayscale: Bool,
         cancellation: CancellationToken?) throws {
        self.document = document
        self.dpi = dpi
        self.grayscale = grayscale
        self.pageCount = document.numberOfPages

        var estimated: Double = 0
        for index in 0..<pageCount {
            if let page = document.page(at: index + 1) {
                let size = PDFPageRasterizer.displaySize(of: page)
                let scale = dpi / 72.0
                let bytesPerPixel: Double = grayscale ? 1 : 4
                estimated += Double(size.width * scale) * Double(size.height * scale) * bytesPerPixel
            }
        }
        if estimated <= Self.cacheBudgetBytes {
            self.cache = Array(repeating: nil, count: pageCount)
        } else {
            self.cache = nil
        }
    }

    private func bitmap(at index: Int) throws -> CGImage {
        if let cached = cache?[index] { return cached }
        guard let page = document.page(at: index + 1),
              let image = PDFPageRasterizer.render(page: page,
                                                   dpi: CompressionEngine.clampedDPI(dpi, for: page),
                                                   grayscale: grayscale) else {
            throw ConversionError.renderFailed(pageIndex: index)
        }
        if cache != nil { cache?[index] = image }
        return image
    }

    /// Total bytes if every page were JPEG-encoded at `quality`.
    func totalJPEGSize(quality: CGFloat,
                       progress: ProgressHandler?,
                       phaseFraction: Double,
                       label: String,
                       cancellation: CancellationToken?) throws -> Int {
        var total = 0
        for index in 0..<pageCount {
            try cancellation?.checkCancellation()
            try autoreleasepoolThrowing {
                let image = try bitmap(at: index)
                total += try ImageEncoder.jpegByteCount(image: image, quality: quality)
            }
            progress?(ConversionProgress(
                fraction: phaseFraction,
                message: "\(label)… page \(index + 1) of \(pageCount)"
            ))
        }
        return total
    }
}

/// `autoreleasepool` that can rethrow — the standard `autoreleasepool` body is
/// `rethrows`, but wrapping it keeps call sites tidy and intent explicit.
@inline(__always)
private func autoreleasepoolThrowing(_ body: () throws -> Void) rethrows {
    try autoreleasepool { try body() }
}
