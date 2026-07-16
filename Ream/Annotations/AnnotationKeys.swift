import PDFKit
import Foundation

/// Ream-private annotation dictionary keys.
///
/// PDFKit round-trips arbitrary `/Ream_*` keys through `dataRepresentation()`
/// unchanged (verified against macOS PDFKit), whereas the spec-standard `/NM`
/// name key is dropped on save. So Ream stores its own stable identity,
/// threading, and review-state metadata under these custom keys. They are
/// ignored by other PDF readers but survive a Ream save/load cycle, which is
/// what threaded replies and resolve state need.
enum ReamAnnotationKey {
    /// Stable per-annotation identifier (a UUID string). Used to link replies
    /// to their parent and to address annotations from the inspector list.
    static let id = PDFAnnotationKey(rawValue: "/Ream_ID")

    /// The `id` of the annotation this one replies to (threading). Absent on
    /// top-level annotations.
    static let inReplyTo = PDFAnnotationKey(rawValue: "/Ream_IRT")

    /// Review resolve state — `"true"` when the thread is marked resolved.
    static let resolved = PDFAnnotationKey(rawValue: "/Ream_Resolved")

    /// Geometry payload for annotation subtypes PDFKit cannot render natively
    /// (Squiggly, Polygon, PolyLine). Comma-separated page-space floats.
    static let vertices = PDFAnnotationKey(rawValue: "/Ream_Vertices")

    /// Callout connector knee/end points, comma-separated page-space floats.
    static let calloutLine = PDFAnnotationKey(rawValue: "/Ream_Callout")
}

extension PDFAnnotation {
    /// The annotation's stable Ream id, minting and persisting one on first
    /// access so every annotation Ream creates or touches is addressable.
    var reamID: String {
        if let existing = value(forAnnotationKey: ReamAnnotationKey.id) as? String,
           !existing.isEmpty {
            return existing
        }
        let fresh = UUID().uuidString
        setValue(fresh, forAnnotationKey: ReamAnnotationKey.id)
        return fresh
    }

    /// Read the stored id without minting a new one (nil if never set).
    var storedReamID: String? {
        value(forAnnotationKey: ReamAnnotationKey.id) as? String
    }

    /// The id of the annotation this one replies to, if any.
    var reamInReplyTo: String? {
        get { value(forAnnotationKey: ReamAnnotationKey.inReplyTo) as? String }
        set {
            if let newValue {
                setValue(newValue, forAnnotationKey: ReamAnnotationKey.inReplyTo)
            } else {
                removeValue(forAnnotationKey: ReamAnnotationKey.inReplyTo)
            }
        }
    }

    /// Whether this annotation (or its thread) is marked resolved.
    var reamResolved: Bool {
        get { (value(forAnnotationKey: ReamAnnotationKey.resolved) as? String) == "true" }
        set { setValue(newValue ? "true" : "false", forAnnotationKey: ReamAnnotationKey.resolved) }
    }

    /// A `Popup` annotation is PDFKit's own bookkeeping companion for `Text`
    /// notes — it should never appear in the inspector or annotation counts.
    var isReamListable: Bool {
        (type ?? "") != PDFAnnotationSubtype.popup.rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            && (type ?? "") != "Popup"
    }
}
