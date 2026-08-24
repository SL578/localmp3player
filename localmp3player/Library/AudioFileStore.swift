import Foundation

/// Owns the app's copy of every imported file. `Song.filePath` is always relative
/// to the audio directory so the sandbox container can move between installs.
enum AudioFileStore {
    enum StoreError: Error {
        case couldNotAccessSource
        case copyFailed(underlying: Error)
    }

    static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var audioDirectory: URL {
        let directory = documentsDirectory.appendingPathComponent("Audio", isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    static func absoluteURL(for relativePath: String) -> URL {
        documentsDirectory.appendingPathComponent(relativePath)
    }

    /// Copies a picked file into app storage and returns its Documents-relative path.
    static func importFile(at source: URL) throws -> (relativePath: String, fileSize: Int64) {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        let destination = uniqueDestination(for: source.lastPathComponent)
        do {
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            throw StoreError.copyFailed(underlying: error)
        }
        let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ("Audio/" + destination.lastPathComponent, Int64(size))
    }

    static func delete(relativePath: String) {
        try? FileManager.default.removeItem(at: absoluteURL(for: relativePath))
    }

    private static func uniqueDestination(for filename: String) -> URL {
        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var candidate = audioDirectory.appendingPathComponent(filename)
        var counter = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(base)-\(counter)" : "\(base)-\(counter).\(ext)"
            candidate = audioDirectory.appendingPathComponent(name)
            counter += 1
        }
        return candidate
    }
}
