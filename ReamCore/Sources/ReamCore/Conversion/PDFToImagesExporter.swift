import Foundation
import CoreGraphics
import ImageIO

/// Exports PDF pages as raster images.
///
/// UI-free (CoreGraphics + ImageIO) so it lives in `ReamCore`. Produces either
/// one image per page or a "contact sheet" grid packing several pages per image.
public enum PDFToImagesExporter {

    /// Upper bound on a contact sheet's longest pixel edge, to keep a
    /// high-DPI × large-page × big-grid request from allocating a bitmap that
    /// exhausts memory. Cells scale down uniformly to fit.
    private static let maxContactSheetEdge: CGFloat = 8000

    /// One exported image ready to be written to disk.
    public struct OutputImage: Sendable {
        /// File name (including extension) — e.g. `"page-003.png"`.
        public let fileName: String
        public let data: Data
    }

    /// How to lay pages into output images.
    public enum Layout: Sendable, Equatable {
        /// One page per output image.
        case perPage
        /// `columns × rows` pages per output image (contact sheet).
        case contactSheet(columns: Int, rows: Int)
    }

    /// Render `pdfData`'s pages to images.
    ///
    /// - Parameters:
    ///   - pdfData: source PDF bytes.
    ///   - format: PNG / JPEG / TIFF (WebP if the OS ever gains an encoder).
    ///   - dpi: output resolution.
    ///   - quality: JPEG/WebP quality (`0...1`); ignored by lossless formats.
    ///   - layout: per-page or contact sheet.
    ///   - fileNameStem: base name for outputs (e.g. document title).
    public static func export(pdfData: Data,
                              format: ImageFormat,
                              dpi: CGFloat,
                              quality: CGFloat = 0.8,
                              layout: Layout = .perPage,
                              fileNameStem: String = "page",
                              progress: ProgressHandler? = nil,
                              cancellation: CancellationToken? = nil) throws -> [OutputImage] {
        guard format.isEncodable else {
            throw ConversionError.unsupportedExportFormat(format.displayName)
        }
        guard let provider = CGDataProvider(data: pdfData as CFData),
              let document = CGPDFDocument(provider) else {
            throw ConversionError.invalidPDF
        }
        let pageCount = document.numberOfPages
        guard pageCount > 0 else { throw ConversionError.emptyDocument }

        switch layout {
        case .perPage:
            return try exportPerPage(document: document, format: format, dpi: dpi,
                                     quality: quality, stem: fileNameStem,
                                     progress: progress, cancellation: cancellation)
        case .contactSheet(let cols, let rows):
            return try exportContactSheet(document: document, format: format, dpi: dpi,
                                          quality: quality,
                                          columns: max(1, cols), rows: max(1, rows),
                                          stem: fileNameStem,
                                          progress: progress, cancellation: cancellation)
        }
    }

    // MARK: Per-page

    private static func exportPerPage(document: CGPDFDocument,
                                      format: ImageFormat,
                                      dpi: CGFloat,
                                      quality: CGFloat,
                                      stem: String,
                                      progress: ProgressHandler?,
                                      cancellation: CancellationToken?) throws -> [OutputImage] {
        let pageCount = document.numberOfPages
        var outputs: [OutputImage] = []
        outputs.reserveCapacity(pageCount)
        let width = numberWidth(pageCount)

        for index in 0..<pageCount {
            try cancellation?.checkCancellation()
            try autoreleasepool {
                guard let page = document.page(at: index + 1),
                      let image = PDFPageRasterizer.render(page: page, dpi: dpi) else {
                    throw ConversionError.renderFailed(pageIndex: index)
                }
                let data = try ImageEncoder.encodedData(image: image, format: format,
                                                        quality: quality, dpi: dpi)
                let number = String(format: "%0\(width)d", index + 1)
                outputs.append(OutputImage(fileName: "\(stem)-\(number).\(format.fileExtension)",
                                           data: data))
            }
            progress?(ConversionProgress(
                fraction: Double(index + 1) / Double(pageCount),
                message: "Exporting page \(index + 1) of \(pageCount)…"
            ))
        }
        return outputs
    }

    // MARK: Contact sheet

    private static func exportContactSheet(document: CGPDFDocument,
                                           format: ImageFormat,
                                           dpi: CGFloat,
                                           quality: CGFloat,
                                           columns: Int,
                                           rows: Int,
                                           stem: String,
                                           progress: ProgressHandler?,
                                           cancellation: CancellationToken?) throws -> [OutputImage] {
        let pageCount = document.numberOfPages
        let perSheet = columns * rows
        let sheetCount = (pageCount + perSheet - 1) / perSheet
        var outputs: [OutputImage] = []
        outputs.reserveCapacity(sheetCount)
        let sheetWidth = numberWidth(sheetCount)

        // Fixed cell size derived from the first page at the requested DPI, so all
        // cells align. Pages are aspect-fit within their cell.
        let firstSize = document.page(at: 1).map { PDFPageRasterizer.displaySize(of: $0) }
            ?? CGSize(width: 612, height: 792)

        // Cap the whole sheet's pixel dimensions so a high DPI × big page × large
        // grid can't allocate a multi-gigabyte bitmap (OOM). Scale the cells down
        // uniformly if the requested DPI would exceed the cap.
        let requestedScale = dpi / 72.0
        let approxWidth = CGFloat(columns) * firstSize.width * requestedScale
        let approxHeight = CGFloat(rows) * firstSize.height * requestedScale
        let longestEdge = max(approxWidth, approxHeight)
        let scale = longestEdge > maxContactSheetEdge
            ? requestedScale * (maxContactSheetEdge / longestEdge)
            : requestedScale

        let cellW = max(1, Int((firstSize.width * scale).rounded()))
        let cellH = max(1, Int((firstSize.height * scale).rounded()))
        let padding = max(8, Int((0.08 * CGFloat(min(cellW, cellH))).rounded()))

        let sheetPxW = columns * cellW + (columns + 1) * padding
        let sheetPxH = rows * cellH + (rows + 1) * padding

        for sheetIndex in 0..<sheetCount {
            try cancellation?.checkCancellation()
            try autoreleasepool {
                guard let ctx = CGContext(data: nil, width: sheetPxW, height: sheetPxH,
                                          bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
                    throw ConversionError.renderFailed(pageIndex: sheetIndex * perSheet)
                }
                ctx.interpolationQuality = .high
                ctx.setFillColor(gray: 0.93, alpha: 1)
                ctx.fill(CGRect(x: 0, y: 0, width: sheetPxW, height: sheetPxH))

                for cell in 0..<perSheet {
                    let pageIndex = sheetIndex * perSheet + cell
                    guard pageIndex < pageCount,
                          let page = document.page(at: pageIndex + 1),
                          let image = PDFPageRasterizer.render(page: page, dpi: dpi) else {
                        continue
                    }
                    // Grid position: fill left-to-right, top-to-bottom. CG origin
                    // is bottom-left, so invert the row.
                    let col = cell % columns
                    let row = cell / columns
                    let cellX = padding + col * (cellW + padding)
                    let cellYFromTop = padding + row * (cellH + padding)
                    let cellY = sheetPxH - cellYFromTop - cellH
                    let cellRect = CGRect(x: cellX, y: cellY, width: cellW, height: cellH)
                    // White card behind each page.
                    ctx.setFillColor(gray: 1, alpha: 1)
                    ctx.fill(cellRect)
                    let fitted = aspectFit(size: CGSize(width: image.width, height: image.height),
                                           into: cellRect)
                    ctx.draw(image, in: fitted)
                }

                guard let sheet = ctx.makeImage() else {
                    throw ConversionError.renderFailed(pageIndex: sheetIndex * perSheet)
                }
                let data = try ImageEncoder.encodedData(image: sheet, format: format,
                                                        quality: quality, dpi: dpi)
                let number = String(format: "%0\(sheetWidth)d", sheetIndex + 1)
                outputs.append(OutputImage(fileName: "\(stem)-sheet-\(number).\(format.fileExtension)",
                                           data: data))
            }
            progress?(ConversionProgress(
                fraction: Double(sheetIndex + 1) / Double(sheetCount),
                message: "Building contact sheet \(sheetIndex + 1) of \(sheetCount)…"
            ))
        }
        return outputs
    }

    // MARK: Helpers

    private static func aspectFit(size: CGSize, into bounds: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return bounds }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let width = size.width * scale
        let height = size.height * scale
        return CGRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2,
                      width: width, height: height)
    }

    /// Zero-pad width so file names sort correctly (e.g. 3 → "page-003").
    private static func numberWidth(_ count: Int) -> Int {
        max(2, String(count).count)
    }
}
