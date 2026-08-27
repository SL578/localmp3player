import CoreData
import SwiftUI

/// Adds a multi-selection to one manual playlist.
struct PlaylistPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var context
    @Environment(\.theme) private var theme
    @FetchRequest(fetchRequest: LibraryQuery.allPlaylists()) private var playlists: FetchedResults<Playlist>

    let songs: [Song]
    let onFinish: () -> Void

    @State private var newPlaylistName = ""
    @State private var showingNewPlaylist = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        showingNewPlaylist = true
                    } label: {
                        Label("New Playlist", systemImage: "plus")
                    }
                    .accentAction(theme)
                }
                .listRowBackground(theme.surface)
                Section("Playlists") {
                    if playlists.isEmpty {
                        Text("No playlists yet.").secondaryText()
                    }
                    ForEach(playlists) { playlist in
                        Button {
                            add(to: playlist)
                        } label: {
                            HStack {
                                Text(playlist.name)
                                Spacer()
                                Text("\(playlist.entries.count)")
                                    .font(.caption)
                                    .secondaryText()
                            }
                        }
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())
                    }
                }
                .listRowBackground(theme.surface)
            }
            .themedScrollBackground(theme)
            .navigationTitle("Add \(songs.count) Song\(songs.count == 1 ? "" : "s")")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .sheet(isPresented: $showingNewPlaylist) {
                NavigationStack {
                    Form {
                        Section {
                            TextField("Name", text: $newPlaylistName)
                        }
                        .listRowBackground(theme.surface)
                    }
                    .themedScrollBackground(theme)
                    .themedSheet(theme)
                    .navigationTitle("New Playlist")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") {
                                newPlaylistName = ""
                                showingNewPlaylist = false
                            }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Create", action: createAndAdd)
                                .disabled(newPlaylistName.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }
            }
        }
    }

    private func add(to playlist: Playlist) {
        for song in songs { playlist.append(song) }
        PersistenceController.shared.save()
        onFinish()
        dismiss()
    }

    private func createAndAdd() {
        let trimmed = newPlaylistName.trimmingCharacters(in: .whitespaces)
        newPlaylistName = ""
        guard !trimmed.isEmpty else { return }
        let playlist = Playlist(context: context)
        playlist.id = UUID()
        playlist.name = trimmed
        playlist.dateCreated = Date()
        add(to: playlist)
    }
}

/// One icon-only button in a bottom selection bar. Shared so the bars in the
/// library and inside a tag are the same size and read the same way.
