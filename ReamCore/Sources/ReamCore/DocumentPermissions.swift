import Foundation

/// The four permission flags Ream exposes when encrypting a PDF with an owner
/// (permissions) password, per the v0.1 scope: allow print / copy / edit /
/// annotate.
///
/// This is a UI-free `OptionSet` living in the portable core; the app maps it
/// onto PDFKit's `PDFAccessPermissions` bitmask at write time. Keeping it here
/// (rather than importing PDFKit) preserves the "no UI frameworks in ReamCore"
/// contract and lets the future CLI reuse the same vocabulary.
public struct DocumentPermissions: OptionSet, Sendable, Equatable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Allow printing the document.
    public static let print = DocumentPermissions(rawValue: 1 << 0)
    /// Allow copying / extracting content (text, images).
    public static let copy = DocumentPermissions(rawValue: 1 << 1)
    /// Allow modifying the document contents.
    public static let edit = DocumentPermissions(rawValue: 1 << 2)
    /// Allow creating / modifying annotations and form fields.
    public static let annotate = DocumentPermissions(rawValue: 1 << 3)

    /// Grant everything — the default for a freshly encrypted file where the
    /// user only set an open password.
    public static let all: DocumentPermissions = [.print, .copy, .edit, .annotate]
    /// Grant nothing.
    public static let none: DocumentPermissions = []
}

/// The complete set of security choices for an encrypt operation.
///
/// Passwords are carried as plain values here only long enough to perform the
/// write — the app never persists them (the "store nothing" rule). At least one
/// of `userPassword` / `ownerPassword` must be non-empty for encryption to mean
/// anything; permission flags only take effect when an owner password is set.
public struct EncryptionSettings: Equatable, Sendable {
    /// Open password: required to open/view the document. `nil` = no open password.
    public var userPassword: String?
    /// Permissions (owner) password: required to change permissions. `nil` = none.
    public var ownerPassword: String?
    /// Which actions remain allowed once opened with the user password.
    public var permissions: DocumentPermissions

    public init(
        userPassword: String? = nil,
        ownerPassword: String? = nil,
        permissions: DocumentPermissions = .all
    ) {
        self.userPassword = userPassword
        self.ownerPassword = ownerPassword
        self.permissions = permissions
    }

    /// Normalize empty strings to `nil` so callers can pass raw text-field values.
    public var normalized: EncryptionSettings {
        func clean(_ s: String?) -> String? {
            guard let s, !s.isEmpty else { return nil }
            return s
        }
        return EncryptionSettings(
            userPassword: clean(userPassword),
            ownerPassword: clean(ownerPassword),
            permissions: permissions
        )
    }

    /// True when at least one password is set (encryption is meaningful).
    public var hasAnyPassword: Bool {
        let n = normalized
        return n.userPassword != nil || n.ownerPassword != nil
    }

    /// Whether every set password is representable in ASCII.
    ///
    /// The native PDF writer (`CGPDFContext`) requires ASCII passwords — a
    /// non-ASCII password (accents, emoji) causes the encrypted write to fail
    /// and return no data. Callers should validate this *before* staging
    /// encryption so the failure surfaces at the point of entry rather than
    /// confusingly at save time.
    public var passwordsAreASCII: Bool {
        func isASCII(_ s: String?) -> Bool {
            guard let s else { return true }
            return s.canBeConverted(to: .ascii)
        }
        return isASCII(userPassword) && isASCII(ownerPassword)
    }
}
