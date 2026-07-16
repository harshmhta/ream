import Foundation
import PDFKit

/// Reads the catalog XMP (`/Metadata`) stream for the Document Properties
/// "advanced" disclosure, presenting it as a raw string plus a best-effort list
/// of key/value pairs.
///
/// v0.1 scope: **show** XMP if present and let the user strip it. PDFKit exposes
/// no XMP-write API (only the Info dictionary via `documentAttributes`), so
/// editing arbitrary XMP keys is deferred; the standard fields (title/author/…)
/// remain editable through the Info dictionary, which most viewers mirror.
enum PDFXMPService {

    struct XMPEntry: Identifiable, Equatable {
        let key: String
        let value: String
        var id: String { key }
    }

    /// The raw XMP packet, if the document has a catalog `/Metadata` stream.
    static func rawXMP(from document: PDFDocument) -> String? {
        guard let data = document.dataRepresentation() else { return nil }
        return rawXMP(fromData: data)
    }

    /// Read the XMP packet directly from PDF bytes via CoreGraphics.
    static func rawXMP(fromData data: Data) -> String? {
        guard let provider = CGDataProvider(data: data as CFData),
              let doc = CGPDFDocument(provider),
              let catalog = doc.catalog else { return nil }

        var streamRef: CGPDFStreamRef?
        guard CGPDFDictionaryGetStream(catalog, "Metadata", &streamRef),
              let stream = streamRef else { return nil }

        var format = CGPDFDataFormat.raw
        guard let cfData = CGPDFStreamCopyData(stream, &format) else { return nil }
        let xmpData = cfData as Data
        guard !xmpData.isEmpty else { return nil }
        return String(decoding: xmpData, as: UTF8.self)
    }

    /// Best-effort parse of common XMP properties into key/value pairs for
    /// display. Handles both simple (`<ns:Prop>value</ns:Prop>`) and container
    /// (`rdf:li`) forms of the widely used Dublin Core / XMP Basic / PDF schemas.
    static func entries(from document: PDFDocument) -> [XMPEntry] {
        guard let xmp = rawXMP(from: document) else { return [] }
        return entries(fromXMP: xmp)
    }

    static func entries(fromXMP xmp: String) -> [XMPEntry] {
        // The handful of properties worth surfacing without a full RDF parser.
        // For each, capture the first text run inside the element (covering both
        // literal values and rdf:li wrapped values).
        let properties: [(label: String, tag: String)] = [
            ("Title", "dc:title"),
            ("Creator", "dc:creator"),
            ("Description", "dc:description"),
            ("Subject", "dc:subject"),
            ("Rights", "dc:rights"),
            ("Producer", "pdf:Producer"),
            ("Keywords", "pdf:Keywords"),
            ("Creator Tool", "xmp:CreatorTool"),
            ("Create Date", "xmp:CreateDate"),
            ("Modify Date", "xmp:ModifyDate"),
            ("Metadata Date", "xmp:MetadataDate"),
        ]

        var result: [XMPEntry] = []
        for property in properties {
            if let value = firstValue(for: property.tag, in: xmp) {
                result.append(XMPEntry(key: property.label, value: value))
            }
        }
        return result
    }

    /// Extract the innermost text content for `<tag …>…</tag>`, stripping any
    /// nested RDF container elements (`rdf:Alt/Seq/Bag/li`) and whitespace.
    private static func firstValue(for tag: String, in xmp: String) -> String? {
        guard let open = xmp.range(of: "<\(tag)"),
              let contentStart = xmp.range(of: ">", range: open.upperBound..<xmp.endIndex),
              let close = xmp.range(of: "</\(tag)>", range: contentStart.upperBound..<xmp.endIndex)
        else { return nil }

        let inner = String(xmp[contentStart.upperBound..<close.lowerBound])
        // Strip any XML tags (rdf:Alt, rdf:Seq, rdf:li, …) leaving text content.
        let stripped = inner.replacingOccurrences(
            of: "<[^>]+>", with: " ", options: .regularExpression
        )
        let collapsed = stripped
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? nil : collapsed
    }
}
