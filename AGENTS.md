# Repository collaboration

This repository is the single source for mpvnet-kit. Read `CONTRIBUTING.md` before changing package tooling or running maintenance tests. Runtime behavior is documented in `docs/`.

If `AGENTS.local.md` exists, read it for this checkout's private maintenance context. It is optional, ignored by Git, and never required to build or test the project.

- Preserve unrelated edits, unknown files, user configuration, and recovery records. Use new external fixture directories for installer tests; never use a personal player directory as a test target.
- Keep `config/` and installer tools in `tools/` separate from developer tooling in `dev-tools/`. Package membership is explicit in `dev-tools/package-map.json`; generated packages and ZIPs stay outside the source tree.
- Run checks appropriate to the change and distinguish automated evidence from real-window and human acceptance. Explain changes to agreed behavior or acceptance criteria before implementing them.

The root `manifest.json` is generated package data, not source. Run installation trials from a generated package, following `CONTRIBUTING.md`.

## Branches and integration

- Before editing, check the current branch, HEAD, and uncommitted changes. Use a short-lived branch from `main` for each independently deliverable work package, including features, fixes, refactors, and documentation batches. Agent-created branches use the `codex/` prefix; reuse the branch for the same package. Use a worktree when parallel work or existing edits require isolation.
- Keep `main` buildable and passing the checks relevant to its changes. It may contain completed work awaiting release; tags and releases identify published versions.
- For approved work, automatically create local Conventional Commits at complete, validated delivery points. Merge locally into `main` once the package and its necessary checks are complete, including agreed user acceptance for important UI or behavior changes. Pending acceptance stays on the work branch; automated checks do not substitute for it.
- Local commits and merges do not authorize push, tags, releases, history rewriting, or personal deployment. Published tags and release assets remain fixed unless the user explicitly authorizes their replacement.
- Keep the workflow lightweight: short-lived work branches and `main`, with no standing `develop` branch or mandatory PR for local work. Use PRs for external contributions. Operational steps are in `CONTRIBUTING.md`; keep these rules authoritative here.
