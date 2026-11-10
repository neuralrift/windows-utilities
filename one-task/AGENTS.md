# AGENTS.md: one-task

Applies on top of the repo-root `AGENTS.md`.

## What it is

A terminal todo, command `t`, for a user who gets distracted easily. It shows one task, the one that matters now. It is kept very simple and grows only by features the owner asks for. Each feature must keep the core ideas below.

## Core ideas (do not break)

1. **One task visible.** Bare `t` prints only the first task. `t list` and `t edit` are the only deliberate ways to see all tasks.
2. **Plain text.** `todo.txt` is one task per line, line 1 is the current task. No metadata, syntax, JSON or database; it must stay editable in Notepad or on a phone. Blank lines are ignored. The format is frozen: an existing `todo.txt` must stay readable as-is.
3. **Capture without interruption.** `t <text>` appends to the bottom and prints `parked.`. It never shows the list and never asks a question.
4. **Done is a log.** `t done` appends `YYYY-MM-DD task` to `done.txt`, and the routine appends `YYYY-MM-DD missed: task`. Nothing reads it back.
5. **Sync is the file system.** Data lives in `OneDrive\Apps\one-task\`, never in this repo. No sync code, network calls, accounts or servers.
6. **Shows on terminal open.** The profile dot-sources `t.ps1`, which ends by calling `t` with `$OneTaskOpening` set, so an empty list prints nothing there; a typed `t` still prints "Nothing to do".
7. **Confirm before guessing.** `t done <n>` and `t done <text>` show what they will log and ask first; bare `t done` does not.

## Design (keep intact)

- One file, `t.ps1`; the script stays in the repo. Only the function `t` is meant for the user; script-level variables are prefixed `OneTask`, since dot-sourcing puts them in the session.
- The version is `$OneTaskVersion` in `t.ps1`. There is deliberately no version command.
- `setup` writes one line ending in `# one-task` to the all-hosts `profile.ps1` of each installed edition (Documents via `GetFolderPath('MyDocuments')`). The line carries `-Root`, the chosen OneDrive, and is guarded by `Test-Path` because profiles may sync between PCs.
- `setup` changes the CurrentUser execution policy only when it would block the profile, and saves the old value and edition in `HKCU\Software\OneTask`. `uninstall` restores it only if it is still `RemoteSigned`.
- `uninstall` removes the marked lines and the registry key, and keeps the task data.
- Commands that take no text (`list`, `edit`, `routine`, `remind`, `merge`, `skip`, `setup`, `uninstall`) only match when typed alone.
- `split` separates steps with ` / `, because `;` is a PowerShell statement separator.
- Routine: `routine.txt` is user-edited plain text (`[days] [HH:MM] task`, `#` comments). `routine.last` is the tool's state: line 1 is the last routine day, then the routine tasks added on it. Routine work runs at the start of every `t` call, so it must stay plain file IO, and it writes only when something changes.
- Routine tasks are identified by their text; on a new day, the previous day's added tasks still in `todo.txt` are removed and logged as missed. Backfilled missed days are capped at 31.
- Reminders: one scheduled task, `OneTask`, runs `conhost.exe --headless powershell.exe ... t.ps1 -Root <root> remind`, always on Windows PowerShell because toasts use WinRT, which PowerShell 7 lacks. Its triggers are a one-shot at the next timed routine task (up to 7 days ahead), logon, and resume from sleep (Power-Troubleshooter event 1), as in `auto-theme-switch`.
- The task is re-registered only by a `remind` run or when `routine.txt`'s write time differs from `Stamp` in `HKCU\Software\OneTask`, so a normal `t` stays fast. Nothing is armed unless setup has created that key.
- `remind` shows one toast for all tasks the routine code just made due (`$due`), so a wake after several due times gives one batched toast.
- `uninstall` unregisters the task and deletes the key; the policy restore runs only if the key holds `PrevPolicy`.
- Conflict copies (`(todo|done|routine)-*.(txt|last)`) are only looked for by bare `t`, `t list` and `t merge`, which keeps capture fast and silent. `t merge` confirms before changing anything; it never merges `routine-*.txt`.
- `$OneTaskNow`, if set in the session, replaces the clock; it exists for tests.
- PowerShell variable names are case-insensitive: don't reuse a name such as `$TODO`/`$todo` for two things.

## Rules for changes

- Stay compatible with Windows PowerShell 5.1 and PowerShell 7:
  - keep `t.ps1` pure ASCII (PS 5.1 misreads UTF-8 without a BOM); write other characters as `[char]0x....`
  - read and write data with `[IO.File]::ReadAllLines`/`WriteAllLines`/`AppendAllText`, not `Set-Content`/`Out-File`
  - use full parameter names, and wrap filtered results in `@()`
  - wrap an `if` that yields lines in `@()` as well (`$x = @(if (...) { ReadAllLines(...) })`): an `if` expression unrolls a one-element array into a bare string, so `$x[0]` becomes its first character
- No dependencies: only built-in PowerShell and .NET.
- Bump `$OneTaskVersion` per the root versioning rules, and update the command table and Known limitations in `README.md`.

## Before finishing any change

Run this in both PS 5.1 and PS 7 against a temporary folder (dot-source `t.ps1 -Root <temp>`), then delete the folder:

```
t                       # -> "Nothing to do..."
t write report; t call bank
t                       # -> write report
t skip                  # -> call bank
t now fix bug           # -> fix bug
t done                  # -> call bank   (done.txt gains "fix bug")
t done                  # -> write report
t list groceries        # -> parked.
t split a / b           # -> write report: a
t done 9                # -> "No such task number"
t done report           # -> lists both "write report" steps, logs nothing
t done 2                # answer y -> logs "write report: b"
```

For the routine, write a `routine.txt` with untimed, `weekdays`, `sat,sun HH:MM` and single-word lines, then step `$OneTaskNow` through: a weekday morning, the same day after a timed task (added once only), the next day (yesterday's leftovers logged as missed), a jump over skipped days (each logged), and a weekend day. Check `todo.txt`, `done.txt` and `routine.last` after each step.

For reminders, use the real clock: create `HKCU\Software\OneTask` with an empty `Stamp` and a temp `routine.txt` with one task two minutes ago and one in 30 minutes. The first `t` must register `OneTask` with logon, event and time triggers; a second `t` must not re-register. Add two more past-time tasks, run `Start-ScheduledTask OneTask` and check for one batched toast and `LastTaskResult` 0. Then uninstall (task and key gone) and restore any real install with `setup`.

For `merge`, put `todo-PC.txt`, `done-PC.txt`, `routine-PC.last` and `routine-PC.txt` next to the main files, with a copy that holds a routine task, a duplicate, a task done today, a task done years ago and a new task. Answer `n` (nothing changes) and `y` (only the old and new tasks are added, the done line is appended, three copies deleted, `routine-PC.txt` kept). If `HKCU\Software\OneTask` exists, set its `Stamp` to the temp `routine.txt`'s write time first and restore it after, so the real reminder task is not re-registered.

For `setup`/`uninstall`, pass `-Root <temp>`, check both `profile.ps1` files, and confirm `uninstall` leaves profiles, policy and `HKCU\Software\OneTask` as they were.
