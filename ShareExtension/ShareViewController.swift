import UIKit
import UniformTypeIdentifiers

/// Takes every audio file a share hands over and parks it where the app can
/// reach it.
///
/// This exists because the "Open in Local Player" route a document-types app
/// gets is a *single*-document channel: iOS hands over exactly one URL however
/// many files were shared, which is why sharing four songs imported one. A share
/// extension is offered the whole selection.
///
/// It asks nothing. Naming, tagging and duplicate decisions all happen in the
/// app's own review sheet, which is where they already lived — anything asked
/// here would be a second place to answer the same questions. All it reports is
/// what it took and where to go next.
final class ShareViewController: UIViewController {
    private let card = UIStackView()
    private let headline = UILabel()
    private let detail = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        buildCard()
        Task { await run() }
    }

    private func run() async {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }

        var accepted = 0
        for provider in providers {
            guard let identifier = audioTypeIdentifier(of: provider) else { continue }
            if await copyIn(provider, typeIdentifier: identifier) { accepted += 1 }
        }

        report(accepted: accepted, offered: providers.count)
        // Best effort, and usually refused: iOS does not generally let a share
        // extension launch its host app. Nothing is lost when it is — the files
        // are in the shared inbox and the app drains it on its next launch or
        // foreground, which is what the card on screen says.
        if await extensionContext?.open(SharedImportInbox.openURL) == true {
            dismissExtension()
        }
    }

    /// A shared song is usually offered as `public.mp3` or `public.mpeg-4-audio`
    /// rather than as `public.audio`, so the concrete type is picked out of what
    /// the provider actually registered instead of being assumed.
    private func audioTypeIdentifier(of provider: NSItemProvider) -> String? {
        provider.registeredTypeIdentifiers.first { identifier in
            UTType(identifier)?.conforms(to: .audio) == true
        }
    }

    /// The URL a provider yields is only valid inside the callback — it is a
    /// temporary the system reclaims — so the bytes are copied there and then.
    private func copyIn(_ provider: NSItemProvider, typeIdentifier: String) async -> Bool {
        await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, _ in
                guard let url else { return continuation.resume(returning: false) }
                // `suggestedName` drops the extension; the temporary keeps the
                // real filename, which is what the app's parser reads when a
                // file's own tags are missing or are a video title.
                let stored = SharedImportInbox.accept(contentsOf: url, named: url.lastPathComponent)
                continuation.resume(returning: stored != nil)
            }
        }
    }

    // MARK: - The card

    private func report(accepted: Int, offered: Int) {
        if accepted == 0 {
            headline.text = offered == 0 ? "Nothing to import" : "Couldn’t read those"
            detail.text = "Local Player takes audio files — mp3, m4a, wav and aiff."
        } else {
            headline.text = "\(accepted) song\(accepted == 1 ? "" : "s") ready"
            detail.text = "Open Local Player to name and add \(accepted == 1 ? "it" : "them")."
        }
        card.isHidden = false
    }

    private func buildCard() {
        view.backgroundColor = .systemBackground

        headline.font = .preferredFont(forTextStyle: .title3)
        headline.adjustsFontForContentSizeCategory = true
        headline.textAlignment = .center
        headline.numberOfLines = 0

        detail.font = .preferredFont(forTextStyle: .callout)
        detail.adjustsFontForContentSizeCategory = true
        detail.textColor = .secondaryLabel
        detail.textAlignment = .center
        detail.numberOfLines = 0

        var configuration = UIButton.Configuration.borderedProminent()
        configuration.title = "Done"
        let done = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in
            self?.dismissExtension()
        })

        card.axis = .vertical
        card.spacing = 12
        card.alignment = .fill
        card.isHidden = true
        card.translatesAutoresizingMaskIntoConstraints = false
        [headline, detail, done].forEach(card.addArrangedSubview)
        card.setCustomSpacing(24, after: detail)
        view.addSubview(card)

        NSLayoutConstraint.activate([
            card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            card.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor, constant: 16),
            card.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor, constant: -16),
        ])
    }

    private func dismissExtension() {
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }
}
