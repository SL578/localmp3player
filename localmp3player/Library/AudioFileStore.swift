import Foundation

/// Owns the app's copy of every imported file. `Song.filePath` is always relative
/// to the Documents directory so the sandbox container can move between installs.
///
/// Importing is two-phase on purpose. The document picker hands back files in a
/// temporary Inbox that iOS reclaims on its own schedule — within a couple of
/// minutes, whether or not the app is still using them. Since the review sheet is
/// designed to be sat on (renaming, tagging, answering duplicate prompts), the
/// bytes are copied into `Staging/` the moment they are picked, and only *moved*
/// into `Audio/` once the user commits. Nothing in the commit path touches a URL
/// the system owns.
enum AudioFileStore {
    enum StoreError: Error {
        case copyFailed(underlying: Error)
        case promoteFailed(underlying: Error)
    }

    static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var audioDirectory: URL { directory(named: "Audio") }

    /// Holds picked files between the document picker and a committed import.
    static var stagingDirectory: URL { directory(named: "Staging") }

    static func absoluteURL(for relativePath: String) -> URL {
        documentsDirectory.appendingPathComponent(relativePath)
    }

    // MARK: - Staging

    /// Copies a picked file out of the system's temporary Inbox immediately, while
    /// the URL is still guaranteed valid, and returns its Documents-relative path.
    static func stageFile(at source: URL) throws -> (stagedPath: String, fileSize: Int64) {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        let destination = uniqueDestination(for: source.lastPathComponent, in: stagingDirectory)
        do {
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            throw StoreError.copyFailed(underlying: error)
        }
        let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ("Staging/" + destination.lastPathComponent, Int64(size))
    }

    /// Moves a staged file into permanent storage. A move on the same volume, so
    /// this is atomic and cannot half-succeed the way a re-copy could.
    static func promote(stagedPath: String) throws -> String {
        let source = absoluteURL(for: stagedPath)
        let destination = uniqueDestination(for: source.lastPathComponent, in: audioDirectory)
        do {
            try FileManager.default.moveItem(at: source, to: destination)
        } catch {
            throw StoreError.promoteFailed(underlying: error)
        }
        return "Audio/" + destination.lastPathComponent
    }

    static func discardStaged(_ relativePath: String) {
        guard relativePath.hasPrefix("Staging/") else { return }
        try? FileManager.default.removeItem(at: absoluteURL(for: relativePath))
    }

    /// Clears anything left behind by an import the app never got to finish —
    /// called once at launch, before any new file can be staged.
    static func clearStaging() {
        let directory = stagingDirectory
        let contents = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for url in contents {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Permanent storage

    static func delete(relativePath: String) {
        try? FileManager.default.removeItem(at: absoluteURL(for: relativePath))
    }

    // MARK: - Helpers

    private static func directory(named name: String) -> URL {
        let directory = documentsDirectory.appendingPathComponent(name, isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    private static func uniqueDestination(for filename: String, in directory: URL) -> URL {
        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var candidate = directory.appendingPathComponent(filename)
        var counter = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(base)-\(counter)" : "\(base)-\(counter).\(ext)"
            candidate = directory.appendingPathComponent(name)
            counter += 1
        }
        return candidate
    }
}
