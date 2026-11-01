# Git two-branch workflow

Mode: solo
Identity: 263138698+neuralrift@users.noreply.github.com
Tag-prefix: */

This repository follows the [Git two-branch workflow](https://github.com/neuralrift/git-clerk-workflow) (v2). Git operations by AI agents go through the `git-clerk` skill.

## Branches

- `dev` is the default branch and receives completed work; feature and fix branches (`feature/<topic>`, `fix/<topic>`) start from `dev`.
- `main` is release-only: each release is a `--no-ff` merge from `dev` with an annotated `*/vX.Y.Z` tag, followed by merging `main` back into `dev`.
- Never force-push `dev` or `main`; never move a published tag.

## Before committing

Verify on a real Windows machine; this repo has no automated tests (see AGENTS.md).

## Approvals

Commits, pushes, tags, branch deletion, resets, rebases and force-pushes need explicit approval from the repository owner.

## Exceptions

Each utility has its own version line, so release tags carry the utility name: `<utility>/vX.Y.Z`, for example `auto-theme-switch/v1.0.0`.
