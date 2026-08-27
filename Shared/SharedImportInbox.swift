import Foundation

/// The hand-off between the share extension and the app.
///
/// An extension cannot hand files to its app directly, so it copies what was
/// shared into a folder both can reach — the App Group container — and opens the
/// app, which drains it. Compiled into both targets, so there is one definition
/// of where that folder is and what the app is opened with.
///
/// This exists because the "Open in Local Player" route a document-types app
/// gets is a *single*-document channel: iOS hands over exactly one URL however
/// many files were shared, which is why sharing four songs imported one. A share
/// extension is the only way to be offered the whole selection.
enum SharedImportInbox {
    static let appGroup = "group.com.lin.localmp3player"

    /// Opening this brings the app forward and makes it look in the inbox. It
    /// carries no payload — the files are already here.
    static let openURL = URL(string: "localplayer://import")!

    /// Nil only when the App Group entitlement is missing or misspelled, which
    /// is a build configuration problem rather than a runtime one.
    static var directory: URL? {
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup) else { return nil }
        let directory = container.appendingPathComponent("SharedInbox", isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    /// Everything waiting to be imported.
    static func pendingFiles() -> [URL] {
        guard let directory else { return [] }
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Copies a shared file in under a name nothing else is using.
    ///
    /// The original filename is kept wherever it can be: it is what
    /// `FilenameParser` reads when a file's own tags are missing or are a video
    /// title, so a name mangled here costs the import its title and artist.
    @discardableResult
    static func accept(contentsOf source: URL, named filename: String) -> URL? {
        guard let directory else { return nil }
        let destination = uniqueDestination(for: filename, in: directory)
        do {
            try FileManager.default.copyItem(at: source, to: destination)
            return destination
        } catch {
            return nil
        }
    }

}

/// A filename in `directory` that nothing is using yet, keeping as much of the
/// original name as it can. Shared because both inboxes and the permanent store
/// need the same answer, and two copies of it drifted once already.
func uniqueDestination(for filename: String, in directory: URL) -> URL {
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
