# AGENTS.md

Guidance for AI coding agents working in this repo. Utility-specific rules live in each utility's own `AGENTS.md`; read the one in the folder you are working in as well as this file.

## Layout

- One folder per utility at the repo root (e.g. `auto-theme-switch/`), each with its own `README.md`, `AGENTS.md` and `CLAUDE.md` (`@AGENTS.md`).
- Adding a utility: create the folder, then add a row to the table in the root `README.md` linking to its README.
- Utilities may use different languages and tools; choose what fits the task and keep each utility self-contained.
- The repo is MIT-licensed (`LICENSE`); keep new files compatible with that.

## Conventions for all utilities

- Keep dependencies minimal and justify any in the utility's README.
- Prefer running without elevation; document it clearly if elevation is needed.
- Background or scheduled runs must be silent (no console flash).
- Provide a clean uninstall path that removes everything the utility created (tasks, registry keys, files, logs) and restores the user's original state.
- Bound the size of any logs or data the utility accumulates.
- No personal data in the repo: no usernames, machine names, local paths or real coordinates. Use placeholders in docs.
- Every utility README documents Requirements, Setup, Usage/Commands and Known limitations.

## Testing

- Verify on a real Windows machine; this repo has no automated tests. Say what was and wasn't verified.
- Do not leave test installs behind: uninstall, or restore the previous state.

## Versioning

- Each utility has its own semantic version, kept in one place in the utility (e.g. a `$Version` constant) and shown by its status/version output.
- Bump it when behaviour changes: patch for fixes, minor for features, major for breaking changes (e.g. a `setup` re-run becoming mandatory).
- Release by tagging `<utility>/vX.Y.Z` (e.g. `auto-theme-switch/v1.0.0`) on `main`.

## Git

- `main` is the default and the only long-lived branch. Do non-trivial work on `feature/<utility>-<topic>` or `fix/<utility>-<topic>` branches and merge into `main` (PR or fast-forward); small docs fixes may go straight to `main`.
- A change to one utility touches only its folder, plus its row in the root `README.md` when needed.
- Use Conventional Commits with the utility as scope (`feat(auto-theme-switch): ...`, `docs: ...`).
- Commit identity is the owner's GitHub noreply address; never change git identity or config.
- Do not commit, push, tag, or change GitHub repo settings unless asked.
