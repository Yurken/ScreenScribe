# ScreenScribe development

- Local builds must keep a stable certificate signing identity. `scripts/build.sh` selects and pins a real identity; it must never silently fall back to ad-hoc signing.
- Update the local application with `scripts/install.sh` after saving work and quitting ScreenScribe. The installer checks signature continuity and preserves a rollback archive.
- `--migrate-signing` is for an intentional identity migration, such as the initial move from an ad-hoc build to certificate signing. Do not use it for normal updates or as a workaround for a failed continuity check.
- Do not reset TCC or change macOS privacy records to make an ordinary update work. A same-identity update should retain existing grants.
- Personal signing selection stays in the local Application Support configuration. Never commit certificates, private keys, personal identity fingerprints, or local signing configuration.
- A restricted sandbox may hide keychain identities or prevent certificate trust evaluation. Use authorized host execution to verify this condition; never weaken signature verification or select ad-hoc signing to bypass it.
- CI uses an explicitly requested ad-hoc test signature because the runner has no personal signing key. Such artifacts are not a substitute for a stable signed local update or a Developer ID distribution release.
- Validate signing changes with `python3 -m unittest discover -s scripts/tests -v`, shell syntax checks, and actual code-signature continuity checks across different app builds. Run `swift test` when application code changes.
