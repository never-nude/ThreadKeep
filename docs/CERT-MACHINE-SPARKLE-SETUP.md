# Sparkle setup on the cert machine (one-time + per-release)

The Sparkle EdDSA **private key exists only on the cert machine's Keychain**
(plus the offline backup below). It must never be committed to ThreadKeep or
threadkeep-xyz, pasted into a chat/session, or copied to any other machine.

Sparkle's CLI tools ship with the SwiftPM artifact. After any build on the
cert machine they're at:

```sh
BIN="$(find "$HOME/Library/Caches/ThreadKeepBuild/swiftpm-notarized/artifacts" -type d -name bin -path "*[Ss]parkle*" | head -1)"
ls "$BIN"   # generate_keys  sign_update  generate_appcast  …
```

## 1. One-time: generate the keypair

```sh
"$BIN/generate_keys"
```

- Stores the **private key in the login Keychain** (item "Private key for signing Sparkle updates").
- Prints the **public key** (base64). Put it in
  `Sources/ThreadKeep/Support/ThreadKeepInfo.plist` as the value of
  `SUPublicEDKey`, replacing `PLACEHOLDER-SPARKLE-EDDSA-PUBLIC-KEY`, and commit
  that (the public key is not a secret).

## 2. REQUIRED before the first signed release: back up the private key

**Failure mode, spelled out:** every shipped app pins the public key. If the
private key is ever lost, no future update can be signed so that shipped apps
accept it — the in-app updater in every copy in the field is permanently
bricked, and the only path forward is asking all users to manually download a
new build with a new key. If the key is ever *leaked*, an attacker who can also
serve a poisoned appcast can ship users malicious "updates." Back it up; keep
the backup offline.

```sh
"$BIN/generate_keys" -x threadkeep-sparkle-private-key.pem
```

Then:

1. Move `threadkeep-sparkle-private-key.pem` to secure storage that is **off
   both git repos and off the cert machine** — e.g. a password manager's
   secure-file vault or an encrypted USB kept offline. Not iCloud Drive, not
   Dropbox, not any synced folder.
2. Delete the local `.pem` (`rm -P`).
3. **Verify the backup restores** before shipping anything signed:
   on any scratch account/machine, `generate_keys -f threadkeep-sparkle-private-key.pem`
   then `sign_update` a scratch file and confirm the printed public key matches
   the one in the plist. Do not release b3 until this check has passed once.

## 3. Per-release: sign the update

`scripts/build-notarized-dmg.sh` prints these steps after stapling. In short:

```sh
"$BIN/sign_update" dist/ThreadKeep-<label>.dmg
# → sparkle:edSignature="…" length="…"
```

Copy `sparkle:edSignature` and `length` into the new `<item>` in the site
repo's `appcast.xml` (template: `docs/appcast-item-template.xml`). Commit the
DMG and the appcast **in the same commit** so the feed never points at a
missing or mismatched file, then push main to deploy.

## Per-release checklist (b3 and later)

- [ ] `CFBundleVersion` bumped in ThreadKeepInfo.plist (build script enforces this)
- [ ] `SUPublicEDKey` in the plist is the real key, not the placeholder
      (build/launch config check also asserts this at runtime in DEBUG)
- [ ] DMG built, notarized, stapled, Gatekeeper-verified
- [ ] `sign_update` run; signature + exact byte length in the new appcast `<item>`
- [ ] DMG + appcast.xml pushed together; `https://threadkeep.xyz/appcast.xml` serves the new item
- [ ] From an installed previous build: "Check for Updates…" finds, downloads,
      installs, and relaunches the new version
- [ ] After release: bump `LAST_SHIPPED_BUNDLE_VERSION` in build-notarized-dmg.sh
