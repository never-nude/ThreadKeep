# ThreadKeep JSON Export Schema

Schema version: 1

ThreadKeep JSON export writes one folder per conversation. Each folder contains:

- `<conversation>.json`
- `attachments/` when attachment copies are included and available

The JSON file is UTF-8 and pretty-printed.

## Top-Level Object

```json
{
  "threadkeep_version": "1.0",
  "schema_version": 1,
  "exported_at": "2026-05-05T17:30:00.000Z",
  "source": {},
  "thread": {},
  "messages": []
}
```

## Source

```json
{
  "chat_db_sha256": null,
  "source_archive_sha256": "optional-sha256",
  "imported_at": "2026-05-04T10:00:00.000Z"
}
```

`chat_db_sha256` is reserved for future imports that persist the original `chat.db`
checksum. Current exports always include the key, and use `null` when that exact
source checksum was not stored at import time. `source_archive_sha256` is included
when ThreadKeep has a stored import snapshot to hash.

## Thread

```json
{
  "id": "thread-id",
  "type": "direct",
  "display_name": "Nancy Glimcher",
  "participants": [
    {
      "display_name": "Nancy Glimcher",
      "handles": ["+15551234567", "nancy@example.com"],
      "is_me": false
    }
  ],
  "first_message_at": "2018-05-27T14:23:00.000Z",
  "last_message_at": "2026-05-05T12:08:00.000Z",
  "message_count": 13440
}
```

`type` is `direct` when the exported conversation has one non-me participant and
`group` otherwise.

## Message

```json
{
  "id": "message-id",
  "sender": {
    "display_name": "Nancy Glimcher",
    "handle": "+15551234567",
    "is_me": false
  },
  "timestamp": "2019-05-27T14:23:00.000Z",
  "service": "iMessage",
  "body": "Message text",
  "attachments": [],
  "reactions": [],
  "reply_to_message_id": null,
  "edited": false
}
```

## Attachment

```json
{
  "filename": "IMG_0915.jpeg",
  "uti": "public.jpeg",
  "size_bytes": 482193,
  "checksum_sha256": "optional-sha256",
  "relative_path": "attachments/IMG_0915.jpeg"
}
```

When the user turns off attachment copies, `relative_path` is `null` and no binary
is copied. Size and checksum are still included when the original local file is
available.

## Reactions

```json
{
  "kind": "love",
  "from": {
    "display_name": "Me",
    "handle": null,
    "is_me": true
  },
  "timestamp": null
}
```

ThreadKeep currently preserves reaction kind and sender from imported archives.
Reaction timestamps remain `null` unless a future importer records them.
