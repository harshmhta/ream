import Foundation
import CoreGraphics

/// Per-document reading state that should survive closing and reopening a file:
/// the reading position (page + normalized scroll point + zoom), the layout
/// mode, and whether dark-content inversion was on.
struct DocumentReadingState: Codable, Equatable {
    var pageIndex: Int = 0
    /// Scroll offset within the page, in PDF points, of the top-left visible
    /// point. Stored so we can restore mid-page positions, not just page tops.
    var scrollPointX: CGFloat = 0
    var scrollPointY: CGFloat = 0
    var scaleFactor: CGFloat = 1
    var autoScales: Bool = true
    var viewModeRaw: Int = ViewMode.continuous.rawValue
    var invertContent: Bool = false
}

/// Persists ``DocumentReadingState`` keyed by document identity.
///
/// Keyed by a stable string (the file's absolute path) rather than a
/// security-scoped bookmark: this is convenience state, and losing it when a
/// file moves is acceptable. The last-session list of open documents lives in
/// ``SessionStore``; this store is purely "where was I in *this* file".
final class DocumentPreferencesStore {
    static let shared = DocumentPreferencesStore()

    private let defaults: UserDefaults
    private let keyPrefix = "com.ream.doc.readingState."

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func readingState(for key: String) -> DocumentReadingState? {
        guard let data = defaults.data(forKey: keyPrefix + key) else { return nil }
        return try? JSONDecoder().decode(DocumentReadingState.self, from: data)
    }

    func setReadingState(_ state: DocumentReadingState, for key: String) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: keyPrefix + key)
    }
}
