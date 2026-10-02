import Combine
import SwiftUI

/// Play Next and Play Last, as the phone offers them: on a row's leading swipe
/// and in the selection bar. One definition, so the wording, the glyph and the
/// confirmation are the same everywhere they appear.
enum QueueAction: CaseIterable, Identifiable {
    case next
    case last

    var id: Self { self }

    var title: String {
        switch self {
        case .next: return "Play Next"
        case .last: return "Play Last"
        }
    }

    var systemImage: String {
        switch self {
        case .next: return "text.line.first.and.arrowtriangle.forward"
        case .last: return "text.line.last.and.arrowtriangle.forward"
        }
    }

    /// Swipe colours, distinct from Like beside them and from Edit / Delete on
    /// the other edge.
    var tint: Color {
        switch self {
        case .next: return .purple
        case .last: return .orange
        }
    }

    /// Queues the songs and says so. With nothing loaded they start playing
    /// instead, which is its own confirmation — the mini bar appears — so no
    /// notice is posted for that.
    func perform(_ songs: [Song], on playback: PlaybackController) {
        guard !songs.isEmpty else { return }
        let wasIdle = playback.currentEntryID == nil
        switch self {
        case .next: playback.playNext(songs)
        case .last: playback.playLast(songs)
        }
        guard !wasIdle else { return }
        QueueNotice.shared.post(confirmation(count: songs.count))
    }

    /// "Playing next" for one song, "3 songs playing next" for several.
    private func confirmation(count: Int) -> String {
        let phrase = self == .next ? "playing next" : "added to queue"
        return count == 1 ? phrase.prefix(1).uppercased() + phrase.dropFirst() : "\(count) songs \(phrase)"
    }
}

/// The brief "Playing next" / "Added to queue" confirmation.
///
/// Its own tiny object rather than state on `PlaybackController`, so posting a
/// notice only invalidates the toast — not every view that observes playback.
@MainActor
final class QueueNotice: ObservableObject {
    static let shared = QueueNotice()

    @Published private(set) var message: String?
    private var clearTask: Task<Void, Never>?

    private init() {}

    func post(_ message: String) {
        self.message = message
        clearTask?.cancel()
        clearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            self?.message = nil
        }
    }
}

/// Floats above the bottom bar while a notice is up. Not interactive, so it can
/// never swallow a tap meant for the list behind it.
struct QueueNoticeToast: View {
    @ObservedObject private var notice = QueueNotice.shared
    @Environment(\.uiMode) private var uiMode
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            if let message = notice.message {
                Label(message, systemImage: "text.badge.checkmark")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.primaryText)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .modeCapsule(uiMode, theme: theme)
                    .modeShadow(uiMode, radius: 8)
                    .transition(.opacity)
            }
        }
        .padding(.bottom, 12)
        .allowsHitTesting(false)
        // Nil in Performance mode: the notice cuts in and out with no fade.
        .modeAnimation(uiMode, value: notice.message)
        .onChange(of: notice.message) { _, message in
            guard let message else { return }
            AccessibilityNotification.Announcement(message).post()
        }
    }
}

/// The selection bar's queue control: one glyph, both actions behind it, so the
/// bar gains one button rather than two.
struct QueueSelectionMenu: View {
    @EnvironmentObject private var playback: PlaybackController
    let songs: () -> [Song]
    let onDone: () -> Void

    var body: some View {
        Menu {
            ForEach(QueueAction.allCases) { action in
                Button {
                    action.perform(songs(), on: playback)
                    onDone()
                } label: {
                    Label(action.title, systemImage: action.systemImage)
                }
            }
        } label: {
            Label("Add to Queue", systemImage: QueueAction.next.systemImage)
                .labelStyle(.iconOnly)
                .frame(width: 44, height: 30)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Add to Queue")
    }
}
