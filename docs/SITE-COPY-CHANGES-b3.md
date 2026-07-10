# Site-copy changes required when b3 ships (Sparkle update checks)

**Do not apply until b3 is live.** The b2 build makes zero network calls, so
today's copy is accurate. b3 adds one capability: an OPT-IN update check that
fetches `https://threadkeep.xyz/appcast.xml` (and, if the user accepts an
update, the DMG). Nothing about the user's library is transmitted; no
analytics, no identifiers beyond an ordinary HTTPS request.

Every affected line in threadkeep-xyz `index.html` (line numbers as of commit
f864982), with exact replacement text:

| Line | Current | Replace with |
|---|---|---|
| 238 | `…works fully offline · 1.0 beta 2 · 2.8 MB` | `…works fully offline (optional update check) · 1.0 beta 3 · <size> MB` |
| 281 | `Your library never leaves your Mac. ThreadKeep has no account, makes no network calls, and collects nothing — there's no telemetry to opt out of. Exports happen only when you ask…` | `Your library never leaves your Mac. ThreadKeep has no account and collects nothing — there's no telemetry to opt out of. Its only network use is an optional, off-by-default update check that fetches a static version file from threadkeep.xyz and sends nothing about you or your data. Exports happen only when you ask…` |
| 309 | `100% local — no account, no telemetry` | `100% local — no account, no telemetry, updates opt-in` |
| 359 | `<dt>network_use</dt><dd>None — works fully offline</dd>` | `<dt>network_use</dt><dd>Opt-in update check only — fetches appcast.xml from threadkeep.xyz; transmits nothing about you</dd>` |
| 386 | `…It makes no network connections and collects no analytics.` | `…It collects no analytics, and its only network connection is the optional update check you can enable (or never enable) — a fetch of a static version file from threadkeep.xyz.` |

Unaffected and still true (leave as-is): meta descriptions (9, 15, 22) — say
"local-first, no account", which remains accurate; 233, 304, 334 (no
account/subscription/email); 280 heading; 282 tags; 338 (Messages access
read-only); 358 (`privacy` row — no account/telemetry still true); 372 (storage
location — still true).

Also when b3 ships: `appcast.xml` lands at the site-repo root (see
docs/appcast-item-template.xml), and the download section gets the b3 DMG +
hash per the usual release flow.
