import CoreData
import SwiftUI

/// Every screen Settings can push. Pushing by value rather than by destination
/// view is what lets `RootView` clear the stack: a `NavigationLink` that carries
/// its own destination pushes through private state the `path` binding never
/// sees, so emptying the path left the pushed screen exactly where it was.
enum SettingsRoute: Hashable {
    case colors
}

struct SettingsView: View {
    @Environment(\.theme) private var theme
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var themeStore: ThemeStore

    @FetchRequest(fetchRequest: LibraryQuery.allSongs()) private var songs: FetchedResults<Song>

    /// Owned by RootView so it can be reset when this tab is left, since this
    /// pane never actually disappears to reset itself.
    @Binding var path: NavigationPath

    var body: some View {
        NavigationStack(path: $path) {
            Form {
                // One section: how heavy the interface is and which palette it
                // draws with are both just "how the app looks".
                Section {
                    Picker("Interface", selection: $settings.uiMode) {
                        ForEach(UIMode.allCases) { mode in
                            Label(mode.label, systemImage: mode.systemImage).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(settings.uiMode.detail)
                        .font(.footnote)
                        .foregroundStyle(theme.secondaryText)

                    Picker("Theme", selection: $themeStore.appearance) {
                        ForEach(AppearanceMode.allCases) { mode in
                            Label(mode.label, systemImage: mode.systemImage).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    Text(appearanceDetail)
                        .font(.footnote)
                        .foregroundStyle(theme.secondaryText)
                } header: {
                    Text("Appearance")
                }
                .listRowBackground(theme.surface)

                Section {
                    NavigationLink(value: SettingsRoute.colors) {
                        LabeledContent("Colors") {
                            HStack(spacing: 4) {
                                ForEach(ThemeColorToken.allCases.prefix(5)) { token in
                                    Circle()
                                        .fill(theme.color(token))
                                        .frame(width: 12, height: 12)
                                        .overlay(Circle().strokeBorder(theme.separator, lineWidth: 0.5))
                                }
                            }
                        }
                    }
                } footer: {
                    Text("Every color the app draws can be replaced. Light and dark are customized separately.")
                }
                .listRowBackground(theme.surface)

                Section {
                    LabeledContent("Songs", value: "\(songs.count)")
                    LabeledContent("On disk", value: storageUsed)
                } header: {
                    Text("Library")
                }
                .listRowBackground(theme.surface)

                Section {
                    LabeledContent("Version", value: appVersion)
                }
                .listRowBackground(theme.surface)
            }
            .themedScrollBackground(theme)
            .navigationTitle("Settings")
            .navigationDestination(for: SettingsRoute.self) { route in
                switch route {
                case .colors: ColorSettingsView()
                }
            }
        }
    }

    private var appearanceDetail: String {
        themeStore.appearance == .dynamic
            ? "\(themeStore.appearance.detail) \(DaylightWindow.summary)"
            : themeStore.appearance.detail
    }

    private var storageUsed: String {
        let total = songs.reduce(Int64(0)) { $0 + $1.fileSize }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}

/// One row per themeable color. Edits apply to whichever scheme is on screen,
/// so switching to dark and editing there gives dark its own palette.
struct ColorSettingsView: View {
    @Environment(\.colorScheme) private var systemScheme
    @Environment(\.theme) private var theme
    @Environment(\.uiMode) private var uiMode
    @EnvironmentObject private var themeStore: ThemeStore

    private var editingScheme: ColorScheme {
        themeStore.effectiveScheme(system: systemScheme)
    }

    var body: some View {
        Form {
            Section {
                ForEach(ThemeColorToken.allCases) { token in
                    row(for: token)
                }
            } header: {
                Text("\(editingScheme == .dark ? "Dark" : "Light") colors")
            } footer: {
                Text("You're editing the \(editingScheme == .dark ? "dark" : "light") palette. Switch Appearance to edit the other one.")
            }
            .listRowBackground(theme.surface)

            Section {
                Button("Reset \(editingScheme == .dark ? "Dark" : "Light") Colors", role: .destructive) {
                    themeStore.resetAllColors(scheme: editingScheme)
                }
                // Destructive, so red rather than the accent.
                .foregroundStyle(.red)
                .disabled(!ThemeColorToken.allCases.contains { themeStore.isCustomised($0, scheme: editingScheme) })
            }
            .listRowBackground(theme.surface)
        }
        .themedScrollBackground(theme)
        .navigationTitle("Colors")
        .navigationBarTitleDisplayMode(.inline)
        .modeNavigationChrome(uiMode, theme: theme)
    }

    private func row(for token: ThemeColorToken) -> some View {
        HStack {
            ColorPicker(
                selection: binding(for: token),
                supportsOpacity: false
            ) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(token.label)
                    Text(token.detail)
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                }
            }

            if themeStore.isCustomised(token, scheme: editingScheme) {
                Button {
                    themeStore.resetColor(token, scheme: editingScheme)
                } label: {
                    Image(systemName: "arrow.uturn.backward.circle")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Reset \(token.label)")
            }
        }
    }

    private func binding(for token: ThemeColorToken) -> Binding<Color> {
        Binding(
            get: { themeStore.color(token, scheme: editingScheme) },
            set: { themeStore.setColor($0, for: token, scheme: editingScheme) }
        )
    }
}

#Preview {
    SettingsView(path: .constant(NavigationPath()))
        .environment(\.managedObjectContext, PersistenceController.preview.viewContext)
        .environmentObject(AppSettings())
        .environmentObject(ThemeStore())
}
