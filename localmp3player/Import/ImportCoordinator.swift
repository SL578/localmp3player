import Combine
import CoreData
import Foundation
import SwiftUI

/// One file staged for import. Everything here is editable in the review sheet
/// before it becomes a `Song`.
struct ImportDraft: Identifiable {
    let id = UUID()
    var sourceURL: URL
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
    enum Choice { case replace, keepBoth }
    var choice: Choice
    var applyToRest: Bool
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

    private let context: NSManagedObjectContext
    private var batchReplaceAll = false
    private var duplicateContinuation: CheckedContinuation<DuplicateDecision, Never>?

    init(context: NSManagedObjectContext) {
        self.context = context
    }

    var isPresentingReview: Bool { phase == .reviewing }

    // MARK: - Stage

    func stage(urls: [URL]) async {
        guard !urls.isEmpty else { return }
        batchReplaceAll = false
        drafts = []
        phase = .scanning(completed: 0, total: urls.count)

        var staged: [ImportDraft] = []
        for (index, url) in urls.enumerated() {
            if let draft = await makeDraft(from: url) {
                staged.append(draft)
            }
            phase = .scanning(completed: index + 1, total: urls.count)
        }
        drafts = staged
        phase = staged.isEmpty ? .idle : .reviewing
    }

    private func makeDraft(from url: URL) async -> ImportDraft? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let filename = url.lastPathComponent
        let embedded = await MetadataExtractor.read(from: url)
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
            sourceURL: url,
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
        drafts = []
        phase = .idle
    }

    // MARK: - Commit

    func commit() async {
        let queued = drafts
        var imported = 0
        var replaced = 0
        var skipped = 0

        for draft in queued {
            switch await resolve(draft) {
            case .replace(let existing):
                replace(existing, with: draft)
                replaced += 1
            case .insert:
                if insert(draft) { imported += 1 } else { skipped += 1 }
            }
        }

        PersistenceController.shared.save()
        drafts = []
        phase = .idle
        batchReplaceAll = false
        lastImportSummary = summary(imported: imported, replaced: replaced, skipped: skipped)
    }

    private enum Resolution {
        case insert
        case replace(Song)
    }

    private func resolve(_ draft: ImportDraft) async -> Resolution {
        let request = LibraryQuery.duplicateCandidates(for: draft.normalizedKey)
        guard let existing = try? context.fetch(request).first else { return .insert }

        if batchReplaceAll { return .replace(existing) }

        let decision = await withCheckedContinuation { continuation in
            duplicateContinuation = continuation
            pendingDuplicate = (draft, existing)
        }
        pendingDuplicate = nil

        if decision.applyToRest && decision.choice == .replace {
            batchReplaceAll = true
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
        guard let stored = try? AudioFileStore.importFile(at: draft.sourceURL) else { return false }
        let song = Song(context: context)
        song.id = UUID()
        song.dateAdded = Date()
        song.playCount = 0
        song.isLiked = false
        apply(draft, to: song, storedPath: stored.relativePath, fileSize: stored.fileSize)
        return true
    }

    private func replace(_ existing: Song, with draft: ImportDraft) {
        guard let stored = try? AudioFileStore.importFile(at: draft.sourceURL) else { return }
        let oldPath = existing.filePath
        apply(draft, to: existing, storedPath: stored.relativePath, fileSize: stored.fileSize)
        if oldPath != stored.relativePath {
            AudioFileStore.delete(relativePath: oldPath)
        }
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

    private func summary(imported: Int, replaced: Int, skipped: Int) -> String {
        var parts: [String] = []
        if imported > 0 { parts.append("\(imported) added") }
        if replaced > 0 { parts.append("\(replaced) replaced") }
        if skipped > 0 { parts.append("\(skipped) skipped") }
        return parts.isEmpty ? "Nothing imported" : parts.joined(separator: ", ")
    }
}
