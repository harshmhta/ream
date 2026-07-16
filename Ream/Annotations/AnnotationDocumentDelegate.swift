import PDFKit

/// The single `PDFDocument.delegate` Ream installs on every document. A
/// `PDFDocument` has exactly one delegate, so this one object carries both
/// features that need delegate callbacks:
///
/// - `class(forAnnotationType:)` — so that when a saved file is re-opened, the
///   non-native subtypes Ream draws itself (`Squiggly`, `Polygon`, `PolyLine`)
///   come back as their editable ``PDFAnnotation`` subclasses instead of inert
///   base annotations.
/// - `classForPage()` — so pages are instantiated as ``InvertingPDFPage``, which
///   powers content-aware dark mode. Inversion is off by default, so this is
///   invisible until the user enables it.
///
/// PDFKit only consults the annotation callback for annotations parsed *after*
/// the delegate is set, so ``PDFReferenceDocument`` installs it at load time.
final class AnnotationDocumentDelegate: NSObject, PDFDocumentDelegate {
    static let shared = AnnotationDocumentDelegate()

    func `class`(forAnnotationType annotationType: String) -> AnyClass {
        switch annotationType {
        case "Squiggly":
            return SquigglyAnnotation.self
        case "Polygon", "PolyLine":
            return PolyShapeAnnotation.self
        default:
            return PDFAnnotation.self
        }
    }

    func classForPage() -> AnyClass {
        InvertingPDFPage.self
    }
}
