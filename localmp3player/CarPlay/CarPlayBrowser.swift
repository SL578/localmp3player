import CarPlay
import CoreData
import UIKit

/// Builds the CarPlay browse hierarchy: Playlists (smart + manual) → Tags → Songs.
///
/// Every list here is produced by the same `LibraryQuery` / `SmartPlaylistEngine`
/// calls the phone screens use, so a rule or sort change lands on both surfaces
/// at once. Lists are also capped, because head units get sluggish long before
/// a phone does.
@MainActor
final class CarPlayBrowser {
    /// CarPlay's own limit on items in a single list template.
    private static let maxItemsPerList = CPListTemplate.maximumItemCount
    private static let maxSongsPerList = 200

    private let interfaceController: CPInterfaceController
    private var context: NSManagedObjectContext { PersistenceController.shared.viewContext }
    private var playback: PlaybackController { .shared }

    init(interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
    }

    // MARK: - Root

    func makeRootTemplate() -> CPTemplate {
        let tabs = CPTabBarTemplate(templates: [
            makePlaylistsTemplate(),
            makeTagsTemplate(),
            makeSongsTemplate()
        ])
        return tabs
    }

    // MARK: - Playlists tab

    /// Smart and manual playlists sit in one tab, smart ones first, so the
    /// rule-based lists are reachable in a single tap from the root.
    private func makePlaylistsTemplate() -> CPListTemplate {
        var sections: [CPListSection] = []

        let smart = LibraryQuery.fetchAll(LibraryQuery.allSmartPlaylists(), in: context)
        if !smart.isEmpty {
            let items = smart.map { playlist in
                let item = CPListItem(text: playlist.name, detailText: playlist.ruleSummary)
                item.accessoryType = .disclosureIndicator
                item.handler = { [weak self] _, completion in
                    guard let self else { completion(); return }
                    let songs = SmartPlaylistEngine.songs(for: playlist, in: self.context)
                    self.pushSongList(songs, title: playlist.name, completion: completion)
                }
                return item
            }
            sections.append(CPListSection(items: items, header: "Smart", sectionIndexTitle: nil))
        }

        let manual = LibraryQuery.fetchAll(LibraryQuery.allPlaylists(), in: context)
        if !manual.isEmpty {
            let items = manual.map { playlist in
                let item = CPListItem(text: playlist.name, detailText: "\(playlist.entries.count) songs")
                item.accessoryType = .disclosureIndicator
                item.handler = { [weak self] _, completion in
                    self?.pushSongList(playlist.songs, title: playlist.name, completion: completion)
                }
                return item
            }
            sections.append(CPListSection(items: items, header: "Playlists", sectionIndexTitle: nil))
        }

        let template = CPListTemplate(title: "Playlists", sections: sections)
        template.tabTitle = "Playlists"
        template.tabImage = UIImage(systemName: "music.note.house")
        template.emptyViewSubtitleVariants = ["Create playlists on your phone to see them here."]
        return template
    }

    // MARK: - Tags tab

    private func makeTagsTemplate() -> CPListTemplate {
        let tags = LibraryQuery.fetchAll(LibraryQuery.allTags(), in: context)
        let items = tags.prefix(Self.maxItemsPerList).map { tag in
            let item = CPListItem(text: tag.displayName, detailText: "\(tag.songs.count) songs")
            item.accessoryType = .disclosureIndicator
            item.handler = { [weak self] _, completion in
                guard let self else { completion(); return }
                let songs = LibraryQuery.fetch(LibraryQuery.songs(taggedWith: tag), in: self.context)
                self.pushSongList(songs, title: tag.displayName, completion: completion)
            }
            return item
        }

        let template = CPListTemplate(title: "Tags", sections: [CPListSection(items: Array(items))])
        template.tabTitle = "Tags"
        template.tabImage = UIImage(systemName: "tag")
        template.emptyViewSubtitleVariants = ["Tag songs on your phone to browse them here."]
        return template
    }

    // MARK: - Songs tab

    private func makeSongsTemplate() -> CPListTemplate {
        let songs = LibraryQuery.fetch(LibraryQuery.allSongs(sort: .title), in: context)
        let template = CPListTemplate(title: "Songs", sections: [songSection(for: songs, sourceName: "Library")])
        template.tabTitle = "Songs"
        template.tabImage = UIImage(systemName: "music.note.list")
        template.emptyViewSubtitleVariants = ["Import mp3 files on your phone to get started."]
        return template
    }

    // MARK: - Shared

    private func pushSongList(_ songs: [Song], title: String, completion: @escaping () -> Void) {
        let template = CPListTemplate(title: title, sections: [songSection(for: songs, sourceName: title)])
        template.emptyViewSubtitleVariants = ["Nothing matches this right now."]
        interfaceController.pushTemplate(template, animated: true) { _, _ in completion() }
    }

    private func songSection(for songs: [Song], sourceName: String) -> CPListSection {
        let capped = Array(songs.prefix(Self.maxSongsPerList))
        let items = capped.enumerated().map { index, song -> CPListItem in
            let item = CPListItem(text: song.title, detailText: song.artist)
            if let data = song.artworkData, let image = UIImage(data: data) {
                item.setImage(image)
            }
            item.handler = { [weak self] _, completion in
                guard let self else { completion(); return }
                self.playback.play(songs: capped, startingAt: index, sourceName: sourceName)
                self.interfaceController.pushTemplate(CPNowPlayingTemplate.shared, animated: true) { _, _ in
                    completion()
                }
            }
            return item
        }
        return CPListSection(items: items)
    }
}
