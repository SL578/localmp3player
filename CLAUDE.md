# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

**At the start of every session, read `docs/HANDOFF.md` before doing anything
else.** It is the single, evolving handoff: current state, simulator traps,
decisions not to re-litigate, planned work, open issues, and how the user likes
to work. At the end of a session (or when asked to hand off), update it in place
and add an entry to the top of its **Session log**. Don't create dated handoff
files.

## What this is

An offline iOS music player for mp3 files the user imports themselves — no
backend, accounts, network calls, or IAP. Swift + SwiftUI, Core Data,
AVFoundation, CarPlay. iOS 17.0 target, Swift 5 language mode, built with
Xcode 27 / iOS 27 SDK. The original spec is `docs/localmp3playerPrompt.md`.

Run git from this directory. The parent `codingRelated` repo ignores this folder
and always reports a clean tree.

## Commands

```bash
# Build (builds both targets — the app embeds the ShareExtension)
xcodebuild -project localmp3player.xcodeproj -scheme localmp3player -destination 'platform=iOS Simulator,name=iPhone 17' build

# Only real diagnostics (a plain `grep warning:` matches compiler flags too)
xcodebuild ... build 2>&1 | grep -E "^(/.*(warning|error):|\*\* BUILD)" | sort -u

# Install over the existing app and launch
xcrun simctl install <UDID> <path>/localmp3player.app && xcrun simctl launch <UDID> com.lin.localmp3player
```

The build is expected to be warning-free. There is **no test target and no
linter** — verification is done by running the app in the simulator.

Two traps, both covered in detail in the handoff:

- **"BUILD SUCCEEDED" + install does not prove the running app is your build.**
  There are two DerivedData directories, and `simctl` can launch a stale
  bundle. Compare the running bundle's `localmp3player.debug.dylib` against the
  build product before testing a change.
- **Never `xcrun simctl uninstall`.** It wipes the data container (library,
  tags, playlists, settings). Install over the top instead.

## Architecture

Two targets: the app (`localmp3player/`) and `ShareExtension/`. `Shared/` is
compiled into both via one file-system-synchronized group listed in both
targets. The project uses Xcode 16 synchronized groups, so adding or removing
files needs no `project.pbxproj` edit — only new targets do.

**`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.** Everything is main-actor by
default; off-main work must be `nonisolated` + `Task.detached`. A plain `async`
function still runs on the main actor.

**The query layer is the single source of truth.** `Library/LibraryQuery` and
`Library/SmartPlaylistEngine` are the only places that decide which songs belong
to a playlist, tag, or smart rule. Both the SwiftUI screens and the CarPlay
templates (`CarPlay/CarPlayBrowser`) read from them. Don't fork this logic.
Smart playlist rules are a `SmartRule` value stored as JSON in
`SmartPlaylist.ruleData`, and evaluated to an array (not a `@FetchRequest`)
because a rule can end in a random sample.

**Model** — Core Data with hand-written `NSManagedObject` subclasses (codegen
off). Schema changes get a new model version in `LocalLibrary.xcdatamodeld`,
never an edit in place. Manual playlists store order in `PlaylistEntry.position`
and can hold a song twice, so selection is keyed by entry, not song.

**Playback** — `PlaybackController.shared` owns the `AVAudioPlayer`, the audio
session, the queue, and the Now Playing / remote-command surface shared by the
phone, lock screen and CarPlay. The queue is kept twice: `orderedQueue` (browse
order) and `queue` (play order), so shuffle can be undone without reloading.
The position lives on a separate `PlaybackClock`, held as a plain `let` so the
1 Hz tick doesn't republish the controller and rebuild every screen. Only small
views that draw the time should observe the clock.

**Tag suggestions** — `Library/TagSuggester` suggests existing tags from artist
history plus the on-device Foundation Models model (iOS 26+, weak-linked, gated
by `#available`). It only suggests; nothing is applied until the user ticks it.
The iOS 26.5 simulator can't run the model — test on the iOS 27 simulator or a
device (see the handoff).

**Import** — three entry points feed `ImportCoordinator`: the document picker,
Files ▸ Open With (`onOpenURL` / `SceneDelegate`), and the Share Extension,
which copies files into the App Group inbox (`Shared/SharedImportInbox`). The
app drains that inbox on launch, on foreground, and on `localplayer://import`.
The coordinator stages files through `AudioFileStore`, reads ID3 via
`MetadataExtractor` (falling back to `FilenameParser`), checks duplicates by
`normalizedKey`, and shows a review sheet before committing.

**UI shell** — `UI/RootView` hand-rolls the bottom bar rather than using
`TabView`. The system tab bar's glass can't be turned off, and it reset the
selected tab. All tab panes stay alive behind an opacity change, so "pop to
root" is signalled with a per-tab counter (`popSignal`). The full player opens
only from the mini bar.

**Two display modes, one seam.** `Style/UIMode` is Standard or Performance
(no animation, no materials, opaque bars). `Style/ModeStyling.swift` is the only
place the modes differ. Screens use its wrappers instead of raw modifiers:
toolbars go through `modeToolbar` (never a bare `.toolbar`), nav bars through
`modeNavigationChrome` with a title style matching the screen, and animations
through the mode helpers. Theme colours are `ThemeColorToken`s resolved once
into an `AppTheme` in `ThemedRoot` and read from the environment.

## Conventions worth knowing before editing

- Swipe actions that only open a confirmation must not use
  `role: .destructive` (the row animates away first). Use `.tint(.red)`.
- Don't put a custom `ButtonStyle` in a `List`'s environment, and don't write
  `@State` from a `GeometryReader` inside a row. Either one can silently stop
  `swipeActions` from being built.
- Colour SF Symbols in toolbars on the `Image` (`ToolbarGlyph`). Symbols don't
  inherit a button's `foregroundStyle`, and UIKit dims the tint while anything
  is presented.
- `docs/HANDOFF.md` → *Decisions worth not re-litigating* has the full list and
  the reasons.
