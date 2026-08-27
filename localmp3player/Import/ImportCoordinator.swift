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
        /// Tags written by a video downloader, tidied up. Named separately
        /// because it is the one source that is a *guess* about a tag rather
        /// than the tag itself, and the review sheet should say so.
        case cleanedVideoTags

        var label: String {
            switch self {
            case .embedded: return "From file tags"
            case .filename: return "From filename"
            case .mixed: return "Tags + filename"
            case .cleanedVideoTags: return "Cleaned from video tags"
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
    /// URLs arriving from outside the app, gathered until they stop coming.
    private var externalQueue: [URL] = []
    private var externalDrain: Task<Void, Never>?

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
        stagingFailureCount = 0
        await addToStaging(urls)
    }

    /// Files handed to the app from outside it — the share sheet, another app's
    /// "Open in", or a tap on an audio file in Files.
    ///
    /// iOS delivers these one URL per callback even when several were shared
    /// together, so they are collected for a beat before anything is staged.
    /// Without that, sharing four songs opened the review sheet four times, each
    /// one throwing away the last.
    func accept(externalURL url: URL) {
        externalQueue.append(url)
        externalDrain?.cancel()
        externalDrain = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await self?.drainExternalQueue()
        }
    }

    private func drainExternalQueue() async {
        let urls = externalQueue
        externalQueue = []
        externalDrain = nil
        guard !urls.isEmpty else { return }

        if phase == .reviewing {
            // A second share while the sheet is open joins the list rather than
            // replacing it.
            await addToStaging(urls)
        } else {
            await stage(urls: urls)
        }
    }

    /// Reads each URL into a draft and appends the result to whatever is already
    /// being reviewed.
    ///
    /// The scanning phase is only entered when nothing is on screen yet. Setting
    /// it while the review sheet is up would make `isPresentingReview` false for
    /// the duration, and the sheet's dismissal binding reads that as the user
    /// closing the sheet — which calls `cancelReview` and discards every draft,
    /// including the ones being added.
    private func addToStaging(_ urls: [URL]) async {
        let showsProgress = phase != .reviewing
        if showsProgress { phase = .scanning(completed: 0, total: urls.count) }

        var staged: [ImportDraft] = []
        var failed = 0
        for (index, url) in urls.enumerated() {
            if let draft = await makeDraft(from: url) {
                staged.append(draft)
            } else {
                failed += 1
            }
            if showsProgress { phase = .scanning(completed: index + 1, total: urls.count) }
        }
        drafts += staged
        stagingFailureCount += failed
        phase = drafts.isEmpty ? .idle : .reviewing
        if drafts.isEmpty, stagingFailureCount > 0 {
            let count = stagingFailureCount
            lastImportSummary = "Couldn\u{2019}t read \(count) file\(count == 1 ? "" : "s")"
            stagingFailureCount = 0
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

        let title: String
        let artist: String
        let source: ImportDraft.MetadataSource

        if embedded.isVideoDownload, let videoTitle = embedded.title {
            // These tags aren't a song and an artist: the title frame holds a
            // whole video title and the artist frame holds the channel that
            // uploaded it. Taking them at face value is what produced
            // "Tchaikovsky - The Nutcracker Suite, Op 71a" by "avrilfan2213".
            // The same cleanup a filename gets applies, on better input — the
            // tag still has the characters the filesystem made the name drop.
            let cleaned = FilenameParser.parse(videoTitle: videoTitle)
            title = cleaned.title
            // An artist named inside the title outranks the channel name: a
            // video called "Tchaikovsky – Swan Lake Suite" says who wrote it,
            // and the orchestra's YouTube account doesn't.
            artist = cleaned.artist ?? embedded.artist ?? parsed.artist ?? "Unknown Artist"
            source = .cleanedVideoTags
        } else {
            title = embedded.title ?? parsed.title
            artist = embedded.artist ?? parsed.artist ?? "Unknown Artist"
            switch (embedded.title != nil, embedded.artist != nil) {
            case (true, true): source = .embedded
            case (false, false): source = .filename
            default: source = .mixed
            }
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
