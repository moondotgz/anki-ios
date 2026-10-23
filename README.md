# anki-ios

A native Anki flashcard app for iOS and iPadOS, written in Swift and SwiftUI with the iOS 26 Liquid Glass design. It syncs with AnkiWeb and reads and writes the same collection format as Anki desktop and AnkiDroid.

## Features

- **AnkiWeb sync** uses sync protocol v11, the same one current Anki desktop uses. It covers sign-in, incremental two-way sync, one-way upload and download for schema changes, account redirects, and media sync. A self-hosted Anki sync server also works.
- **Collection format.** The app stores an Anki schema 11 collection. Full downloads from AnkiWeb arrive in schema 18 and are converted, including the protobuf notetype, deck and deck-options data.
- **Scheduler.** A port of Anki's v3 SM-2 scheduler: learning and relearning steps, interval fuzz, ease changes, hard/easy multipliers, lapses and leeches, burying siblings, daily limits (including subdeck and parent limits), and day rollover.
- **Card rendering** handles Anki templates: fields, conditionals, `FrontSide`, `cloze` (including nested and hints), `type:` answers with a diff, `hint:`, `text:`, furigana filters, `[sound:]` audio, images, and notetype CSS with night mode.
- **Import and export.** It imports `.apkg` decks (including AnkiWeb shared decks) and `.colpkg` backups in all three formats Anki writes (legacy `anki2`, `anki21`, and zstd `anki21b`), and exports decks as `.apkg`. Before importing, it shows what the package contains: decks, note types, notes, cards, media, and how many notes you already have. You can choose whether to keep learning progress and when to update existing notes. If a media file name is already taken by a different file, the incoming file is renamed and the notes that use it are updated. You can open packages from the + menu, from Files, Safari or AirDrop ("Open in Anki"), or by dragging them onto the deck list on iPad.
- **Other tools:** add and edit notes (with images from Photos), a browser with Anki-style search (`deck:`, `tag:`, `is:due`, `flag:`, `prop:ivl>10`, …), deck options presets, statistics, undo, flags, bury and suspend.

## Building

The Xcode project is generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
brew install xcodegen
xcodegen generate
open AnkiSwift.xcodeproj
```

You need Xcode 26 or later; the deployment target is iOS 26. The only dependency is [zstd](https://github.com/facebook/zstd), which Swift Package Manager fetches.

### Install with SideStore or AltStore

Add this source in SideStore or AltStore (Sources → Add Source):

```
https://moondotgz.github.io/anki-ios/apps.json
```

Or open https://moondotgz.github.io/anki-ios/ on your iPhone and tap **Add to SideStore** / **Add to AltStore**. The page also links the latest IPA and lists previous builds.

### CI

`.github/workflows/build-ipa.yml` runs on GitHub's `xcode-27` runner. It generates the project, builds a Release app without code signing, and uploads `AnkiSwift-unsigned.ipa` as a workflow artifact. Every build gets a new version: `MARKETING_VERSION` in `project.yml` holds the major and minor (e.g. `1.0`), and the workflow run number becomes both the patch number and the build number, so build 42 is version `1.0.42` (`CFBundleVersion` 42). This way SideStore and AltStore always offer the update. Bump `MARKETING_VERSION` for a new major or minor release.

On pushes to `main` it also:

1. publishes the IPA as a GitHub release tagged `build-<run number>`, with the commit message as release notes;
2. rebuilds the source from all `build-*` releases with `scripts/make_source.py`, and deploys it to GitHub Pages together with the page in `site/`.

SideStore and AltStore sign the IPA when they install it. To sideload it another way, sign it yourself, for example with Sideloadly or `codesign`.

## Layout

```
AnkiApp/
  App/        app entry point, AppModel (collection, sync, import), keychain
  Core/
    Collection/     schema 11 storage, models, search, schema 18 conversion
    Scheduler/      v3 SM-2 states, queues, answering, stats
    Rendering/      template engine, cloze, card HTML
    Sync/           v11 sync client, collection sync, media sync
    ImportExport/   .apkg/.colpkg import, .apkg export
    Util/           SQLite, JSON, zstd, zip, inflate, protobuf, SHA-1
  Views/      SwiftUI screens (decks, study, editor, browse, stats, settings)
```

The code under `Core/` uses only Foundation, SQLite and zstd, so it also builds and runs on Linux. During development it was tested against Anki's own sync server (`python -m anki.syncserver`) and the official `anki` Python package. The tests covered full upload and download, incremental sync both ways, media sync, schema 18 conversion (the output matches Anki's own downgrade), and package import and export.

## Limitations

- FSRS: cards are scheduled with SM-2 even if FSRS is turned on in your collection. FSRS memory state already stored on cards is kept.
- The app can study filtered decks that come from sync but cannot create them.
- Changing a note type's fields or templates is not supported in the app; edit those in Anki desktop.
- MathJax is loaded from a CDN when a card contains `\(`…`\)`, so it needs a network connection.

Anki is a trademark of Ankitects Pty Ltd. This project is not affiliated with Ankitects.
