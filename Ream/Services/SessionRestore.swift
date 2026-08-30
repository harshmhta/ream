import Foundation

/// Decides what "reopen last session" should do with the documents resolved from
/// the previous session's bookmarks.
///
/// This is the part of session restore worth reasoning about carefully, so it
/// lives here as a pure function rather than inline in ``AppDelegate``:
///
/// - **Every resolved URL owns a started security scope.** Resolving a
///   security-scoped bookmark starts access; whoever resolves it must balance
///   that. A URL we decide *not* to open still has to be released, or the process
///   leaks a sandbox extension per already-restored document on every launch.
/// - **macOS restores windows asynchronously**, and the user may have opened a
///   document from Finder while we were starting. Anything already on screen must
///   be skipped or the session reopens it a second time.
/// - The same file can appear twice (two bookmarks, `/tmp` vs `/private/tmp`, a
///   path with `..` in it), so comparison is by canonical path and duplicates
///   within the session collapse to one.
enum SessionRestore {

    /// What to do with the session's URLs: open these, release those.
    struct Plan: Equatable {
        /// Documents to open, in session order. Their security scope is handed to
        /// the open call and released when it completes.
        let open: [URL]
        /// Documents that must have their security scope released *without* being
        /// opened, because a window for them already exists (or they are
        /// duplicates of one earlier in the list).
        let release: [URL]
    }

    /// Split `sessionURLs` into the ones to open and the ones to release.
    ///
    /// - Parameters:
    ///   - sessionURLs: URLs resolved from the session bookmarks, in session
    ///     order. Each is assumed to hold a started security scope.
    ///   - alreadyOpen: canonical paths of documents already on screen — build it
    ///     with ``canonicalPath(_:)`` so both sides compare the same way.
    static func plan(sessionURLs: [URL], alreadyOpen: Set<String>) -> Plan {
        var open: [URL] = []
        var release: [URL] = []
        var seen = alreadyOpen

        for url in sessionURLs {
            let path = canonicalPath(url)
            if seen.contains(path) {
                release.append(url)
            } else {
                seen.insert(path)
                open.append(url)
            }
        }
        return Plan(open: open, release: release)
    }

    /// The path used to compare two URLs for "is this the same document".
    ///
    /// Resolves symlinks *and* standardizes: `.`/`..` segments collapse, and for
    /// a file that exists the `/private` prefix normalises away, so
    /// `/private/tmp/x.pdf` and `/tmp/x.pdf` compare equal. (Standardization
    /// alone does not do the `/private` half — Foundation only applies it after
    /// touching the filesystem, which `resolvingSymlinksInPath()` does.)
    static func canonicalPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }
}
