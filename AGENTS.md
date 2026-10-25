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

## Git

- Default branch is `main`. Use Conventional Commits (`feat:`, `fix:`, `docs:`).
- Commit identity is the owner's GitHub noreply address; never change git identity or config.
- Do not commit, push, or change GitHub repo settings unless asked.
