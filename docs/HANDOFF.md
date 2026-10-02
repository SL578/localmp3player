# Local Player — handoff

The one handoff for this project, kept current. Read it at the start of a
session; update it in place at the end.

**How to maintain it:**

- The sections above **Session log** describe the project *as it is now*. Edit
  them in place — correct what changed, delete what stopped being true. Don't
  write "this session" or "new" in them; that goes stale the moment the session
  ends.
- Add one entry to the top of **Session log** per session: date, commits, what
  changed and why, anything tried that didn't work. Keep it short — the load-
  bearing detail belongs in the sections above.
- Don't create dated `HANDOFFMMDDYYYY.md` files again. The eight that existed
  (2026-08-23 through 2026-09-01) were folded into this one on 2026-09-29; the
  originals are in git history, e.g. `git show f1b0907:docs/HANDOFF09012026.md`.

---

## What this is

A native iOS music player for mp3 files the user imports themselves. Fully
offline: no backend, no accounts, no network calls of any kind, free, no IAP.

Differentiators vs. existing local players (e.g. Doppler): messy-filename →
metadata cleanup, rules-based smart playlists, smarter duplicate handling, and
CarPlay treated as a first-class surface rather than bolted on.

**Stack:** Swift + SwiftUI, Core Data, AVFoundation, CarPlay framework.
The original spec is `docs/localmp3playerPrompt.md`; the smart-playlist rebuild
spec is `docs/smart-playlist-rebuild-prompt.md`.

## Where things are

| | |
| --- | --- |
| Repo root | `/Users/stephenlin/Desktop/codingRelated/localMp3Player` |
| GitHub | `https://github.com/SL578/localmp3player` (**public**) |
| Branch | `main` |

The parent `codingRelated` repo (`SL578/codingRelated`, **private**) ignores
`localMp3Player/` outright — no gitlink. **Running git from the parent reports a
clean tree no matter what is uncommitted here.** Run git from the app repo root.
The parent also ignores a Unity project belonging to a different GitHub account —
leave it alone.

`docs/` holds the specs and this handoff.

### Identifiers

| | |
| --- | --- |
| App bundle id | `com.lin.localmp3player` |
| Extension bundle id | `com.lin.localmp3player.ShareExtension` |
| App Group | `group.com.lin.localmp3player` |
| URL scheme | `localplayer://import` |
| Team | `3HV3R6K698` |

## Architecture

```
localmp3player/
  Model/      Core Data entities + hand-written NSManagedObject subclasses (codegen off)
  Library/    LibraryQuery, SmartPlaylistEngine  ← the shared query layer
              AudioFileStore, ArtworkUpgrade, NormalizedKey
  Import/     document picker, filename parser, ID3 reader, import/duplicate coordinator
  Playback/   PlaybackController (AVAudioPlayer, queue, now-playing, remote commands),
              PlaybackClock (the 1 Hz position, kept off the controller)
  CarPlay/    scene delegate + browse-template builder
  UI/         SwiftUI screens
  Style/      UIMode (Standard/Performance seam), Theme, ModeStyling, AppSymbols
ShareExtension/  the share-sheet target — copies audio into the App Group inbox
Shared/          compiled into both targets (App Group id, shared inbox)
```

**The one rule that matters:** `LibraryQuery` and `SmartPlaylistEngine` are the
only places that decide which songs belong to a playlist, tag, or rule. Both the
phone screens and the CarPlay templates read from them, so a change lands on both
surfaces at once. Don't fork this logic.

**The project uses Xcode 16 file-system-synchronized groups.** New and deleted
files on disk are picked up with no `project.pbxproj` edit. New *targets* still
need one.

## What's built

- **Import** — document picker (copies into app storage, batch), Files ▸ Open
  With, and a Share Extension for multi-file shares. ID3 wins; `FilenameParser`
  is the fallback. yt-dlp downloads (detected by the source URL in `TXXX`
  frames) get filename-style cleanup applied to the tag, since their title frame
  holds a video title and the artist frame the uploading channel. Editable review
  sheet before save, with a one-tap title/artist swap.
- **Duplicates** — `normalizedKey` lookup with Replace / Keep Both / Replace All.
  Editing a song recomputes the key.
- **Tagging** — per-song and multi-select batch tagging (tri-state for partial
  selections), colour-coded chips.
- **Tag suggestions** — `Library/TagSuggester` suggests the user's *existing*
  tags for a song from two signals: how they've tagged other songs by the same
  artist, and the on-device Apple Intelligence model (Foundation Models, iOS 26+,
  weak-linked). Shown as dashed chips you tap to accept, in the import review
  sheet (rows and editor, plus "Add All Suggested Tags") and, for existing songs,
  under Select ▸ Tag ▸ Suggest Tags for Each Song (`UI/TagSuggestionViews`).
  Settings ▸ Tag Suggestions has "Tick Suggestions Automatically" (off by
  default) and shows the model's status.
- **Playlists** — manual (drag-reorder, order in `PlaylistEntry.position`) and
  smart. `SmartRule` carries tag and artist criteria together: include (any/all),
  exclude, and an except-override that rescues from an exclusion only. Untagged
  can be required or excluded. Stored as JSON in `ruleData`; the reader accepts
  all historical shapes and upgrades on save. Live match count in the editor.
- **Playback** — queue, background audio, lock-screen remote commands, play
  count / last-played. Queue kept twice (`orderedQueue` browse order + `queue`
  play order) so shuffle off restores order without reloading the track. Both
  hold `QueueEntry` values (own `UUID` + song), not songs, so one song can be
  queued twice. Repeat cycles off → all → one; **repeat-one applies only on
  natural track end** — next always advances. `ScrubBar` owns its drag gesture;
  tap-to-seek works.
- **Queue actions** — Play Next / Play Last on the leading swipe (after Like)
  in `SongListContent` and playlist detail rows, and as one menu glyph in the
  Library, tag and playlist selection bars (`UI/QueueActions.swift`). A
  "Playing next" / "Added to queue" capsule shows for 1.6s (`QueueNotice`). Up
  Next in the player is editable: long-press drag to reorder, swipe to Remove.
- **Total length** — "N songs · X min" on playlist, smart, tag and CarPlay rows
  and as the first row of each detail screen; "X min left" in the Up Next
  header. `TimeFormatting.totalLength` / `songSummary`, summed in memory.
- **Colours** — tags, playlists and smart playlists carry a colour; nil draws in
  the theme accent via `Colorable.tint(_:)`.
- **Appearance** — System / Light / Dark / Dynamic (fixed 19:00–07:00, see
  decisions). Every colour is a `ThemeColorToken` with a picker; light and dark
  overrides stored separately. Dark is the default on a fresh install.
- **Display Mode** — Standard vs Performance, one styling seam (`UIMode`,
  `ModeStyling`). Performance turns off animation and materials app-wide.
- **Artwork** — stored at 1024px / JPEG 0.92. `ArtworkUpgrade` runs once in the
  background to re-read older, smaller art; it's gated on a default set only
  after a complete pass. Decoding is off the main thread.
- **CarPlay** — browse hierarchy built and linked. **Not visually verifiable**
  without a real head unit, and the entitlement isn't requested yet.

## Out of scope by design

Android / Android Auto (no cross-platform abstraction — explicitly not wanted
now), any in-app song acquisition or YouTube functionality (must stay out for
App Store compliance), monetization of any kind, cloud sync, accounts, social.

---

## Build and run

```bash
xcodebuild -project localmp3player.xcodeproj -scheme localmp3player -destination 'platform=iOS Simulator,name=iPhone 17' build
xcrun simctl install <UDID> <path>/localmp3player.app && xcrun simctl launch <UDID> com.lin.localmp3player
```

Builds clean, zero warnings. iOS 17.0 target, Xcode 27.0, iOS 27.0 SDK (the user
updated Xcode on 2026-10-01). **There
are two targets**, and the app target embeds the extension, so building the app
builds both.

To see only real diagnostics, anchor the grep to the start of the line —
`grep -iE "warning:|error:"` alone matches compiler *flags* in the echoed command
lines and buries you in 38KB of noise:

```bash
xcodebuild ... build 2>&1 | grep -E "^(/.*(warning|error):|\*\* BUILD)" | sort -u
```

Device builds are healthy:

```bash
xcodebuild -project localmp3player.xcodeproj -scheme localmp3player -destination 'platform=iOS,id=EFEEEBD5-61F7-5EEF-AEAD-A1F827571239' -allowProvisioningUpdates build
```

Automatic signing registered the second App ID on its own and issued profiles for
both, with the App Group on both. Nothing was needed in the developer portal.

### There are two DerivedData directories

```
localmp3player-epkotvwgruvmxlcvryjchmiyacng   # stale, last written 2026-08-25
localmp3player-hhbhvdugsegxzpaxxddnxlogcfmg   # the one xcodebuild writes
```

`ls` returns both and they look identical. **Check mtimes, or install the wrong
build and debug a change that was never in it.** Combined with the stale-bundle
trap below, this is two independent ways to test the wrong binary.

### The stale-bundle trap

`xcrun simctl install` exits 0 and creates a new bundle directory, but
`xcrun simctl launch <old-identifier>` starts whatever was installed under the
*old* identifier. **"BUILD SUCCEEDED" plus a successful install is not evidence
that the app on screen is your build.**

**Grepping the debug dylib for a new string only works if the change added one.**
What works for any change is comparing the installed dylib against the build
product. This prints `1` when the running bundle is your build and `2` when it is
not (`$BP` is the build products directory):

```bash
RB=$(ps -Ao comm | grep localmp3player.app/localmp3player | head -1)
shasum "$(dirname "$RB")/localmp3player.debug.dylib" "$BP/localmp3player.debug.dylib" | awk '{print $1}' | sort -u | wc -l
```

### `simctl uninstall` is never the answer

It **deletes the app's data container** — library, tags, playlists, palette,
interface mode, everything. It cost one session its test library. `xcrun simctl
install` over the existing install registers new PlugIns fine.

If an uninstall is genuinely unavoidable, back the data container up *and verify
the copy* first:

```bash
cp -R "$(xcrun simctl get_app_container <UDID> com.lin.localmp3player data)/" backup/
```

### The scheme trap, if another target is ever hand-added

The project had **no `.xcscheme` files at all** — Xcode autocreated one per
target. Adding `ShareExtension` added a scheme, and with equal order hints Xcode
picks the alphabetically first: capital `S` sorts before lowercase `l`, so the
picker silently switched and ⌘R started asking "choose an app to run".

Fixed by committing a real shared scheme at
`localmp3player.xcodeproj/xcshareddata/xcschemes/localmp3player.xcscheme`, and
hiding the ShareExtension scheme in the user's `xcschememanagement.plist`
(`xcuserdata/` is gitignored, so that half is local only).

**Editing scheme files while Xcode is running does nothing.** The active scheme
lives in Xcode's in-memory UI state. Restarting Xcode is what applied it.

### Logging from the simulator

`NSLog` and `print` do **not** reach `xcrun simctl spawn <UDID> log show`, and
`--console-pty` redirected to a file captures nothing. What works is writing to a
file in the app's own Documents directory and reading it from the host.

---

## Decisions worth not re-litigating

### Platform and architecture

**CarPlay uses the modern template API, not `MPPlayableContentDataSource`.**
The original spec named that API; it has been deprecated since iOS 14 and
CarPlay no longer calls it. Uses `CPTemplateApplicationSceneDelegate`,
`CPTabBarTemplate`, `CPListTemplate`, `CPNowPlayingTemplate` instead.

**The bottom bar is hand-rolled, not a `TabView`.** The iOS 26 system tab bar
always draws a glass material, which Performance mode must be able to turn off;
and attaching the mini player as a `tabViewBottomAccessory` restructured the view
tree, which reset the selected tab mid-navigation. Don't reintroduce a `TabView`.

**Tab panes are kept alive behind an opacity change,** so `popSignal` exists.
Re-tapping the current tab returns it to its root; for the Library (which never
pushes) that means clearing search and scrolling to the top.

**Dynamic appearance uses fixed hours, not real sunset.** Real sunset needs
location or network, and the app is strictly offline.

**`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` is set on this project**, in all
four build configurations. Anything that needs to be off the main thread must say
so explicitly — `nonisolated` plus `Task.detached`. A bare `async` function is
not enough here.

**Core Data gets a new model version rather than an edit in place.**

**`testSongs/` is gitignored, not committed.** 56MB of material that is not ours
to redistribute from a public repository.

### Performance mode

**Performance mode's `UIView.setAnimationsEnabled(false)` makes interactive
transitions look broken.** Anything gesture-driven that ends in a UIKit
completion animation snaps instead, and a system cross-fade becomes a hard step.
The ruling is to remove the gesture or the thing being faded rather than carve an
exception into the mode — *"that's the only thing that impacts user experience."*

**The player is a `fullScreenCover` in Performance and a `sheet` in Standard.**
Both modifiers are always applied, gated on mode-aware bindings so exactly one is
live; an `if` between them would restructure the view tree on a mode change.
`.interactiveDismissDisabled` was tried and is not enough — it blocks the
dismissal, not the drag. The user rejected an inert drag as a "false promise".

**iOS 26's toolbar-button glass samples the content behind the bar, not the
bar.** A pinned opaque `toolbarBackground` does not stop it. If any bar control's
appearance shifts with scroll position, this is why — start by measuring pixels.

**Every toolbar goes through `modeToolbar`** (`ModeStyling.swift`). It wraps
`.toolbar` and sets iOS 26's `sharedBackgroundVisibility` from the mode —
`.automatic` in Standard, `.hidden` in Performance. `modeToolbarBackground` is
`fileprivate` on purpose, so a new screen can't forget. The mode is passed as a
value, not branched on (a branch in a `@ToolbarContentBuilder` changes structural
identity). `.buttonStyle(.plain)` on the button does nothing — the capsule
belongs to the `ToolbarItem`. There is no View-level API for this. In
Performance mode every toolbar button is therefore a bare glyph.

**The system back button's capsule is out of `modeToolbar`'s reach.** Only a
global `UINavigationBarAppearance.backButtonAppearance` could touch it, which
would apply in both modes and fight `modeNavigationChrome`. Checked 2026-09-01
and not observed. Don't reach for it without reproducing first.

**A pinned toolbar background and a large title are mutually exclusive on iOS
26.** `modeNavigationChrome` takes a `ModeTitleStyle` that must match the
screen's real `navigationBarTitleDisplayMode`: `.inline` gets the pinned opaque
bar, `.large` gets a colour-only bar that lets the title show. **When a helper's
doc comment already states a constraint, honour it per call site rather than
changing the helper for everyone** — dropping it everywhere regressed two screens
(`af3187d`, corrected in `a783931`).

**`PlaybackClock` is held as a plain `let`.** Making it `@Published`, or adding a
`currentTime` passthrough on the controller, puts the 1 Hz rebuild of every tab
straight back. Views that draw the position observe the clock in their own small
view.

### Lists, swipes, buttons

**A swipe action that only raises a confirmation must not carry
`role: .destructive`.** The role makes UIKit animate the row away before the
prompt appears. State `.tint(.red)` instead. Actions that really do remove their
row (the detach actions) keep the role.

**Delete is red, detach is blue.** The root `.tint(palette.accent)` outranks the
destructive role's colour, so delete states `.tint(.red)` — a platform
convention, not themeable. The user ruled: *"I will not veto the detach swipes
being blue. I like it that way."* Settled — don't re-offer.

**Don't hand-roll a gesture that competes with `List`'s own recognizers.** The
custom `LikeSwipe` produced three defects and no benefit the user valued, and was
deleted: *"I really don't think changing the length of a swipe calls for
inventing an entirely new library."* The leading swipe uses UIKit's own
threshold (~two-thirds of the row). **Do not rebuild it.**

**Never measure a List row with a `GeometryReader` that writes `@State`.** The
write lands during cell configuration and can leave `swipeActions` unbuilt on the
first rows of a cold launch.

**Never put a custom `ButtonStyle` in a List's environment.** `swipeActions`
builds its actions from the `Button`s you declare, and with a custom style in
scope it produces *none*. Buttons inside lists use `accentAction(theme)`.

**An explicit `foregroundStyle` outranks `.tint`.** That's why the palette goes
on list content, not the app root — at the root it repainted every toolbar button
in the text colour.

**An SF Symbol does not inherit a foreground style set on its enclosing
`Button`; a `Text` does.** Colour toolbar glyphs on the `Image`, via
`ToolbarGlyph`; text buttons use `.toolbarTint()`. (UIKit dims the presenting
view controller's tint while anything is presented over it.)

**Test presentation dimming in Standard mode.** Performance mode has no
presentation animation to see it in.

**`EditButton` is not used anywhere.** It drives whatever `editMode` it finds
rather than the one the toolbar reads. `PlaylistDetailView` owns its `editMode`
and binds it to the list itself. `onDelete` came off the playlist's `ForEach`
because its red circles collide with the selection ticks; swipe still offers
Remove.

**Playlist selection is keyed by `PlaylistEntry.id`**, not the song — a playlist
may hold the same song twice.

**Toolbar item budget on a pushed screen:** four compact trailing icons alongside
a *short* inline title. Five, or four with a long name, truncate it. Screenshot
with a long name before believing it fits.

**Settings pushes by value.** **Delete confirmations show only a Delete button.**
**Sliders mean edit, a pencil means rename.**

**Tapping the selected swatch clears the colour.** "No colour" means "draw in the
theme accent", a real state that needs a route back.

**`EntityColorPicker` observes the object, not a binding to its colour.** A bare
binding changes the store but publishes nothing.

### Playback and player

**The mini bar is the only way into the full player.** Tapping a song plays it
and stays put. One player screen, one design, dismissed by a leading chevron.

**Don't trust `Slider.onEditingChanged` for "the drag ended" on iOS 26.** It
never arrives on the fluid slider. Any control that needs to know when a finger
lifted should own its own `DragGesture`.

**`ScrubBar` uses `highPriorityGesture`, not `gesture`.** It lives in a
`ScrollView` and a slightly diagonal scrub would otherwise be handed to the
scroll view mid-gesture. (Fine because it is not in a `List`.)

**A `play()` re-issue after setting `AVAudioPlayer.currentTime` is not needed.**
Tested with the line disabled: playback resumes on its own. Don't re-add it.

**The play/pause icon swaps instantly** via `instantSymbolSwap` in both modes —
SF Symbols otherwise cross-fade when the name changes.

### Import and sharing

**Multi-file sharing needs a share extension. Full stop.** The document-types
route delivers one URL, measured at the scene-delegate level. And **iOS will not
let a share extension launch its host app** — both `NSExtensionContext.open` and
the responder-chain fallback are refused, so the extension shows a card and the
user switches over themselves. The app drains the shared inbox on launch, on
foreground, and on `localplayer://import`.

**Ordering matters in the extension.** Calling `completeRequest` before the
asynchronous `open` tears the extension down and the open never lands.

**One `PBXFileSystemSynchronizedRootGroup` can be listed in two targets'
`fileSystemSynchronizedGroups`**, which is how `Shared/` reaches both.

**`AudioFileStore.stageFile` must not delete its source unconditionally.**
`AudioFileStore.Origin` decides; only the picker's temp copies, the app's own
`Documents/Inbox`, and the share extension's shared inbox are disposable.

**An incoming share must not enter the scanning phase while the review sheet is
open.** `phase` leaving `.reviewing` makes `isPresentingReview` false, which the
sheet's dismissal binding reads as the user closing it.

**Incoming URLs are buffered for 400ms before staging.** Otherwise sharing four
songs opened the review sheet four times, each throwing away the last.

**`onOpenURL` selects the Library tab first.** The review sheet hangs off
`LibraryView`, and presenting from a non-visible pane puts it over the wrong
screen.

**Parser rules are deliberately narrow, each guarded by the case that would
break it.** `AC/DC`, `20 ft Under`, `Level 42`, `Sum 41` all survive.
**`ワールドイズマイン CPK! Remix` keeps its remix name** — trailing remix credits
are not stripped. Settled.

### Smart playlists

**Tag exclusions use `SUBQUERY(...).@count == 0`,** not `NOT (ANY tags.id == x)`.

**Untagged joins the tag group rather than standing as its own clause**, so the
Any/All mode governs it. "All" plus Untagged is a contradiction, and the editor
says so in the section footer instead of silently returning nothing.

**`SmartPlaylistDetailView` renders an array, not a `@FetchRequest`.** A rule can
end in a random sample, which no single request expresses.

**A smart row's length comes from `SmartPlaylistEngine.summary`**, a
durations-only dictionary fetch, refreshed on every context save. A random
sample that the limit trims has no fixed length, so it shows `~` and the
sample size × the average match. CarPlay's smart rows show count · length
instead of the rule summary — "how much" matters more than "how it's built"
when picking something in the car.

### Queue and Up Next

Settled with the user on 2026-09-29 — don't re-ask:

- **Tapping a song still replaces the whole queue**, queued songs included.
  There is no separate user queue.
- **Queueing a song that's already queued adds a copy**; it doesn't move it.
- **Up Next is edited in the player, which is a `List` (option B).** Option A,
  a separate queue-editor sheet, was the fallback and wasn't needed.

How it works, and why:

- **With shuffle off, `orderedQueue == queue` at all times**, and every edit
  relies on it (`moveInQueue` copies `queue` over). Play Next inserts after the
  playing entry in *both* orders, so turning shuffle off keeps the songs next.
  Play Last appends to both and is never shuffled in. A move made with shuffle
  on changes play order only — turning shuffle off goes back to browse order.
- **With nothing loaded, Play Next / Last just start playback**, and no toast is
  posted — the mini bar appearing is the confirmation.
- **The playing row can't be removed from Up Next** (no swipe on it). Removing
  it would be "stop" by another name.
- **Reorder is long-press-and-drag with no edit mode.** An `EditMode` toggle
  would show handles but turn row taps into selection and swipes into red
  circles. Remove is a detach, so it keeps `role: .destructive` and comes out
  blue like every other detach.
- **The Up Next header is a row, not a section header.** A plain list pins
  headers and draws a background behind them.
- **`UpNextHeader` observes `PlaybackClock` itself** — same reason as
  `ProgressSection`. Don't read the clock in `NowPlayingView.body`.
- **`QueueNotice` is its own object**, not state on `PlaybackController`, so a
  toast only invalidates the toast.
- **The queue swipe buttons sit inside each row's existing
  `.swipeActions(edge: .leading)`**, after Like (so a full swipe still likes). A
  second `.swipeActions` on the same edge risks one replacing the other.
- **`moveInQueue` hand-rolls the move** rather than importing SwiftUI into the
  playback layer for `move(fromOffsets:toOffset:)`.
- Re-checked after the `List` rebuild (2026-10-01): Performance bar stays pure
  black with artwork scrolled under it, chevron pixels identical (0,153,255) at
  rest and mid-scroll, scrubbing a slightly diagonal drag doesn't scroll the
  list, shuffle on → off restores order with queued songs kept.

### Tag suggestions

Settled with the user on 2026-10-01 — don't re-ask:

- **Suggest, never apply.** Suggestions are shown unticked; nothing is tagged
  unless the user picks it. The Settings toggle only pre-ticks them — they still
  pass through a review screen before anything is written. The reason: a wrong
  tag silently changes smart playlists, CarPlay ones included.
- **Only existing tags are ever suggested.** The model answers through a
  `DynamicGenerationSchema` whose items are `anyOf` the tag display names, so it
  can't emit anything else — no validation or fuzzy matching afterwards.
- **The user's tags are genre and language** (jpop, japanese, classical,
  english, rap, EDM, videogame, vocaloid…), which is why title/artist/album is
  enough input. Mood/activity tags would not suit this approach.

How it works, and why:

- **Artist history first, model second, merged.** A tag qualifies from history
  when at least half of the user's tagged songs by any credited artist carry it.
  `artistKeys` splits "feat." / "&" / "x" / "," credits, so a Teto feature by a
  new producer still picks up how the user tags Teto.
- **The prompt carries up to two of the user's own tagged songs per tag** (max
  24) as examples. Suggestions get noticeably better once a library has some
  tagging — the zero-history import missed `vocaloid` on two Teto/Miku songs.
- **One `LanguageModelSession` per song.** A long-lived one would carry every
  song in its transcript and overflow the context window mid-batch.
- **Greedy sampling**, so the same song gets the same answer.
- **Any model error just means no model suggestions** for that song — guardrail
  refusals, unsupported locale, a busy model.
- **Import suggestions live in `ImportCoordinator.suggestions`, not on the
  draft.** Accepting copies the name into `draft.tagNames`. One background task
  asks for each draft in turn; a second share joining the sheet restarts it and
  skips drafts already answered. Commit cancels it.
- **Import rows push the editor by tap, not `NavigationLink`.** A link claims the
  whole row; the chips need their own taps (`.buttonStyle(.borderless)` per chip,
  never on the list). Swipe-to-delete re-checked after the change.
- **No new model version.** Nothing is stored — suggestions are recomputed.

---

## Known issues / open items

- **Move-or-delete-the-original on import is deliberately not built.** Deferred
  on 2026-08-31 — *"we might not be done with testing just yet"* — because
  copy-only is what allows repeat imports and deletions. To finish it: switch
  `DocumentPicker` to `asCopy: false`, hold the security scope from pick through
  commit, and delete on successful commit only. **Ask first whether it should
  move or delete, be a setting or the default, and confirm per file or run
  silently** — this is the one feature that destroys data if it is wrong.
- **The share extension cannot bring the app forward.** Not fixable from the app
  side. Worth re-testing on a physical device.
- **The large-title bar is clear at rest, by design.** Tag and smart-playlist
  detail screens trade a pinned bar for a visible title. Content scrolling under
  them takes `theme.background` rather than a material.
- **`RootView` still rebuilds on every song change.** It observes `playback`
  only to re-inject it into the Now Playing presentation, and rebuilds all four
  panes when `currentSong` or `isPlaying` publishes. User-initiated and rare, so
  left alone.
- **The `ArtworkCache` key still calls `data.hashValue` on every render.** The
  one main-thread cost left in that path.
- **The play/pause fade removal was never visually confirmed frame-by-frame.**
- **The rule migration path has never met real data.**
- **The `colorHex` migration has only met the simulator's store.**
- **The Library's toolbar collapses sort and import into a "..." menu while
  selecting.** Pre-existing.
- **No test target.** Worth re-offering; the parser regressions are a ready-made
  first suite. **This is the largest remaining item the user has not picked up.**
- **Drag-to-reorder is unverified by automation.** Synthetic touch paths couldn't
  reliably drive the gesture. Worth a manual check.
- **CarPlay entitlement not requested.** Manual approval from Apple
  (https://developer.apple.com/contact/carplay/), once the app is otherwise
  complete. `localmp3player.entitlements` intentionally lacks the key — adding it
  without a matching provisioning profile breaks device signing. CarPlay paths
  are untested.
- **Performance mode's player is genuinely full screen** (no card, no inset)
  since `cb46a92`. Flagged with the veto offered; not ruled on.
- **Unverified on the simulator:** the `~` random-sample length (the toggle
  taps raced the screenshot lag), and the playlist-reorder fix for a playlist
  holding a song twice (`Jjj` has no duplicates). Both are small; worth one
  manual look.
- **The queue isn't persisted.** A relaunch (including every `simctl install`)
  empties it. Pre-existing; not asked for.
- **The selection bar's queue menu is a system menu**, so it draws glass in
  Performance mode — same as the Library's sort menu. No View-level way off.
- **The iOS 26.5 simulator can't run the model.** It reports Apple Intelligence
  available, but every request fails inside the safety filter
  (`SensitiveContentAnalysisML` → `ModelManagerError 1001`, asset not found),
  with default and permissive guardrails alike. The Mac itself answers fine
  (checked with a script), and so does an **iOS 27.0 simulator** — that's where
  the model path was verified. On the 26.5 sim only the artist-history half
  works, silently.
- **Tag suggestions are untested on the iPhone 16.** Expect it to behave like the
  iOS 27 simulator; worth one import and one Suggest Tags run on the device.
- **Suggestions aren't recomputed after editing a draft's title/artist** in the
  import editor. Small; not asked for.
- **With auto-tick on, a suggestion arriving while that draft's editor is open is
  dropped on Done** (the editor writes back its own copy). Edge case; left.
- **Announce Notifications** was reported as "text to speech turned on" while
  listening. Not the app — no app can enable it. Not re-confirmed by the user.

## State of the simulator's test data

As of 2026-09-01, re-checked 2026-10-01 (unchanged — five tags were added for
the suggestion test and deleted again, with no songs ever put in them):

- **Library: 25 songs.**
- **One tag, `Classical`, holds 9 songs** — Swan Lake Suite, The Nutcracker
  Suite, and 7 added on 2026-09-01 to make a pushed screen scroll ('I'm Bach',
  逆さ月, トリックハート, はぐ, Bandits [Remix], Birdbrain (HEV mix), Bumpin').
  The user was told. It is the *only* pushed screen with enough content to
  scroll. **Ask before undoing this — it is useful fixture.** The tag has the
  default colour, so a colourless tag is still needed to exercise the nil-colour
  accent fallback.
- **One playlist, `Jjj`, with 4 songs** — created by the user. There is no smart
  playlist and no custom palette.
- **`Documents/TestSongs`** — the original four only. The repo's `testSongs/` is
  the current set of 25; the container copy was not refreshed.
- **`Documents/TestFiles`** — six filename-parser fixtures, silent tone files
  with no ID3 tags.
- **Fastest way to load the simulator library** — copy files straight into the
  app's own inbox and relaunch; the app collects it on becoming active, and the
  review sheet comes up with the whole batch:

  ```bash
  cp testSongs/*.mp3 "$(xcrun simctl get_app_container <UDID> com.lin.localmp3player data)/Documents/Inbox/"
  ```

  Files placed there are consumed and deleted by design — copy, never move.
- Last known state (2026-10-01): Standard mode, dark, default blue accent. No
  smart playlist (one was made and deleted to test the row).

**The simulator is the larger library** — 25 songs against nine on the iPhone 16
at last count. Ask which device a report came from.

## Working notes for the simulator

- Simulator: **iPhone 17, `D4DACBFD-572D-42AB-96AF-6FD72E2A3562`** (iOS 26.5).
  **Apple Intelligence testing: "iPhone 17 (iOS 27 AI test)",
  `DD15D551-47A9-45ED-A4DD-9D86CAA42588`** — created 2026-10-01 because the 26.5
  sim can't run the model. Throwaway library: the 25 test songs, six tags
  (Classical, EDM, english, japanese, rap, vocaloid) applied from suggestions,
  and "Tick Suggestions Automatically" left **on**. On it, a plain tap doesn't
  flip a `Toggle` — drag across the switch instead.
  Device: **iPhone 16, `EFEEEBD5-61F7-5EEF-AEAD-A1F827571239`**.
- **Native screenshots are 1206 × 2622; point space is 402 × 874** — a clean
  **×3**. The simulator tool returns a resized image with a different ratio;
  **use `xcrun simctl io ... screenshot` and divide by 3** when you need
  pixel-accurate coordinates. `control` action `attach` reports point dimensions.
- **Measure the pixels to settle a colour question.** Screenshots looked at by
  eye did not settle the chevron bug; sampling the capsule at three scroll
  positions did, in four calls. `sips -Z 500` to look, and a small Swift
  `NSBitmapImageRep` tool to read exact values (built in a scratchpad; not in
  the repo).
- **`touch_path` beats `swipe` for controlled scrolling.** A `swipe` flings and
  overshoots by hundreds of points. A five-point `touch_path` with `dt_ms` of
  150–400 and a repeated final point lands roughly where aimed.
- **Horizontal swipes need a duration.** `swipe` with `duration: 0.8` works. A
  swipe or drag starting within 4pt of a screen edge performs the OS edge gesture
  instead — start further in.
- **A tab remembers where you left it**, so tapping a tab may land on a pushed
  detail screen. Screenshot before tapping by coordinate.
- **The mini bar shifts every row below it**, and it sits *above* the tab bar —
  aim for its vertical middle (~757pt in Performance), not its top edge.
- **Performance mode changes the bottom bar's layout** — captioned icons at
  y≈819 rather than the Standard pill row at y≈808. Screenshot after switching.
- **Tapping the Library search field opens the keyboard and a paste menu.** Two
  taps to get back out. Aim at song rows, not the top of the list.
- **The user tests alongside you in the same simulator.** Don't assume the app
  state is yours.
- **The simulator tool's screenshots lag taps by ~1s.** Two taps on a toggle
  with a screenshot between them can land as on-then-off. Tap once, wait, then
  screenshot; `xcrun simctl io ... screenshot` is current.
- **A redeploy stops playback** (the app relaunches), so any queue test starts
  from an empty queue.

## User preferences observed

**Verify the running bundle, every time.** Two DerivedData directories and the
stale-bundle trap mean "BUILD SUCCEEDED" proves nothing.

**They diagnose their own bugs, and the diagnosis is usually right.** On the
chevron bug they supplied screenshots and a non-monotonic description that *was*
the mechanism, while the previous session's theory was wrong. **Take the symptom
report as the specification and go measure it.** Their reports are precise and
worth taking literally.

**If a suggestion of theirs would cost more in future complexity than it buys,
say so with concrete consequences and let them reconsider — before building it.**
*"If I make a bad suggestion that may add more complications in the future than
good, tell me the potential consequences and I'll reconsider."*

**Offer a ranked list, not a menu.** Rank by value, name what is waiting on them,
and name what to leave alone and why — they act on all three.

**They will ask about things that turn out not to be the app.** Answer the
question on its merits rather than hedging or hunting for an app-side cause.

**Performance Mode is a general efficiency mode, not a driving mode.** It's an
mp3 player that happens to support CarPlay well. Keep UI copy neutral.

**Fix causes, not symptoms** — band-aid fixes get called out. Tell them what was
deliberately left out and why.

**Consistency across screens is a stated priority** — the reason the toolbar fix
went to all 19 toolbars rather than one.

**Small proactive fixes adjacent to the request are welcome** — flag them and
offer the veto rather than asking first. When a judgment call is offered the
answer tends to be "if you think it's better, go for it".

**Pushes are authorized per batch, not standingly.**

**They notice accumulated cruft and will ask for it to be cleaned up.** Code
bloat is a reason to reject an approach.

**They are relaxed about test data** — "it's for testing anyways" — but that is
forgiveness after the fact, not licence. Flag changes to it in the same message.

---

## Session log

Newest first.

### 2026-10-01 (second) — tag suggestions with Apple Intelligence (`8dc4ef7`)

The user asked whether Apple Intelligence could assign existing tags to songs.
Agreed: suggestions only (unticked chips), plus a Settings toggle to pre-tick
them. Built `TagSuggester` (artist history + Foundation Models with a
schema-constrained answer), suggestion chips in the import review sheet and
editor, "Suggest Tags for Each Song" from the batch Tag sheet, and a Tag
Suggestions section in Settings. See **Decisions ▸ Tag suggestions**.

Verified on a new iOS 27 simulator: 25-song import got sensible tags at ~1.5s a
song; chips toggle without opening the row; Add All; editor chips; commit; the
existing-songs screen (artist history added `vocaloid` to はぐ from MIMI's other
songs); auto-tick on both paths; swipe-to-delete on the review sheet. Tried
first on the 26.5 simulator — the model fails there (see Known issues).

### 2026-10-01 — queue actions and total length (`cabbf17`, `f80954c`)

Built the whole plan from 2026-09-29. `cabbf17`: total length on rows, detail
screens and CarPlay. `f80954c`: queue entries, Play Next / Play Last (swipe +
selection bar + toast), Now Playing rebuilt as a `List` with an editable Up
Next. Option B held up; no fallback to A. Adjacent fix folded into `f80954c`:
`Playlist.reorder` keyed entries by song, so a song held twice collapsed onto
one entry — now reorders by entry. Toast first used `modeCard`'s thin material
and text read through it; `modeCapsule` (regular material) added. Simulator
left in Standard mode as found; a temporary smart playlist was created to check
the row and then deleted. Not pushed.

### 2026-09-29 — planning only, and this file

No code. Planned queue actions (Play Next / Play Last / edit Up Next) and total
playlist length — built 2026-10-01; see **Queue and Up Next**. Folded the eight dated handoffs into this
single file and added `CLAUDE.md` pointing here.

### 2026-09-01 — toolbar glass in Performance mode (`cc0e29e`)

The Performance-mode player's return chevron changed colour while scrolling. The
glyph never changed; iOS 26's glass capsule behind toolbar buttons samples the
scroll content (measured rgb(25) → rgb(46) → rgb(25) as the artwork passed
under). Fixed for all 19 toolbars via `modeToolbar`. The 2026-08-31 theory
(toolbar-chrome cross-fade) was wrong. Also checked the back button on pushed
screens: not affected.

### 2026-08-31 — delete animation, performance, Performance-mode chrome

- `59df086` — delete swipes no longer animate the row out before the prompt
  (dropped `role: .destructive` from prompt-only actions).
- `24b528d` — artwork decodes off the main thread; decoded images tagged with
  their key so recycled rows don't show the wrong cover.
- `21bbcf0` — `PlaybackClock` split off the controller, ending the 1 Hz rebuild
  of every tab.
- `af3187d` + `a783931` — nil tag colours fall back to the accent; large-title
  screens show their title in Performance mode; Library re-tap goes to root. The
  title fix was applied too broadly and corrected the same day.
- `3660fb9` — the three tab roots got an opaque bar in Performance mode.
- `899e2d3` + `cb46a92` — the player is a `fullScreenCover` in Performance mode;
  the first attempt (`interactiveDismissDisabled`) was superseded.
- Announce Notifications traced to an iOS setting, not the app.

### 2026-08-27 (second) — `LikeSwipe` deleted, delete is red (`c36d0b4`)

First rows of lists wouldn't swipe on cold launch: `LikeSwipe`'s
`GeometryReader` wrote `@State` during cell configuration. Deleted at the user's
call (net −94 lines). Destructive swipe actions now `.tint(.red)`; detach stays
blue. Two orphaned doc comments removed.

### 2026-08-27 — multi-file share, player entry, declutter (`697373c`)

Added the Share Extension target (iOS only ever delivered one URL through
document types). Removed the pushed player — the mini bar is the only way in.
Toolbar glyphs no longer grey out while something is presented (`ToolbarGlyph`).
Artwork upgrade became automatic. Settings lost the Upgrade Artwork row and the
privacy footer. `LibraryView.swift` split from 11 types into several files, and
duplicated selection bars and like helpers unified. Also added `LikeSwipe`
(deleted next session).

### 2026-08-26 — scrubbing, artwork size, yt-dlp tags, Open With

- `f064d8e` — committed Xcode's signing and bundle-id changes.
- `da09894` — the progress bar never seeked (`Slider.onEditingChanged(false)`
  never arrives on iOS 26); `ScrubBar` owns its gesture. Instant play/pause
  symbol swap.
- `ae29741` — cover art stored at 1024px instead of 320px.
- `8c44186` — yt-dlp downloads detected via `TXXX` source URL; Files ▸ Open
  With works.

### 2026-08-25 (second) — Select everywhere, edit mode, colours

- `5605984` — Select with Select All/None on Playlists and Tags; swiping Delete
  inside a tag no longer deletes the file (`SongRemoval`); Untagged criterion.
- `68b32e9` — tag and playlist detail share one edit mode (rename, colour,
  selection); playlists and smart playlists carry a colour (new model version);
  re-tapping a tab returns to root.

### 2026-08-25 — smart playlists rebuilt, repo restructured

- `b0285ea` — `SmartRule` with include/exclude/except for tags and artists;
  swipe actions; delete confirmations; `SongEditor`; appearance reaches every
  screen; dark by default.
- `01627f4` / `648f8e9` — wrapper directory collapsed (repo root moved up a
  level), specs brought into `docs/`, `DEVELOPER_DIR` requirement dropped.

### 2026-08-23/24 — MVP (`1765612`, `097fb4f`, `de1d2bd`)

Initial build: import, duplicates, tagging, playlists, playback, shuffle/repeat,
appearance, Display Mode, CarPlay browse. Then fixes for silent import loss, a
smart-playlist crash, stuck-grey controls, and Performance-mode animation.
