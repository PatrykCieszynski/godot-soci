# Publishing godot-soci in the Godot Asset Library

The Godot Asset Library is a **separate listing**. Creating a GitHub Release
does not automatically submit the addon to the Asset Library.

## Release prerequisites

- All GitHub Actions workflows must pass on the release commit:
  Linux integration, Windows integration and native Linux/Windows package smoke.
- Use **Actions → Package Godot 4.7 addon → Run workflow** on `main`;
  supply the semver version (e.g. `v0.4.0`). Publishing is performed only
  after both native builds and the combined ZIP succeed.
- Download `godot-soci-vVERSION.zip` from the release assets — **not** GitHub's
  source ZIP. It contains debug/release `x86_64` Windows and Linux binaries,
  GDScript wrappers, API documentation and third-party license texts.
- Install into `res://addons/godot_soci`. Godot loads the `.gdextension`
  automatically; there is no EditorPlugin and **nothing to enable** in Plugins.
- Verify both Godot editor and exported debug/release projects on target OS.
  The CI packaging smoke test covers the editor/headless GDExtension load,
  but does not replace exported-project testing.

## Asset Library listing draft

**Name:** godot-soci — SQLite + PostgreSQL for Godot 4.7+

**Category:** Addons / Scripts (the appropriate available native extension
category when submitting).

**Godot compatibility:** 4.7+; only Windows x86_64 and Linux x86_64 packaged
so far. Do not claim macOS/mobile/Web support before binaries and tests exist.

**Description:**

Native C++ GDExtension powered by SOCI for SQLite and PostgreSQL. Offers a
synchronous SQL API and a GDScript-friendly async wrapper backed by a dedicated
worker thread, bounded query queues, named parameters, atomic async transaction
batches with affected-row guards, and portable binary-value helpers. Includes
built-in editor class documentation and a backend-switch example. The same
Godot-facing API works with both databases, but their SQL dialects and schema
migrations are not automatically translated.

**Repository:** https://github.com/PatrykCieszynski/godot-soci

**License:** MIT. Bundled native dependency notices under
`addons/godot_soci/licenses/` and `THIRD_PARTY_NOTICES.md`.

**Recommended README warning:** Never connect to a protected PostgreSQL server
directly from a game client or ship production database passwords with clients.
For authoritative multiplayer state, run this addon in the trusted server.

## Submission

Manually submit the release download link / repository version through the
Godot Asset Library publisher interface. Follow the current Asset Library
submission requirements and wait for review. Do not mark it as published
until the submission has actually been accepted.
