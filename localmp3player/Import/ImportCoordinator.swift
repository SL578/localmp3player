import Combine
import CoreData
import Foundation
import SwiftUI

/// One file staged for import. Everything here is editable in the review sheet
/// before it becomes a `Song`.
struct ImportDraft: Identifiable {
    let id = UUID()
    /// Documents-relative path inside `Staging/`. The picked URL is deliberately
    /// not kept: it points into a system Inbox that is reclaimed out from under us.
    var stagedPath: String
    var fileSize: Int64
    var originalFilename: String
    var title: String
    var artist: String
    var album: String?
    var duration: Double
    var artworkData: Data?
    var tagNames: [String] = []
    var metadataSource: MetadataSource

    enum MetadataSource {
        case embedded
        case filename
        case mixed

        var label: String {
            switch self {
            case .embedded: return "From file tags"
            case .filename: return "From filename"
            case .mixed: return "Tags + filename"
            }
        }
    }

    var normalizedKey: String { NormalizedKey.make(title: title, artist: artist) }
}

struct DuplicateDecision {
    enum Choice { case replace, keepBoth, cancelImport }
    var choice: Choice
    var applyToRest: Bool

    static let cancel = DuplicateDecision(choice: .cancelImport, applyToRest: false)
}

@MainActor
final class ImportCoordinator: ObservableObject {
    enum Phase: Equatable {
        case idle
        case scanning(completed: Int, total: Int)
        case reviewing
    }

    @Published private(set) var phase: Phase = .idle
    @Published var drafts: [ImportDraft] = []
    @Published var pendingDuplicate: (draft: ImportDraft, existing: Song)?
    @Published var lastImportSummary: String?
    /// Files the picker handed over that could not be copied into app storage.
    private var stagingFailureCount = 0

    private let context: NSManagedObjectContext
    private var batchReplaceAll = false
    private var batchKeepAll = false
    private var duplicateContinuation: CheckedContinuation<DuplicateDecision, Never>?

    init(context: NSManagedObjectContext) {
        self.context = context
    }

    var isPresentingReview: Bool { phase == .reviewing }

    // MARK: - Stage

    func stage(urls: [URL]) async {
        guard !urls.isEmpty else { return }
        batchReplaceAll = false
        batchKeepAll = false
        discardAllStaged()
        drafts = []
        phase = .scanning(completed: 0, total: urls.count)

        var staged: [ImportDraft] = []
        var failed = 0
        for (index, url) in urls.enumerated() {
            if let draft = await makeDraft(from: url) {
                staged.append(draft)
            } else {
                failed += 1
            }
            phase = .scanning(completed: index + 1, total: urls.count)
        }
        drafts = staged
        stagingFailureCount = failed
        phase = staged.isEmpty ? .idle : .reviewing
        if staged.isEmpty, failed > 0 {
            lastImportSummary = "Couldn\u{2019}t read \(failed) file\(failed == 1 ? "" : "s")"
        }
    }

    private func makeDraft(from url: URL) async -> ImportDraft? {
        let filename = url.lastPathComponent
        // Copy out of the system Inbox before anything else. Metadata reading and
        // the whole review step then run against a file we own.
        guard let staged = try? AudioFileStore.stageFile(at: url) else { return nil }

        let localURL = AudioFileStore.absoluteURL(for: staged.stagedPath)
        let embedded = await MetadataExtractor.read(from: localURL)
        let parsed = FilenameParser.parse(filename: filename)

        let title = embedded.title ?? parsed.title
        let artist = embedded.artist ?? parsed.artist ?? "Unknown Artist"

        let source: ImportDraft.MetadataSource
        switch (embedded.title != nil, embedded.artist != nil) {
        case (true, true): source = .embedded
        case (false, false): source = .filename
        default: source = .mixed
        }

        return ImportDraft(
            stagedPath: staged.stagedPath,
            fileSize: staged.fileSize,
            originalFilename: filename,
            title: title,
            artist: artist,
            album: embedded.album,
            duration: embedded.duration,
            artworkData: embedded.artworkData,
            metadataSource: source
        )
    }

    func cancelReview() {
        discardAllStaged()
        batchReplaceAll = false
        batchKeepAll = false
        drafts = []
        stagingFailureCount = 0
        phase = .idle
    }

    /// Removing a row in the review sheet drops its staged copy too.
    func removeDrafts(atOffsets offsets: IndexSet) {
        for index in offsets where drafts.indices.contains(index) {
            AudioFileStore.discardStaged(drafts[index].stagedPath)
        }
        drafts.remove(atOffsets: offsets)
    }

    private func discardAllStaged() {
        for draft in drafts {
            AudioFileStore.discardStaged(draft.stagedPath)
        }
    }

    // MARK: - Commit

    func commit() async {
        let queued = drafts
        var imported = 0
        var replaced = 0
        var failed = stagingFailureCount

        var cancelled = false

        commitLoop: for draft in queued {
            switch await resolve(draft) {
            case .cancel:
                // Everything already committed stays; the rest is dropped.
                cancelled = true
                break commitLoop
            case .replace(let existing):
                if replace(existing, with: draft) { replaced += 1 } else { failed += 1 }
            case .insert:
                if insert(draft) { imported += 1 } else { failed += 1 }
            }
        }

        PersistenceController.shared.save()
        discardAllStaged()
        drafts = []
        phase = .idle
        batchReplaceAll = false
        batchKeepAll = false
        stagingFailureCount = 0
        lastImportSummary = summary(imported: imported, replaced: replaced, failed: failed, cancelled: cancelled)
    }

    private enum Resolution {
        case insert
        case replace(Song)
        case cancel
    }

    private func resolve(_ draft: ImportDraft) async -> Resolution {
        let request = LibraryQuery.duplicateCandidates(for: draft.normalizedKey)
        guard let existing = try? context.fetch(request).first else { return .insert }

        if batchReplaceAll { return .replace(existing) }
        if batchKeepAll { return .insert }

        let decision = await withCheckedContinuation { continuation in
            duplicateContinuation = continuation
            pendingDuplicate = (draft, existing)
        }
        pendingDuplicate = nil

        if decision.choice == .cancelImport { return .cancel }
        if decision.applyToRest {
            switch decision.choice {
            case .replace: batchReplaceAll = true
            case .keepBoth: batchKeepAll = true
            case .cancelImport: break
            }
        }
        return decision.choice == .replace ? .replace(existing) : .insert
    }

    func resolvePendingDuplicate(_ decision: DuplicateDecision) {
        let continuation = duplicateContinuation
        duplicateContinuation = nil
        continuation?.resume(returning: decision)
    }

    @discardableResult
    private func insert(_ draft: ImportDraft) -> Bool {
        guard let storedPath = try? AudioFileStore.promote(stagedPath: draft.stagedPath) else { return false }
        let song = Song(context: context)
        song.id = UUID()
        song.dateAdded = Date()
        song.playCount = 0
        song.isLiked = false
        apply(draft, to: song, storedPath: storedPath, fileSize: draft.fileSize)
        return true
    }

    @discardableResult
    private func replace(_ existing: Song, with draft: ImportDraft) -> Bool {
        guard let storedPath = try? AudioFileStore.promote(stagedPath: draft.stagedPath) else { return false }
        let oldPath = existing.filePath
        apply(draft, to: existing, storedPath: storedPath, fileSize: draft.fileSize)
        if oldPath != storedPath {
            AudioFileStore.delete(relativePath: oldPath)
        }
        return true
    }

    private func apply(_ draft: ImportDraft, to song: Song, storedPath: String, fileSize: Int64) {
        song.filePath = storedPath
        song.fileSize = fileSize
        song.title = draft.title
        song.artist = draft.artist
        song.album = draft.album
        song.duration = draft.duration
        song.artworkData = draft.artworkData
        song.originalFilename = draft.originalFilename
        song.normalizedKey = draft.normalizedKey
        for name in draft.tagNames {
            if let tag = Tag.findOrCreate(named: name, in: context) {
                song.addTag(tag)
            }
        }
    }

    private func summary(imported: Int, replaced: Int, failed: Int, cancelled: Bool) -> String {
        var parts: [String] = []
        if imported > 0 { parts.append("\(imported) added") }
        if replaced > 0 { parts.append("\(replaced) replaced") }
        if failed > 0 { parts.append("\(failed) failed") }
        if parts.isEmpty { return cancelled ? "Import cancelled" : "Nothing imported" }
        if cancelled { parts.append("rest cancelled") }
        return parts.joined(separator: ", ")
    }
}
