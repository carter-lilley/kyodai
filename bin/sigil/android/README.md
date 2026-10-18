# Sigil Android binaries

`sigil-arm64.bin` / `sigil-armv7.bin` are ELF executables (built by
`.github/workflows/build-sigil.yml` from `bin/src/argosy-sigil`).

**How they reach the device:** Android 10+ forbids executing binaries from the
app's private data dir, so these are shipped as a *fake native library*:
`android/build_plugin.sh` copies them to
`android/plugin/src/main/jniLibs/<abi>/libsigil.so` (generated, gitignored),
the AAR bundles them, and the package manager extracts them to
`nativeLibraryDir` with exec permission. `SigilRunner._get_sigil_path()`
(`utils/identity/sigil_runner.gd`) runs it from there.

Never copy these into `android/build/` by hand — that directory is a
gitignored generated template; manual placement there is how this broke once
already. If you rebuild sigil, just commit the new `.bin` files and re-run
`android/build_plugin.sh`.
