# ThreadKeep

ThreadKeep is a local-first macOS conversation archive app built with Swift, SwiftUI, PDFKit, and SQLite. It imports user-provided Messages PDFs or structured JSON archives, stores them locally, indexes message text for search, renders threads in a Messages-inspired transcript view, and exports the current thread as a searchable PDF.

## What is implemented

- Native macOS SwiftUI app shell with a sidebar library and thread detail view
- Messages-on-Mac PDF import flow using PDFKit text extraction and transcript reconstruction
- `Import Messages` flow that automatically scans the local Messages store and imports one thread as a snapshot archive
- Documented JSON import format for `ConversationArchive`
- Parsing and validation with readable import errors
- Local SQLite persistence with FTS5-backed full-text search
- Library filters for keyword, date range, participant, and attachment presence
- Thread transcript rendering with day grouping, incoming/outgoing bubbles, timestamps, sender labels, attachment cards, and highlighted in-thread search
- Search result snippets with jump-to-message navigation
- Searchable PDF export in review and memorial styles
- Local-only privacy messaging in the UI
- Bundled sample archive JSON for immediate demo data

## Architecture

`Sources/Threadkeeper/App`
- App entry point and shared `AppViewModel`

`Sources/Threadkeeper/Import`
- JSON DTOs, parser dispatch, Messages PDF importer, timestamp handling, and validation

`Sources/Threadkeeper/Database`
- Plain SQLite storage, schema migration, import mapping, deletion, and search queries

`Sources/Threadkeeper/Models`
- Normalized app/domain models used by the UI, search, and export layers

`Sources/Threadkeeper/Views`
- SwiftUI library, import, settings, and transcript screens

`Sources/Threadkeeper/PDF`
- Text-based PDF renderer so exported transcripts remain selectable/searchable

## Data model

SQLite tables:

- `threads`
- `participants`
- `thread_participants`
- `messages`
- `attachments`
- `message_attachments`
- `message_reactions`
- `message_fts`

`message_fts` uses SQLite FTS5 for fast full-text lookup and snippet generation. The original imported file, whether PDF or JSON, is also copied into the app's local Application Support directory so users can re-export it later.

## Recommended import workflow

1. In Messages on Mac, open the conversation you want.
2. Choose `File > Print`.
3. In the print dialog, choose `PDF > Save as PDF`.
4. Import that PDF into ThreadKeep.

ThreadKeep treats this as the primary user-friendly import path. JSON import is still available for advanced or pre-structured archives.

## Messages on This Mac

ThreadKeep also includes a direct importer for the local Messages database on a Mac:

1. Click `Import`.
2. Choose `Import Messages`.
3. ThreadKeep automatically looks for your local Messages database and loads the available conversations.
4. If automatic detection needs help, choose the `~/Library/Messages` folder manually.
5. Pick a thread from the scanned list and import it.

This path aims to get as close as possible to “import the whole thread from the beginning,” but the imported coverage depends on what message history is currently present on that Mac. If Messages in iCloud has not downloaded older history locally, ThreadKeep cannot import messages that are not actually stored there yet.

## JSON import shape

Top-level fields:

- `thread_id`
- `thread_title`
- `participants[]`
- `messages[]`
- `attachments[]`

Message fields:

- `id`
- `sender_id`
- `sender_display_name`
- `is_outgoing`
- `body_text`
- `timestamp` (ISO 8601)
- `service`
- `attachment_ids[]`
- `reply_to_message_id` optional
- `reactions` optional
- `metadata` optional

Attachment fields:

- `id`
- `type`
- `filename`
- `local_path` optional
- `mime_type` optional
- `thumbnail` optional
- `url` optional

See [`sample-studio-archive.json`](Sources/Threadkeeper/Resources/sample-studio-archive.json) for a working example.

## Build A Release App

From the project root:

```bash
./scripts/build-release-app.sh
```

This builds the executable in Release mode using a stable SwiftPM cache path and packages a reproducible app bundle at:

```bash
dist/ThreadKeep.app
```

SwiftPM build intermediates are stored in:

```bash
~/Library/Caches/ThreadkeeperBuild/swiftpm
```

You can override that cache location by setting `THREADKEEPER_BUILD_CACHE` before running the script.

You can open it locally with:

```bash
open dist/ThreadKeep.app
```

## Build A Tester DMG

From the project root:

```bash
./scripts/build-tester-dmg.sh
```

This will:

- build the Release app
- package `ThreadKeep.app` into a tester-friendly DMG
- include a short `Read Me First.txt`

The output lands in:

```bash
dist/ThreadKeep-<version>-Apple-Silicon.dmg
```

The DMG contains:

- `ThreadKeep.app`
- `Applications`
- `Read Me First.txt`

The tester app is still:

- ad-hoc signed
- arm64 only
- not notarized

## Running From Source

1. Open `Package.swift` in Xcode.
2. Select the `Threadkeeper` executable target and run it as a macOS app.
3. Or build from Terminal with `swift build`.

## Current tradeoffs

- Messages PDF import is heuristic and depends on selectable PDF text exposed by the print export.
- Messages-on-This-Mac import is beta and depends on the current local Messages database schema and the history available on disk.
- Search uses FTS5 keyword/prefix matching today; phrase search and advanced search syntax are not exposed yet.
- Attachment rendering is intentionally local/archive-oriented and uses placeholders/cards instead of media previews.
- PDF export is text-based and printable, but not a pixel-perfect clone of the on-screen transcript.

## Best next steps

1. Improve Messages PDF reconstruction fidelity and add more importer adapters.
2. Expand search syntax with phrase, exact timestamp, and attachment filters inside a thread.
3. Add attachment previewing and a dedicated attachment browser.
4. Improve PDF pagination for very long messages and larger attachment appendices.
