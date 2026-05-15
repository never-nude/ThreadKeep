# Claude Code Handoff — iMessage-Parity Pass

This is a follow-up to `CLAUDE-CODE-HANDOFF.md`. The user (Mike) installed the Phase 1 build, opened the import sheet, and saw a list of raw phone numbers (`3088987692`, `+19145550623`, `+19145197924`, …) where Messages.app would have shown contact names. He has explicitly asked that the experience be "as close to the experience of using iMessage on the computer as possible."

I made one targeted source change before this handoff: flipped the default of `@AppStorage("threadkeep.import.useContactsNames")` from `false` → `true` in all four call sites (`ImportArchiveSheet.swift`, `LibrarySidebarView.swift`, `ThreadDetailView.swift`, `SettingsView.swift`), and added an eager `requestContactsAccessIfNeeded()` call in the import sheet's `.task` block so the system prompts for Contacts access the first time the sheet opens (instead of only after the user clicks the toggle). The contact-resolution code path itself (`MessagesStoreImporter.resolvedHandle(...)` calling `MessagesContactResolver`) was already correct — it just was never enabled for new users.

**Verify those changes still make sense after a clean build.** If `useContactsNames` was loaded from a stale UserDefaults value during testing, you may need to reset with `defaults delete com.threadkeep.app threadkeep.import.useContactsNames` before re-running.

## What "iMessage parity" means in scope

Mike isn't asking ThreadKeep to send/receive messages or be a chat client. He's asking the *reading and browsing* experience to feel like Messages.app does on the same Mac. Concretely, that means:

1. **Names everywhere a number could appear.** Sidebar titles, message bubble sender labels, search results, PDF exports.
2. **Avatars/monograms** for each conversation (single contact: their photo or initials; group: a 2x2 collage of participant initials). Messages.app draws a colored circle with initials when no photo is set; ThreadKeep currently draws nothing.
3. **Bubble layout that reads as a chat.** Right-aligned outgoing bubbles in iMessage blue (`systemBlue`), left-aligned incoming in `secondarySystemBackground` gray, sender name above the bubble in group chats only, timestamps grouped by gap (>15 min) instead of on every message.
4. **Tapbacks (reactions) shown inline** — a small badge on the affected bubble. The data is in `chat.db`'s `message.associated_message_guid` + `associated_message_type` columns.
5. **Attachment thumbnails** rendered in-line: small image grid for photos, a paperclip + filename for non-image attachments. Currently the importer copies attachments to disk but the viewer only links them.
6. **Message status** ("Delivered" / "Read" tags) for the most recent outgoing message, like Messages.app shows. Data is in `message.is_delivered`, `message.date_delivered`, `message.date_read`.
7. **Edited / unsent indicators** for iOS 16+ messages. Already called out in `CLAUDE-CODE-HANDOFF.md` Phase 3.3.
8. **Sidebar layout**: avatar on the left, name and timestamp on the right, last-message preview underneath in two lines, unread badge if relevant. Messages-style row height ~64pt.
9. **Search results that look like Spotlight in Messages.app**: matched snippet with the query bolded, sender name + relative date underneath.

## Concrete tasks (do these in this order)

### Task 1 — Verify and extend contact-name resolution

- **Confirm fix.** Build, install, open the import sheet on a fresh user defaults state. The chat picker should now show contact names for any number in your Contacts. macOS will prompt for Contacts access on first sheet appearance.
- **Audit every code path that displays a handle.** Grep for `participantNames`, `chat.identifier`, `displayName`, and `chat.title` across `Sources/ThreadKeep/Views/`. For each occurrence, confirm it's running through the resolver. Particular attention to:
  - `LibrarySidebarView.swift:6` — the contact resolver is plumbed but verify sidebar rows actually call into it for *every* row (not just the selected thread).
  - `ThreadDetailView.swift` — sender labels above bubbles and the header title.
  - `ThreadPDFExporter.swift` — both Review and Memorial modes; PDFs sent to family/lawyers should never leak raw phone numbers.
- **Add a fallback policy** for handles that don't match a contact: keep the prettified phone number (e.g., `(555) 555-0199` instead of `+15555550199`) using `CNPhoneNumber` formatting or `CNContactFormatter`. Today the raw E.164 leaks through.
- **Cache resolved labels** keyed by handle string in a `MessagesContactResolver`-shared instance. Re-running through `CNContactStore.unifiedContacts(matching:)` once per row is wasteful for large libraries.

### Task 2 — Avatars / monograms

- **Files to add:** `Sources/ThreadKeep/Views/AvatarView.swift`, `Sources/ThreadKeep/Views/Components/MonogramView.swift`.
- `AvatarView` takes a `ThreadSummary` (or `ThreadDetail`) and renders, in priority order:
  1. The first participant's `CNContact.imageData` if available (already authorized via Contacts permission).
  2. Otherwise a colored circle with 1–2 initials. Use a stable hash of the participant identifier → palette index so the same person always gets the same color.
  3. For group chats: a 2x2 grid of mini avatars, max four participants, "+N" for the rest.
- Wire into `LibrarySidebarView` (replace the current text-only row), `ThreadDetailView` header, and the message bubble layout for incoming messages in groups.
- Avatar size in sidebar: 36×36. In bubble groups: 28×28.

### Task 3 — Bubble layout

- **File:** `Sources/ThreadKeep/Views/ThreadDetailView.swift` (582 lines today).
- Currently messages render as fairly flat rows. Convert to true chat bubbles:
  - Outgoing (`message.isOutgoing == true`): right-aligned, white text on `Color.accentColor` (which on macOS defaults to systemBlue — match Messages.app exactly with `Color(nsColor: .systemBlue)`), max width = 70% of available width, 16pt corner radius with the bottom-right corner sharper using a custom `Shape`.
  - Incoming: left-aligned, `Color(nsColor: .secondarySystemBackground)` background, primary text color, same max width.
  - Sender name (small, secondary color) above incoming bubbles **only in group chats**, and only when the previous message was from a different sender or more than 15 minutes ago.
  - Timestamp ribbon: a small centered date/time label every time the gap to the previous message exceeds 15 minutes.
  - Avatar on the left for incoming messages in groups (omit for 1:1 chats — Messages.app does the same).

### Task 4 — Tapbacks and reactions

- **Files:** `Sources/ThreadKeep/Import/MessagesStoreImporter.swift` (and the new `MessagesMessageDecoder.swift` from the original Phase 3.2) + `Sources/ThreadKeep/Models/ThreadKeepModels.swift` + `Sources/ThreadKeep/Views/ThreadDetailView.swift`.
- Schema: in Apple's `chat.db`, a tapback is itself a `message` row with `associated_message_type` ∈ {2000…2005, 3000…3005} (love/like/dislike/laugh/emphasize/question, plus their "removed" variants), and `associated_message_guid` pointing at the parent message GUID.
- Importer: when scanning messages, group tapbacks under their parent. Add `parentGUID` and `kind: TapbackKind` fields to a new `Reaction` model. Strip them out of the linear message list (they aren't real messages).
- Model: `ThreadMessage.reactions: [Reaction]` keyed by sender + kind, with the latest one winning (a "removed" reaction cancels the corresponding "added" one).
- View: small badge group anchored to the top-left (incoming) or top-right (outgoing) corner of the parent bubble — overlapping the bubble border by ~6pt, like Messages.app draws them.

### Task 5 — Attachment thumbnails

- **Files:** `Sources/ThreadKeep/Views/ThreadDetailView.swift`, possibly a new `AttachmentThumbnailView.swift`.
- Today attachments are stored under `~/Library/Application Support/ThreadKeep/ImportedArchives/<id>/Attachments/` (verify path in `ArchiveStore`); the viewer just lists filenames.
- Render images inline (`NSImage` from disk path → `Image(nsImage:)`), max 240pt wide, rounded 12pt corners, tap to open in Preview. Render videos with a play overlay on a thumbnail (`AVAssetImageGenerator`). For other types (PDFs, vCards, audio), show a paperclip + filename row that opens in the default app.
- Multi-image messages: 2-up grid for two images, 2x2 grid + "+N" for more — matches Messages.app's photo collage.

### Task 6 — Delivery / read receipts

- **Files:** `MessagesStoreImporter.swift`, `ThreadKeepModels.swift`, `ThreadDetailView.swift`.
- Read `message.is_delivered`, `message.date_delivered`, `message.date_read` from `chat.db`. Surface as `ThreadMessage.deliveryStatus: DeliveryStatus` (`.sent`, `.delivered(at:)`, `.read(at:)`).
- Render under the **last outgoing message in the thread only** as small secondary text: "Delivered" or "Read · 3:42 PM". Messages.app's behavior — don't decorate every message.

### Task 7 — Sidebar + search formatting

- **File:** `Sources/ThreadKeep/Views/LibrarySidebarView.swift` (732 lines).
- Replace each row with: avatar (36pt) | (name, timestamp on right) over (last-message preview, two lines, secondary color). Row height ~64pt.
- Last-message preview: prefix with sender name in groups ("Alice: heard the news?"), or "You: ..." for outgoing.
- Timestamp formatting: "3:42 PM" today, "Yesterday" yesterday, "Mon" this week, "11/4/25" older. Match `Messages.app`'s exact behavior — `RelativeDateTimeFormatter` is close but not exact.
- For search results: bold the matched span using `AttributedString` with `.foregroundColor` accent + `.font` semibold on the matched range. Show "Alice — Tuesday" underneath.

### Task 8 — PDF parity

- **File:** `Sources/ThreadKeep/PDF/ThreadPDFExporter.swift`.
- The "Print Conversation" feature in Messages.app produces a chat-bubble-style PDF. Match it for the Review mode at minimum: bubbles, timestamps every 15 min, sender names in groups, attachment thumbnails embedded.
- Keep Memorial mode as the more typographic / book-like layout, but it should also use resolved contact names and embed attachments.

## Things to NOT do

- Do not implement send/reply/compose. ThreadKeep is read-only.
- Do not fetch contact photos over the network or sync to iCloud. Local-only.
- Do not change the SQLite schema mid-task — bundle any schema additions (reactions table, delivery status columns) under a single migration in Phase 1.4 of the original handoff.
- Do not deprioritize the original `CLAUDE-CODE-HANDOFF.md` Phase 1 work (FTS5 escaping, foreign keys, AppFlow consolidation) for this. Correctness fixes ship before cosmetics.

## Suggested ordering with the original handoff

1. Original handoff Phase 0 — safety net.
2. Original handoff Phase 1 — P0 correctness (FTS escaping, FKs, AppFlow, FDA card, schema versioning, temp cleanup).
3. **This handoff Tasks 1–3** (contact names everywhere, avatars, bubble layout) — biggest visual return per hour. Do these next; Mike will *see* the difference.
4. Original handoff Phase 2 — error taxonomy, keyboard nav, settings, dynamic type, sample button.
5. **This handoff Tasks 4–6** (tapbacks, attachments, delivery status) — needs the data-model refactor from Phase 3.2/3.3 first.
6. **This handoff Tasks 7–8** (sidebar/search/PDF polish).
7. Original handoff Phase 3 (split AppViewModel, importer decomposition, attributedBody decode, real test coverage).
8. Original handoff Phase 4 (docs, privacy, README).

Commit each task as its own commit on `renovation/imessage-parity` (or whatever branch Mike approved). Update `RENOVATION-LOG.md` with screenshots if you can grab them; before/after on the sidebar especially is worth the few minutes.
