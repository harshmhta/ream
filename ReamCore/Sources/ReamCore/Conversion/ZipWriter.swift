import Foundation

/// Bundles files into a single `.zip` using `NSFileCoordinator`'s
/// `.forUploading` option — the system's built-in, dependency-free, sandbox-safe
/// zip path (the same one Finder's "Compress" uses).
public enum ZipWriter {

    /// A file to place inside the archive.
    public struct Entry: Sendable {
        public let fileName: String
        public let data: Data
        public init(fileName: String, data: Data) {
            self.fileName = fileName
            self.data = data
        }
    }

    /// Write `entries` into a zip at `destinationURL`.
    ///
    /// Materializes the entries into a temporary staging directory, asks
    /// `NSFileCoordinator` to produce an archive of it, and copies the result to
    /// `destinationURL`. The staging directory is removed afterward.
    ///
    /// - Parameter folderName: the name of the single top-level folder the archive
    ///   expands to. `NSFileCoordinator`'s `.forUploading` zips the *directory*,
    ///   so this controls what the user sees after unzipping (defaults to a
    ///   friendly name rather than the internal UUID staging path).
    public static func write(entries: [Entry], to destinationURL: URL,
                             folderName: String = "Images") throws {
        let fm = FileManager.default
        let stagingRoot = fm.temporaryDirectory
            .appendingPathComponent("ream-zip-\(UUID().uuidString)", isDirectory: true)
        // The archived folder is a *named* child of the staging root, so the zip
        // expands to `<folderName>/…`, not `ream-zip-<uuid>/…`.
        let cleanFolder = FileNaming.sanitized(folderName, fallback: "Images")
        let staging = stagingRoot.appendingPathComponent(cleanFolder, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stagingRoot) }

        var used = Set<String>()
        for entry in entries {
            let safe = FileNaming.unique(FileNaming.sanitized(entry.fileName), in: &used)
            let fileURL = staging.appendingPathComponent(safe)
            try entry.data.write(to: fileURL, options: .atomic)
        }

        var coordinatorError: NSError?
        var copyError: Error?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(readingItemAt: staging,
                               options: [.forUploading],
                               error: &coordinatorError) { zipURL in
            do {
                if fm.fileExists(atPath: destinationURL.path) {
                    try fm.removeItem(at: destinationURL)
                }
                try fm.copyItem(at: zipURL, to: destinationURL)
            } catch {
                copyError = error
            }
        }

        if let coordinatorError {
            throw ConversionError.cannotCreateOutput(coordinatorError.localizedDescription)
        }
        if copyError != nil {
            throw ConversionError.cannotCreateOutput(destinationURL.path)
        }
    }
}
