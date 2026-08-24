# Local Player

An offline, local-only music player for iOS. Songs are mp3 files you import
yourself. No backend, no accounts, no network calls of any kind.

## Building

`xcode-select` on this machine points at CommandLineTools, so command-line
builds need `DEVELOPER_DIR` set:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project localmp3player.xcodeproj -scheme localmp3player -destination 'platform=iOS Simulator,name=iPhone 17' build
```

Opening the project in Xcode works normally.

## Layout

| Path | What lives there |
| --- | --- |
| `Model/` | Core Data model + `NSManagedObject` subclasses (written by hand, `codegen` is off) |
| `Library/` | `LibraryQuery` and `SmartPlaylistEngine` — the shared query layer |
| `Import/` | Document picker, filename parser, ID3 reader, import/duplicate coordinator |
| `Playback/` | `PlaybackController` — AVAudioPlayer, queue, now-playing, remote commands |
| `CarPlay/` | CarPlay scene delegate and browse-template builder |
| `UI/` | SwiftUI screens |
| `Style/` | `UIMode` (Standard/Performance seam) and `Theme` (appearance + user colors) |

`LibraryQuery` and `SmartPlaylistEngine` are the only places that decide which
songs belong to a playlist, tag, or rule. Both the phone screens and the CarPlay
templates read from them, so a change lands on both surfaces at once.

## CarPlay

**TODO before shipping:** request the CarPlay audio entitlement from Apple
(https://developer.apple.com/contact/carplay/). Once granted, add it to
`localmp3player.entitlements`:

```xml
<key>com.apple.developer.carplay-audio</key>
<true/>
```

The file is intentionally empty until then — adding the key without a matching
provisioning profile breaks signing for device builds.

**Deviation from the original spec:** the spec called for
`MPPlayableContentDataSource`. That API has been deprecated since iOS 14 and
CarPlay no longer calls it, so the browse hierarchy is built with the CarPlay
framework's template API (`CPTemplateApplicationSceneDelegate`, `CPTabBarTemplate`,
`CPListTemplate`, `CPNowPlayingTemplate`) instead. The structure the spec asked
for is unchanged: Playlists (smart first, then manual) → Tags → Songs, with
playback one tap from any list.

## Appearance and theming

`Style/Theme.swift` holds all of it.

**Appearance** — System, Light, Dark, or Dynamic. Dynamic follows the clock
rather than the system setting, using fixed hours (`DaylightWindow`: dark from
19:00 to 07:00) so the app never needs location access or a network call to
work out sunset. A five-minute timer plus a `scenePhase` check flips it over
without a relaunch.

**Colors** — every color the app paints is a `ThemeColorToken` case. Settings →
Colors loops over `allCases`, so adding a token adds a row automatically. Light
and dark store overrides separately (key is `token.scheme`); the screen edits
whichever scheme is currently on screen and says so. Anything unset falls back
to the token's default, and each row and the whole palette can be reset.

The resolved `AppTheme` is computed once in `ThemedRoot` and read from the
environment everywhere else, so no view recomputes the palette.

## Display Mode

**Standard** — system materials, a floating glass bottom bar, shadows, and
`.snappy` transitions.

**Performance** — `UIMode.animation` returns nil and `modeTransactions` sets
`disablesAnimations`, so nothing animates at all; no blur or material anywhere
(the bottom bar becomes an opaque edge-to-edge fill), no shadows, and opaque
navigation bars so scrolling content never composites through glass.

Both modes render from the same views. `Style/ModeStyling.swift` is the only
place the two differ.

Independent of mode, the app avoids two costs that would otherwise show up on
every screen: `ArtworkCache` decodes and downsamples embedded artwork once per
(image, size) instead of per row render, and tabs are built on first visit
rather than all four at launch.

## Filename parsing

`FilenameParser` reads filenames as `Artist - Title`, which is what downloaded
files overwhelmingly use. The import review screen has a one-tap
**Swap Title and Artist** for files that use the other order. Embedded ID3 tags
always win over the filename; parsing is only a fallback.

## Playback

Shuffle and repeat live on `PlaybackController`. The queue is kept twice:
`orderedQueue` in browse order and `queue` in play order, so toggling shuffle
off restores the original order without reloading the track. Repeat cycles
off → all → one. Repeat-one applies only when a track ends naturally — pressing
next always moves on, which is the platform convention. `shufflePlay` is the
"play something random" entry point and is on the toolbar of the Library, every
playlist, every smart playlist, and every tag. Shuffle and repeat are also wired
to the system remote commands, so the lock screen and CarPlay can drive them.

Tapping a song starts playback and pushes the player for that list, so the queue
on screen is exactly what you played from and nothing else.

## Not implemented (out of scope by design)

Android/Android Auto, any in-app song acquisition, monetization, cloud sync or
accounts.
