# THREADKEEP_MASTER_STATE

> This file is the single source of truth for ThreadKeep across all AI tools (ChatGPT, Claude Chat, Claude Coworker, Codex, and any future additions). Paste it — or link to it — at the top of every prompt. Update it whenever a decision changes. Never let any tool contradict it without first updating this file.

**Last updated:** 2026-07-10
**Owner:** Mike Kushman

---

## 1. Product definition

ThreadKeep is a macOS-first app that turns a user's Messages history (iMessage + SMS from `~/Library/Messages/chat.db`) into a searchable, private, local archive, with an iPhone companion for viewing archives and importing on-device conversations the Mac can't reach.

Target experience: "Messages.app, but for reading your history — private, offline, exportable."

Mac UI target: Messages.app / iMessage-style familiarity. ThreadKeep should feel like a read-only Messages archive: sidebar rows, contact identity, avatars, conversation headers, message bubbles, timestamps, and search should follow Messages.app conventions as closely as practical. ThreadKeep must not claim Apple affiliation and remains a read-only archive app, not a messaging client.

---

## 2. Architecture

- **Mac (primary):** ingestion of `chat.db`, local SQLite+FTS5 store, reader UI, global library search, PDF and JSON export, AirDrop handoff to iPhone.
- **iPhone (companion):** reader for archives transferred from Mac; batch import of on-device Messages data the Mac doesn't have.
- **Storage:** local SQLite with FTS5 full-text search. Per-thread archive schema. No cloud, no account, no telemetry.
- **Stack:** Swift Package Manager (swift-tools-version 6.1, no Xcode project). macOS 14+. SwiftUI + AppKit bridges. Direct SQLite3 C API. PDFKit. Contacts framework (CNContact).

---

## 3. Active priorities (max 3)

1. **Ganymede pre-launch polish** — merge duplicate 1:1 contact rows by canonical Contacts identity, add global cross-conversation SQLite FTS5 search, and add Export JSON alongside Export PDF while preserving Messages.app-style browsing.
2. **iPhone multi-archive intake** — batch import of archives transferred from Mac; reader parity with Mac.
3. **Synthetic conversation dataset** — realistic fixture data for screenshots, demos, and tests without exposing real conversations.

Anything not on this list is out of scope until one of these ships or gets promoted/demoted here.

**Done (merged to master 2026-07-10):** attributedBody import-crash fix (TKArchiveDecode shim), identity-only message dedup (guid → rowid → archive id, never content), and the versioned in-database duplicate-cleanup migration that replaces the dotfile-gated content-key cleanups. 1.0 beta 2 release prep (distribution metadata + notarized-DMG pipeline script) is also on master.

---

## 4. Constraints

- No direct Messages DB access on iPhone (Apple doesn't expose it). iPhone data flows via Mac → AirDrop, or user-driven on-device import.
- Per-thread archive schema. No schema changes without explicit coordination and a migration plan.
- Read-only access to `~/Library/Messages/chat.db` at runtime (via a copy). Never mutate the user's Messages database.
- `useContactsNames` defaults to `true`. Contacts permission is requested on first launch.
- ThreadKeep opens to the welcome/home screen by default. Revealing saved conversations requires local Mac authentication (Touch ID or Mac password) each app session. Quitting clears ThreadKeep session/UI state only; it must not delete imported library data unless the user explicitly chooses a destructive library-removal action.
- No cloud sync, no account, no telemetry, no ads. Ever.
- macOS 14+ minimum. No backporting to older macOS.
- **Reader parity** (Mac ↔ iPhone): canonical reader semantics live on Mac first. Parity means thread-list structure, message grouping + timestamp rules, contact display rules, and archive terminology match across platforms unless device constraints force divergence. When Mac and iPhone disagree, Mac is the reference.
- **No schema or archive-format changes during UX work.** UI/UX passes must not touch SQLite schema, archive format, or migration code. Schema changes require their own scoped task and a migration plan. **Ganymede exception:** schema/index work is permitted only for the scoped SQLite FTS5 global-search index and must preserve existing archive/import semantics.
- **Canonical source tree is whatever Mike uploads at the start of a session.** Codex must build from the uploaded `ThreadKeep-v2/` zip, not from a remembered state across sessions. Codex must not invent UI changes outside the scope of the current prompt. If the uploaded tree differs from what Codex remembers, the uploaded tree wins — no exceptions.

Current macOS baseline:
- Source zip: `ThreadKeep-v2-baseline-supersedes-postpolish-2026-04-25.zip`
- DMG: `ThreadKeep-macOS-baseline-2026-04-25.dmg`
- Status: internal baseline, not public release
- Public release blocker (the real one, verified 2026-07-10): **Developer ID Application certificate is missing from the keychain.** The Apple Developer Program membership IS active (team `QHUS8AZVD4`, since 2026-03-23) — only the cert itself needs to be created and installed. Once it exists, the notarized-DMG pipeline (`scripts/build-notarized-dmg.sh`, on master) covers signing, notarization, and stapling.

---

## 5. Naming

- **ThreadKeep** — canonical product name. Never "Thread Keep", "Threadkeep", "TK", or "MessagesKeep".
- **Export PDF** — visible export action for creating a readable conversation PDF with timestamps included by default.
- **Export JSON** — visible export action for creating a structured per-thread JSON archive with provenance fields and optional attachment copies.
- **Master state file** — THIS file. Referenced as `THREADKEEP_MASTER_STATE.md`.

---

## 6. Tool roles (which AI does what)

| Tool | Role | Allowed to modify source? |
|---|---|---|
| **ChatGPT** | Strategy, synthesis, product decisions, final validation | No |
| **Claude Coworker** (this one) | System design, planning, audits, UX review from running app | No (writes specs & prompts only) |
| **Claude Chat** | Writing, narrative copy, synthetic dataset generation | No |
| **Codex** | Code implementation from scoped specs | **Yes — only hands model** |
| **Claude Code** | Backup hands when Codex unavailable | Yes — only when explicitly tagged in |

**Critical rule:** Codex (and Claude Code as backup) NEVER invents product direction. They implement what's already decided in this file or in a handoff prompt derived from this file.

---

## 7. Workflow

1. **Decide** — ChatGPT + Mike define what to build next. Output: updated priorities in section 3.
2. **Plan** — Claude Coworker produces a structured plan with edge cases, file paths, and acceptance criteria. Output: a handoff prompt (e.g. `CODEX-PROMPT-*.md`).
3. **Implement** — Codex executes the scoped prompt. Output: a branch or PR with a diff.
4. **Generate content** — Claude Chat produces any copy, fixture data, or narrative content called for by the spec.
5. **Validate** — ChatGPT reviews: does it still make sense against this master state? If not, update this file or reject the work.

---

## 8. Decision log (append-only)

Record every decision that changes scope, naming, architecture, or priorities. Newest at top.

- **2026-07-10** — Merged `fix/migration-content-key-hazard` to master after migration sign-off: import-crash fix for undecodable legacy `attributedBody` (TKArchiveDecode Obj-C shim), identity-only dedup contract (Messages guid → source rowid → archive-unique id; content is never an identity), and the duplicate-cleanup migration re-keyed on source identity and gated by `PRAGMA user_version` in the database itself (legacy dotfile markers are now written only as inert tombstones for downgrade safety). Read-only ship-blocker audit committed as `AUDIT.md`. Confirmed remaining public-release blocker: Developer ID Application cert missing from keychain (Developer Program active, team `QHUS8AZVD4`).
- **2026-05-05** — `Threadkeep-thumbnails` experimental build approved as a non-baseline Mac UI prototype. Scope is limited to local attachment thumbnail rendering in the reader. No schema, archive-format, import, cloud, telemetry, account, or product-name changes.
- **2026-05-05** — `Iapetus` experimental build approved to hide duplicate message records in loaded conversation details. Dedupe uses Messages `messages_rowid` metadata when available, with an exact timestamp/body/sender/attachment fallback for older imported records. Raw imported library data is preserved; no schema, archive-format, Messages DB mutation, cloud, telemetry, account, or product-name changes.
- **2026-05-05** — Ganymede pre-launch polish approved. Scope: merge duplicate 1:1 contact threads by canonical Contacts identity, add global cross-conversation SQLite FTS5 search, and add Export JSON alongside Export PDF. This supersedes the prior “single visible Export PDF only” direction. Schema changes are permitted only for the scoped FTS5 search index and must include a migration path.
- **2026-05-04** — Privacy launch model: ThreadKeep always opens to the welcome/home screen, requires local Mac authentication before showing saved conversations each app session, and clears only ThreadKeep session/UI state on quit. Imported library data is preserved unless the user explicitly removes it.
- **2026-04-29** — Mac UI target is Messages.app-style read-only archive parity. Visible export UI simplified to one action: Export PDF. Exported PDFs include timestamps by default.
- **2026-04-25** — Promoted the live ThreadKeep-v2 macOS source tree as the current internal macOS baseline. Baseline artifacts:
  - `ThreadKeep-macOS-baseline-2026-04-25.dmg`
  - `ThreadKeep-v2-baseline-supersedes-postpolish-2026-04-25.zip`
  The older `ThreadKeep-v2-postpolish-2026-04-15.zip` is stale and must not be used as canonical.
- 2026-04-15 — Consolidated restore-and-polish pass: dedup + UI cleanup + bubble fill + import-sheet contact names. From 2026-04-14 baseline.
- **2026-04-15** — Added canonical-source-tree rule to section 4 after a Codex session regressed the dedup fix and invented unspecified sidebar UI. Build from uploaded zip only, no remembered state, no scope creep.
- **2026-04-15** — Restored incoming-bubble background fill (regressed during dedup pass).
- **2026-04-15** — Codex avatar/participant dedup follow-up landed: canonical contact keys now drive 1:1 avatar/title/group-chat behavior and test coverage.
- **2026-04-15** — Added reader-parity definition and no-schema-changes-during-UX-work constraint to section 4. (ChatGPT validation pass, Mike approved.)
- **2026-04-15** — Jump-to-Month persistent right panel: drop it. Reintroduce only as popover/inspector behind a toolbar button if needed. (ChatGPT validation pass, Mike approved.)
- **2026-04-15** — Adopted five-role workflow and THREADKEEP_MASTER_STATE.md as single source of truth. (ChatGPT proposal, Mike approved.)
- **2026-04-15** — `useContactsNames` defaults to `true`; Contacts permission requested on first launch. Import sheet must route titles through `ContactDisplayResolver`, not just string-parse parentheticals.
- **2026-04-15** — Avatar dedup by `CNContact.identifier` (not display name) is required to prevent one person rendering twice when Apple splits them across iMessage + SMS handles.
- **2026-04-14** — v2 renovation kicked off: native `.sheet()` for import, keyboard shortcuts via `ThreadKeepCommands`, NSAlert startup-failure path instead of `fatalError`, `LegacyDataMigration` wired in.

---

## 9. Open questions (must be resolved before the relevant work starts)

- ~~Jump-to-Month right panel~~ **RESOLVED 2026-04-15:** drop the persistent right panel. Reintroduce only as a popover or collapsible inspector behind a toolbar button if needed later.
- ~~Memorial PDF: keep alongside Review PDF, or replace?~~ **RESOLVED 2026-04-29 / UPDATED 2026-05-05:** hide/remove Memorial PDF from visible UI. Ganymede adds Export JSON alongside Export PDF.
- iPhone companion: SwiftUI + shared core, or fully separate codebase? (Deferred — blocker for priority 2, not priority 1. Must be resolved before iPhone work begins.)

---

## 10. How to use this file

**Every AI session starts with:**

> "Read THREADKEEP_MASTER_STATE.md before doing anything. Do not contradict it. If your task requires changing anything in it, stop and tell me first."

If a tool proposes something that contradicts this file, either update the file (with a decision-log entry) or reject the proposal. No silent drift.
