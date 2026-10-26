# Repository collaboration

This repository is the single source for mpvnet-kit. Read `CONTRIBUTING.md` before changing package tooling or running maintenance tests. Runtime behavior is documented in `docs/`.

If `AGENTS.local.md` exists, read it for this checkout's private maintenance context. It is optional, ignored by Git, and never required to build or test the project.

- Preserve unrelated edits, unknown files, user configuration, and recovery records. Use new external fixture directories for installer tests; never use a personal player directory as a test target.
- Keep `config/` and installer tools in `tools/` separate from developer tooling in `dev-tools/`. Package membership is explicit in `dev-tools/package-map.json`; generated packages and ZIPs stay outside the source tree.
- Run checks appropriate to the change and distinguish automated evidence from real-window and human acceptance. Explain changes to agreed behavior or acceptance criteria before implementing them.
- After completing an approved, independently deliverable batch and its necessary checks, create a local Conventional Commit for that batch. Push, tags, releases, history rewriting, and personal deployment require their own applicable authorization.

The root `manifest.json` is generated package data, not source. Run installation trials from a generated package, following `CONTRIBUTING.md`.
