# ThreadKeep Ship-Blocker Audit

**Scope:** read-only diagnostic pass. Nothing was fixed, edited, configured, or committed.
**Date:** 2026-07-08
**Auditor:** Claude Code (automated), findings independently spot-checked before writing this file.

---

## Step 1–3: Identity & drift check

- Machine confirmed correct — full ThreadKeep SPM source tree found at `/Users/michael/ThreadKeep`, plus a mirror clone at `/Users/michael/GitHub-Migration/never-nude-all/ThreadKeep` (also clean, on `master`, not the branch that shipped — not used further in this audit). Desktop has ~60 dated `.dmg`/`.app`/`.zip` build artifacts from manual iteration; not evidence of anything wrong, just build-history clutter worth archiving/deleting at your leisure.
- **Installed app:** `/Applications/ThreadKeep.app`, version `1.0` (build `1`), bundle ID `com.threadkeep.app`, installed/built 2026-06-11 15:54 UTC. Signed **ad-hoc** (`flags=0x2(adhoc)`, `TeamIdentifier=not set`).
- **Repo state:** checked out on branch `codex/compact-thread-attachments` @ `bd4c103` ("Compact thread attachment rendering," 2026-05-30), working tree clean, no stash, no commits anywhere in the repo (any branch) after 2026-05-30.
- **Drift verdict: NONE.** `dist/ThreadKeep.app` in the repo is **byte-identical** (`cmp` confirmed) to `/Applications/ThreadKeep.app`, same executable mtime (Jun 11 11:54:04) on both. This is the correct repo/commit to audit — you're not looking at a stale copy.
- Note: the shipped build is from a **feature branch**, not `master`. `master` is missing the "Compact thread attachment rendering" commit that's in the shipped build, and — more importantly, see Blocker 1 below — the shipped build is *also* missing a crash fix that exists on a **different**, unrelated feature branch. Nothing has been merged since 2026-05-29/30.

---

## Step 4: Notarization readiness

| Check | Result |
|---|---|
| Developer ID Application cert in keychain | **Not present.** Only cert found: `Apple Development: Michael Kushman (598Z6QP7FL)` — a personal development cert, not valid for Developer ID distribution or notarization. |
| Code signing | Ad-hoc (`codesign --sign -`), by explicit design in `scripts/build-release-app.sh` (comment: *"Ad-hoc signing keeps the local bundle launchable without introducing a Developer ID or notarization requirement at this stage"*). No hardened runtime, no entitlements wired in. |
| App Sandbox | **Disabled.** `codesign -d --entitlements -` returns an empty entitlements blob — no `.entitlements` file exists anywhere in the repo. |
| chat.db-vs-Sandbox conflict (the specific thing you asked me to flag) | **Not currently applicable** — since Sandbox is off, there's no conflict today. This is consistent with the app's own README, which states outright: *"ad-hoc signed / arm64 only / not notarized."* **However**, flagging for awareness: if you ever pursue Mac App Store distribution, enabling Sandbox would very likely break (or at minimum, jeopardize App Review approval of) the chat.db read path — reading another app's private container data is the kind of thing Apple both sandbox-restricts and reviews harshly regardless of sandbox status. This is a known, common wall for Messages-reading utilities; it's why apps like this are usually distributed outside the App Store. Not a bug — just don't let sandboxing this app become a project in itself.
| Is this news to you? | No — `THREADKEEP_MASTER_STATE.md:56` already lists "Developer ID signing, notarization, Gatekeeper-friendly distribution" as untouched public-release blockers, and `CHANGES.md:55` says the same. This audit just confirms it directly against the machine. |

**Bottom line:** to ship outside the App Store with Gatekeeper-friendly distribution, you need (1) a paid Apple Developer Program enrollment + Developer ID Application certificate, (2) hardened runtime + codesign with that identity, (3) a `notarytool submit` + `staple` step added to the release script. None of the three exist yet. This is a **blocker for any public distribution**, but it's a known, already-tracked one, not a surprise.

---

## Step 5: Build & test

- `swift build` (debug): **Success**, 0 warnings/errors reported in output, 5.93s.
- `swift test`: **Success — 60/60 tests passed**, 0 failures, 0.18s runtime.
- No environment/toolchain issues (macOS 26.5.1, Swift 6.3.3, arm64).

Build and test health is good. This is not where the risk is.

---

## Step 6: Ship-blocker findings, ranked by severity

### 🔴 BLOCKER — App aborts on a real-world malformed iMessage row; the fix exists but was never merged

**File:** `Sources/ThreadKeep/Import/MessagesStoreImporter.swift:838-860` (`legacyTypedstreamObject(from:)`, called from `decodeAttributedBody` at line 822)

The importer decodes legacy `attributedBody` blobs (old-format iMessage rows) via `NSClassFromString("NSUnarchiver")` and raw Objective-C message sends (`perform(_:with:)`), with **no exception handling**:

```swift
let decodedObject = unarchiver.perform(decodeSelector)?.takeUnretainedValue()
```

When a row's `attributedBody` is a legacy `streamtyped` archive that `NSUnarchiver` cannot decode, this raises an **Objective-C `NSException`** (`decodeObject` → `_decodeCStringAtCursor` → `objc_exception_throw` → `abort()`). Swift's `try`/`catch` **cannot catch Objective-C exceptions** — the entire process aborts. One bad row kills the whole import (and the app).

**This exact bug was already found and fixed once.** Commit `ad1585e` / `7fba3ce` ("Edith: don't crash on undecodable attributedBody...") added a dedicated Objective-C SPM target (`Sources/TKArchiveDecode/`) that wraps `NSUnarchiver` in `@try`/`@catch` and returns `nil` on exception, plus a regression test (`messagesStoreImportSkipsUndecodableAttributedBodyWithoutCrashing`). That work is real and complete — **but it lives only on branch `edith-attributedbody-crash-and-sheet-ui` (pushed as `origin/import-attributedbody-crash-and-sheet-ui`)**. Verified directly:

```
git merge-base --is-ancestor ad1585e HEAD        → NO
git merge-base --is-ancestor ad1585e master       → NOT on master
git merge-base --is-ancestor ad1585e origin/master → NOT on master
```

The currently shipped build has no `TKArchiveDecode` target, no `@try`/`@catch` anywhere in the source tree, and the raw unguarded `NSUnarchiver` call is live in the binary running in `/Applications` right now.

**Impact:** any user importing real Messages history that happens to contain an old-format row `NSUnarchiver` chokes on will get a hard crash mid-import, not a graceful error. This is exactly the kind of thing that shows up in App Store reviews / bug reports as "the app just quits." It does **not** put the user's actual `chat.db` at risk (see below — that layer is solid), but it's a reliability blocker for the core import feature.

**This isn't tracked anywhere** — not in `THREADKEEP_MASTER_STATE.md`, not in `CHANGES.md`. It reads like a fix that was done, reviewed, and then the branch never got merged — worth checking your merge history/PR queue rather than re-doing the work, since it already exists.

---

### 🟡 Minor — chat.db temp copy is not atomic

**File:** `Sources/ThreadKeep/Import/MessagesStoreImporter.swift:264-278`

`chat.db` is copied to a temp directory via sequential `FileManager.copyItem` calls (`chat.db`, then `-wal`, then `-shm`). If Messages.app checkpoints the WAL between those two copies, the temp copy could be a torn/inconsistent snapshot. In practice this surfaces as an already-handled `databaseUnreadable` error, or silently misses the very latest messages (already disclosed to the user via an existing "coverage depends on..." warning). It never touches the live file, so no data-loss/corruption risk to the user's real database — just a small, already-mitigated data-completeness edge case. Not worth blocking a release on.

---

### 🟡 Minor — latent fragility, not a current bug

**File:** `Sources/ThreadKeep/Import/MessagesStoreImporter.swift:547`

`participants["you"]!` is a force-unwrap that's safe *today* only because `"you"` is unconditionally seeded into the dict earlier in the same function and never removed. Fine as-is; flagging only because a future refactor that changes that invariant would reintroduce a crash silently. No action needed now.

---

### ✅ Verified clean — no action needed

- **chat.db is never opened for writing.** Every production `SQLiteDatabase` construction site was enumerated (only two: the app's own private archive DB, and the Messages temp-copy import path) and only one `sqlite3_open_v2` call site exists in the whole codebase — there is no bypass. The Messages read path opens the *copy* with `SQLITE_OPEN_READONLY`, confirmed by the already-landed hardening commits (`f4e80fd`/`50796f1`, "T-026/T-027") which *are* present on the current branch. `sqlite3_busy_timeout(5000)` is applied unconditionally to every connection.
- **No `try!`, `fatalError(`, or `as!` anywhere in `Sources/ThreadKeep`.** Only 4 force-unwraps (`!`) exist in the entire source tree; three are trivially guarded by preceding checks or are hardcoded literals, and the fourth is the "you" key noted above.
- **No network calls anywhere in the app** (`grep` for `URLSession`/`URLRequest`/`http(s)://` in `Sources/` returns nothing) — fully local, which is a clean privacy story for review purposes and rules out a whole class of App Review concerns.
- **No private-framework usage.** The only dynamic-class-lookup pattern (`NSClassFromString`) targets the deprecated-but-public `NSUnarchiver`, not a private API — this is a crash-safety issue (see Blocker above), not an App Review private-API violation.
- Temp file cleanup (both success and failure paths) is handled via `defer`/`deinit` — no routine leftover-file leakage under normal error handling. (Caveat: a hard `abort()` from the Blocker above bypasses Swift `defer` entirely, so a crash could leave a temp copy of the user's Messages data sitting in `NSTemporaryDirectory()`. That directory is per-user, mode 0700 — not an exposure risk to other users on the machine, just clutter that won't get cleaned up until reboot/next import.)

---

## Priority order

1. **Blocker:** merge (or cherry-pick) the existing `NSUnarchiver` crash fix from `edith-attributedbody-crash-and-sheet-ui` into whatever branch you intend to ship — it's already written and tested, just sitting unmerged.
2. **Blocker (already known to you):** Developer ID cert + notarization pipeline, before any public/Gatekeeper distribution.
3. **Minor, optional:** atomic chat.db+wal+shm snapshot; the `participants["you"]` invariant.

No fixes have been applied. All findings above are diagnostic only, per your instructions.
