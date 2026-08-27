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

    /// Where iOS drops files handed to the app from outside it. Created by the
    /// system, not by us, so it is read without being made first.
    static var inboxDirectory: URL {
        documentsDirectory.appendingPathComponent("Inbox", isDirectory: true)
    }

    /// Everything currently sitting in the system's drop box for this app.
    ///
    /// Sharing several files at once puts *all* of them here, but the app is only
    /// told about them through `onOpenURL`, which does not reliably deliver one
    /// callback per file — share four songs and one URL arrives. Reading the
    /// directory is the only account of the whole batch that doesn't depend on
    /// how many callbacks the system decided to make.
    static func pendingInboxFiles() -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: inboxDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents.filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
    }

    static func absoluteURL(for relativePath: String) -> URL {
        documentsDirectory.appendingPathComponent(relativePath)
    }

    // MARK: - Staging

    /// Where a URL handed to the app came from, which decides whether the app is
    /// allowed to delete it once its bytes are safely copied.
    ///
    /// This used to be assumed rather than asked. Every incoming URL came from
    /// the document picker in `asCopy: true` mode, so every incoming URL was a
    /// throwaway copy and deleting it unconditionally was right. Accepting files
    /// shared in from other apps broke that assumption: with
    /// `LSSupportsOpeningDocumentsInPlace`, a file shared from Files arrives as
    /// a reference to the user's actual document, and the same line of code
    /// would have deleted the original off their device.
    enum Origin {
        /// A copy the system made for the app — the picker's temporary copy, or
        /// the `Documents/Inbox` drop a share creates. Nobody else will ever
        /// look at it again.
        case systemCopy
        /// A file that still belongs to the user somewhere else on the device.
        /// Read it, never touch it.
        case userFile

        /// Only locations this app or the system made for it are treated as
        /// disposable. Anything else is the user's.
        static func of(_ url: URL) -> Origin {
            let path = url.standardizedFileURL.path
            var disposable = [
                inboxDirectory.standardizedFileURL.path,
                FileManager.default.temporaryDirectory.standardizedFileURL.path,
            ]
            // The share extension's copies. They exist only to be handed over,
            // and nothing reads them again once they are staged.
            if let shared = SharedImportInbox.directory {
                disposable.append(shared.standardizedFileURL.path)
            }
            return disposable.contains(where: path.hasPrefix) ? .systemCopy : .userFile
        }
    }

    /// Copies an incoming file out of wherever the system put it, while the URL
    /// is still guaranteed valid, and returns its Documents-relative path.
    static func stageFile(at source: URL) throws -> (stagedPath: String, fileSize: Int64) {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        let destination = uniqueDestination(for: source.lastPathComponent, in: stagingDirectory)
        do {
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            throw StoreError.copyFailed(underlying: error)
        }
        // Clear the system's copy now that we own one of our own, rather than
        // waiting on the ~2 minute reclaim. Left in place, a second pick of the
        // *same* source file before that reclaim ran found the old copy still
        // there and avoided the name collision by renaming the new one to
        // "<name> 2.mp3" — which the parser correctly read as a different title,
        // so re-importing the same file back-to-back silently produced a new
        // "duplicate" instead of matching the existing song.
        if Origin.of(source) == .systemCopy {
            try? FileManager.default.removeItem(at: source)
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
}
