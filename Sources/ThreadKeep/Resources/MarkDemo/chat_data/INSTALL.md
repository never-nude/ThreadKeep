# ThreadKeep — synthetic chat data

Drop this into ThreadKeep as Mark Jones's iMessage history.

## Files

- `chat.db` — Apple-schema SQLite (24,200 messages, 4 conversations, full
  Sonoma column set including `attributedBody`)
- `Attachments/` — 12 placeholder PNGs referenced by `[picture]` messages
  (not every `[picture]` has a real file — that's intentional and
  matches real Messages.app behavior when attachments have been pruned)

## Install paths

ThreadKeep imports a chat.db from a path the user provides at runtime,
or from the canonical macOS location:

    ~/Library/Messages/chat.db
    ~/Library/Messages/Attachments/

For development / demo, point ThreadKeep at this folder directly, or
copy `chat.db` and `Attachments/` to those paths on a sandbox account.

## What's inside

| Conversation     | Phone              | Messages | Span                       |
|------------------|--------------------|----------|----------------------------|
| Nicole 💛        | +1-917-555-0311    | 6,050    | Apr 2025 → Apr 2026        |
| Larry            | +1-917-555-0747    | 10,050   | Oct 2024 → Apr 2026        |
| Mom              | +1-973-555-0109    | 4,050    | Oct 2024 → Apr 2026        |
| Alice            | +1-617-555-0622    | 4,050    | Oct 2024 → Apr 2026        |

Owner: Mark Jones, RN at Mount Sinai NYC, phone +1-212-555-5555.

All numbers are in 555-prefix reserved ranges; no real patient names
appear anywhere in the data.
