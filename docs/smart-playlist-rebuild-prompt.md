# Claude Code Prompt: Rebuild the Smart Playlist Rule System

## What's wrong with the current implementation

The current Smart Playlist builder treats filtering as **one mode at a time**: a "Filter By" picker that switches between Tag and Artist. That is the wrong model. A single smart playlist must be able to filter on tags **and** artists **simultaneously**, with include and exclude criteria for each, all active at once.

The root cause is the data model, not the UI. The `SmartPlaylist` entity currently stores a single `ruleType` enum plus one set of IDs, so it structurally cannot hold more than one criterion. **Fix the Core Data model first, then rebuild the UI on top of it.** Do not attempt to patch the existing UI over the existing single-rule schema.

## New Data Model

Replace the `SmartPlaylist` entity's rule fields entirely. Write a lightweight Core Data migration for any existing smart playlists (a best-effort mapping of each old single rule into the equivalent new field is fine; dropping unmigratable ones is acceptable, but do not crash on launch).

### SmartPlaylist
- `id`: UUID
- `name`: String
- `dateCreated`: Date

**Tag criteria**
- `includeTagIDs`: [UUID] — empty means "no tag include filter"
- `includeTagsMatchMode`: enum `.any` / `.all` — whether a song needs any one of the included tags or every one of them
- `excludeTagIDs`: [UUID] — empty means "no tag exclusion"

**Artist criteria**
- `includeArtists`: [String] — empty means "no artist include filter". Matched against `Song.artist`, case-insensitive. Always ANY (a song has exactly one artist, so an "all" mode is meaningless — do not add one).
- `excludeArtists`: [String] — empty means "no artist exclusion"

**Exclusion override**
- `exceptIfHasTagIDs`: [UUID]
- `exceptIfHasArtists`: [String]

**Optional behavioral filters** (all optional, all compose with the above — nil/false means "not applied")
- `notPlayedInDays`: Int?
- `addedWithinDays`: Int?
- `onlyLiked`: Bool
- `resultLimit`: Int? — with `sortBy`: enum `.mostPlayed` / `.recentlyAdded` / `.title` / `.artist` / `.random`

Every one of these fields is independently optional and they all apply together. There is no mode, no either/or, no picker that disables one group when another is used.

## Matching Logic — implement exactly this

A song qualifies for the playlist if **all** of the following pass. Any criterion that is empty/nil automatically passes.

1. **Tag include** — if `includeTagIDs` is non-empty: with `.any`, the song has at least one of those tags; with `.all`, the song has every one of those tags.
2. **Artist include** — if `includeArtists` is non-empty: the song's artist matches one of them (case-insensitive).
3. **Behavioral filters** — if set: `lastPlayed` is nil or older than `notPlayedInDays`; `dateAdded` is within `addedWithinDays`; `isLiked` is true when `onlyLiked` is set.
4. **Exclusion check** — the song is removed if it matches `excludeTagIDs` (has any of those tags) **or** `excludeArtists` (artist matches any of them), **unless** it also matches the override: it has any tag in `exceptIfHasTagIDs` or its artist is in `exceptIfHasArtists`. The override rescues a song from exclusion only.

**Critical semantics — do not deviate:** the override applies *only* to step 4. It never rescues a song that failed the include criteria in steps 1–3.

Worked example — Must Have tag "2000s", Must Not Have tag "rap", Except If Has artist "Eminem":
- A 2000s Eminem rap song → **included** (excluded by "rap", rescued by the Eminem override)
- A 1990s Eminem rap song → **excluded** (fails the "2000s" include; the override does not apply)
- A 2000s rap song by another artist → **excluded**
- A 2000s pop song → **included**

Write unit tests covering these four cases plus: include-only with no exclusions, exclusion with no override set, `.any` vs `.all` tag include behavior, and simultaneous tag + artist criteria on one playlist.

Evaluate rules live via `NSFetchRequest` predicates at query time. Never store a static resolved song list.

## UI Requirements

Remove the "Filter By" mode picker entirely. Replace the rule editor with a **single scrolling form where all criteria groups are visible at once**, in this order:

1. **Playlist name**
2. **Must Have** — tag chips and artist chips together in one section, with an Any/All toggle that applies to tags only (label it clearly as applying to tags)
3. **Must Not Have** — tag chips and artist chips together
4. **Except If Has** — tag chips and artist chips together; visible only once something has been added to Must Not Have, with a short inline explanation like "Songs matching these are kept even if excluded above"
5. **More Filters** — collapsed by default: not played in X days, added within X days, liked only, limit + sort

Interaction rules:
- Tags and artists coexist in every section. There is never a moment where choosing a tag prevents adding an artist, or vice versa.
- Adding a criterion: tap an "Add" button in that section → a single searchable multi-select sheet with two segments (Tags / Artists) → check multiple items across both segments → Done adds them all at once. Do not require a separate trip through the sheet per item.
- Artists are picked from artists already present in the library; tags from existing tags. Both lists must be searchable — do not use a raw picker wheel or an unfiltered long list.
- Selected criteria display as removable chips with a tap-to-delete affordance, colored by the tag's `colorHex` where available.
- Show a **live match count** at the bottom of the form ("142 songs match") that updates as criteria change, with a tap-through to preview the matching songs. This is the single most valuable thing for making the rule builder feel understandable — prioritize it.
- Saving requires only a name; a playlist with no criteria is valid and simply matches everything.
- Editing an existing smart playlist opens this same form fully populated — no separate create-vs-edit code path.

## Constraints
- Respect the existing Performance / Standard UI mode toggle: the chip and sheet UI must render acceptably in Performance Mode with no blur materials or elaborate transition animations.
- Smart playlists must remain fully browsable from CarPlay via `MPPlayableContentDataSource`, exactly as accessible as manual playlists. Verify the new multi-criteria playlists still populate the CarPlay browse tree correctly after this change.
