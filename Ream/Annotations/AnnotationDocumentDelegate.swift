import PDFKit

/// Installed as the `PDFDocument.delegate` so that when a saved file is
/// re-opened, the non-native subtypes Ream draws itself (`Squiggly`, `Polygon`,
/// `PolyLine`) come back as their editable ``PDFAnnotation`` subclasses instead
/// of inert base annotations. Everything else uses PDFKit's default class.
///
/// PDFKit only consults this for annotations parsed *after* the delegate is set,
/// so ``PDFReferenceDocument`` installs it at load time.
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
}
