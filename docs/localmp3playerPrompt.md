# Claude Code Prompt: Local MP3 Player iOS App (MVP)

Paste this into Claude Code as your initial project prompt. It covers the full MVP scope discussed — CarPlay is the standout feature, so its section is intentionally the most detailed.

---

## Project Overview

Build a native iOS app in **Swift + SwiftUI** that functions like Spotify, but the entire song library lives locally on the user's device as mp3 files they import themselves. There is no backend, no server, no accounts, and no subscription — the app is entirely free and fully offline-capable. Core differentiators vs. existing local-library players (e.g. Doppler): a messy-filename-to-metadata cleanup tool, rules-based smart playlists, smarter duplicate handling, and a CarPlay experience that is a first-class citizen of the design, not an afterthought.

## Tech Stack

- Swift + SwiftUI (iOS 17+)
- **Core Data** for local persistence
- **AVFoundation** for playback
- **MediaPlayer framework**, specifically **`MPPlayableContentDataSource`** (see CarPlay section — this is the most important integration point in the whole app and should be architected for from the start, not bolted on later)
- `UIDocumentPickerViewController` for importing files from the Files app
- No third-party backend, no analytics SDKs, no network calls of any kind

## Data Model (Core Data)

Implement these entities exactly as specified — the field set is deliberate and each field maps to a specific feature below.

### Song
- `id`: UUID (primary key)
- `filePath`: String — path relative to the app's own sandboxed Documents directory. Imported files are **copied** into app storage, not referenced externally.
- `title`: String
- `artist`: String
- `album`: String? (optional)
- `duration`: Double (seconds)
- `artworkData`: Data? (optional, embedded thumbnail from ID3 or user-added)
- `dateAdded`: Date
- `lastPlayed`: Date? (nil until first play)
- `playCount`: Int (default 0)
- `normalizedKey`: String — computed on import: lowercased, punctuation-stripped `title+artist`, indexed, used only for fast duplicate lookup
- `originalFilename`: String — retained for debugging, never shown in UI
- `fileSize`: Int64
- `isLiked`: Bool (default false)

### Tag
- `id`: UUID
- `name`: String (unique, case-insensitive; store lowercase, display with preferred casing)
- `colorHex`: String? (optional, for tag chip color-coding on phone and CarPlay)
- `songs`: many-to-many relationship to Song

### Playlist (manual)
- `id`: UUID
- `name`: String
- `dateCreated`: Date
- `entries`: one-to-many relationship to PlaylistEntry

### PlaylistEntry (join entity — required because Core Data relationships don't preserve order)
- `id`: UUID
- `playlist`: relationship to Playlist
- `song`: relationship to Song
- `position`: Int

### SmartPlaylist (rule-based, evaluated live via NSFetchRequest predicate — never stores a static song list)
- `id`: UUID
- `name`: String
- `ruleType`: enum — `.tagInclude`, `.tagExclude`, `.notPlayedSince`, `.recentlyAdded`, `.mostPlayed`, `.liked`
- `tagIDs`: [UUID]? (used for tag-based rules; supports multiple tags)
- `thresholdDays`: Int? (used for `.notPlayedSince`)
- `resultLimit`: Int? (used for `.mostPlayed`, top N)

## Core Features

### 1. Import Flow
- Entry point: "Import" button opens `UIDocumentPickerViewController` scoped to audio files
- Selected files are copied into the app's sandboxed storage (not referenced via security-scoped bookmark)
- Each imported file is run through the filename parser (below) before being saved as a Song entity
- Support importing multiple files at once (batch import)

### 2. Filename-to-Metadata Parser
- Rule-based (not ML) parser that cleans up typical YouTube-download filenames, e.g. `Song Title - Artist (Official Video) [Audio].mp3`
- Strip common noise patterns: bracketed/parenthetical tags like `(Official Video)`, `[Audio]`, `(Lyrics)`, `(HD)`, `(Official Music Video)`, etc.
- Split remaining string on ` - ` to infer artist/title where possible
- Fall back to using the raw (cleaned) filename as the title if artist can't be confidently inferred
- Always show the parsed result in an editable confirmation UI before saving — user can correct title/artist/tags before committing
- Pull embedded ID3 tags first if present, and only fall back to filename parsing when ID3 data is missing or incomplete

### 3. Duplicate Detection
- On import, compute `normalizedKey` for the new file and check for an existing Song with a matching key
- If a likely duplicate is found, prompt the user with three options: **"Replace"**, **"Keep Both"**, **"Replace All"** (applies the replace decision to all remaining duplicates detected in the current batch import)
- Not fully automatic — always requires user confirmation except when "Replace All" has been selected for the batch

### 4. Tagging
- Manual multi-tag assignment per song (many-to-many via Tag entity)
- **Batch tag editing**: multi-select songs in list view, apply or remove a tag across the whole selection in one action

### 5. Playlists
- Manual playlists: user-created, manually ordered (via PlaylistEntry.position), drag-to-reorder
- **Smart playlists**, all rule types evaluated live:
  - Tag include (songs matching any/all of selected tags)
  - Tag exclude (`NOT (ANY tags.name IN %@)` predicate)
  - Not played in X days (`.notPlayedSince`, using `lastPlayed` vs `thresholdDays`)
  - Recently added (sort by `dateAdded` descending)
  - Most played (sort by `playCount` descending, limited by `resultLimit`)
  - Liked songs (`isLiked == true`)

### 6. Playback
- Standard AVFoundation-based playback: play/pause, skip, seek, queue management
- Update `lastPlayed` and increment `playCount` on each play
- Background audio playback support

### 7. UI Modes: Performance vs. Standard

Two selectable UI modes, toggled in Settings and persisted via `UserDefaults` (no need for Core Data — this is a lightweight app-level setting, not user data). Both modes render from the **same underlying views and data** — they differ only in a styling/animation layer, controlled by a single environment value or view modifier that swaps rendering behavior. Do not build two duplicate sets of screens.

- **Performance Mode**: minimizes CPU/GPU load. No translucency or blur materials, no "Liquid Glass" effects (iOS's translucent glass material system), no spring/parallax/over-the-top transition animations. Use flat colors, plain system list views, and short capped-duration cross-fades only where an animation is functionally necessary (e.g. confirming an action). Goal is the lowest possible battery and CPU draw — this matters especially for CarPlay use during long drives.
- **Standard Mode**: normal iOS visual polish is allowed — system materials, more expressive transitions — but should still avoid needlessly expensive custom rendering (no custom Metal shaders, no continuous/looping background animations, no animation that runs when off-screen). "Nicer, not wasteful."

Make Performance Mode easy to find and switch to from Settings; either mode can reasonably be the default.

## CarPlay Integration — Priority Feature

This is the app's core differentiator and should shape the browsing/data-access layer from the very start, not be retrofitted after the phone UI is built.

- Implement `MPPlayableContentDataSource` to expose the song/tag/playlist library to CarPlay's browse interface
- The browse hierarchy exposed to CarPlay should mirror the phone app's structure: Playlists (manual + smart) → Tags → Songs, with minimal taps required to start playback
- Smart playlists must be just as accessible from CarPlay as manual playlists — this is a primary use case, not a secondary one
- Design the tag/smart-playlist browsing UI on the phone with CarPlay's list/grid template constraints in mind from the start, so the same underlying data queries power both surfaces
- Implement `MPPlayableContentDelegate` for playback initiation from CarPlay selections
- Note for later: requesting the CarPlay audio-app entitlement from Apple is a separate manual approval step, done once the app is otherwise functional — flag this as a TODO but don't block MVP development on it

## Explicitly Out of Scope for This MVP
- Android / Android Auto support (planned for a later, separate port — do not build any cross-platform abstraction for this now)
- Any in-app song acquisition/downloading feature (app only ever imports files the user already has — do not build any YouTube-related functionality, this must stay strictly out of the app to stay App Store compliant)
- Monetization of any kind (no IAP, no subscription, no ads — app is free)
- Cloud sync / accounts / social features

## Suggested Build Order
1. Core Data model + basic song list UI
2. Files import flow + filename parser + confirmation UI
3. Duplicate detection flow
4. Manual playlists + tagging + batch tag editing
5. Smart playlists
6. Playback engine (AVFoundation) wired to the full library
7. CarPlay (`MPPlayableContentDataSource` / `MPPlayableContentDelegate`)
8. Performance/Standard UI mode toggle (styling/animation layer over existing views)
9. Polish pass, then Apple Developer Program enrollment + CarPlay entitlement request in parallel
