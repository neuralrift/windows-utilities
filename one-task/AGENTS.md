# AGENTS.md: one-task

Applies on top of the repo-root `AGENTS.md`.

## What it is

A terminal todo, command `t`, for a user who gets distracted easily. It shows one task, the one that matters now. It is kept very simple and grows only by features the owner asks for. Each feature must keep the core ideas below.

## Core ideas (do not break)

1. **One task visible.** Bare `t` prints only the first task. `t list` and `t edit` are the only deliberate ways to see all tasks.
2. **Plain text.** `todo.txt` is one task per line, line 1 is the current task. No metadata, syntax, JSON or database; it must stay editable in Notepad or on a phone. Blank lines are ignored. The format is frozen: an existing `todo.txt` must stay readable as-is.
3. **Capture without interruption.** `t <text>` appends to the bottom and prints `parked.`. It never shows the list and never asks a question.
4. **Done is a log.** `t done` appends `YYYY-MM-DD task` to `done.txt`, the routine appends `YYYY-MM-DD missed: task`, and `t del` appends `YYYY-MM-DD dropped: task`. Nothing reads it back.
5. **Sync is the file system.** Data lives in the task folder chosen at setup (by default `Apps\one-task\` in a OneDrive, Google Drive, Dropbox or iCloud Drive folder), never in this repo. No sync code, network calls, accounts or servers.
6. **Shows on terminal open.** The profile dot-sources `t.ps1`, which ends by calling `t` with `$OneTaskOpening` set, so an empty list prints nothing there; a typed `t` still prints "Nothing to do".
7. **Undo before confirm.** A change to one task happens at once, says what it did, and can be taken back with `t undo`. Deleting, and acting on several tasks at once, ask first.
8. **Command line first.** Every common change to `todo.txt` and `routine.txt` should be possible through `t`, so the user never has to edit the files by hand. `t edit` and `t edit routine` are fallbacks, not the way to do things; when a change can only be made in an editor, that is a gap to close.

## Design (keep intact)

- One file, `t.ps1`; the script stays in the repo. Only the function `t` is meant for the user; script-level variables are prefixed `OneTask`, since dot-sourcing puts them in the session.
- The version is `$OneTaskVersion` in `t.ps1`. There is deliberately no version command.
- `setup` writes one line ending in `# one-task` to the all-hosts `profile.ps1` of each installed edition (Documents via `GetFolderPath('MyDocuments')`). The line carries `-Folder`, the task folder used as is, and is guarded by `Test-Path` because profiles may sync between PCs.
- `setup` changes the CurrentUser execution policy only when it would block the profile, and saves the old value and edition in `HKCU\Software\OneTask`. `uninstall` restores it only if it is still `RemoteSigned`.
- `uninstall` removes the marked lines and the registry key, and keeps the task data.
- Commands that take no text (`list`, `edit`, `remind`, `merge`, `skip`, `add`, `help`, `setup`, `uninstall`) only match when typed alone; `edit` also accepts exactly `routine` or `routines`.
- `t routine` mirrors `t`: alone or with `list` it lists, `add` alone prompts, `del` removes, and any other text is a routine line to add. `done`/`del`/`top` and `routine del` share `$select`, which takes the list to pick from.
- `t edit` picks `$VISUAL`/`$EDITOR` (run through `cmd /c` so an editor command with arguments works), then `nvim`, `vim`, `nano`, `edit`, then Notepad. After a terminal editor closes it calls `t`, which shows the task and re-arms reminders if the routine changed; Notepad does not wait, so it returns at once.
- New command words must rarely start a real task, or capture breaks: `top` and `del` were chosen over `do`, `pick`, `delete` and `drop` for that reason.
- A task line is `title // note`. Duplicates (on park, `now` and `add`) compare titles case-insensitively; text matching for `done`/`del`/`top` searches the whole line. `done`, `del` and `top` share one selection rule (numbers, or text with exactly one match).
- `del` confirms even for the current task and logs `dropped:`; `top` changes nothing but order, so it does not confirm.
- `t add` reads with `Read-Host`, the only way to take `'` and other PowerShell syntax as typed.
- `t routine add` uses the same `$parseLine` as the routine itself, so what it reports is what will run. It skips a task text already in the routine and writes only when it adds something (writing changes `Stamp`, which re-arms reminders).
- PowerShell turns `a, b` and `mon,thu` into array arguments; `$a` joins them back with `, `, and `$parseLine` accepts `mon, thu`. `t routine list <words>` is treated as a routine line, so a task may start with "list".
- `split` separates steps with ` / `, because `;` is a PowerShell statement separator.
- Routine: `routine.txt` is user-edited plain text (`[days] [HH:MM] task`, `#` comments). `routine.last` is the tool's state: line 1 is the last routine day, then the routine tasks added on it. Routine work runs at the start of every `t` call, so it must stay plain file IO, and it writes only when something changes.
- Routine tasks are identified by their title (`$isOf`: the entry's text, or a step `entry: ...`), so a note or a split does not detach them; on a new day, the previous day's added tasks still in `todo.txt` are removed and logged as missed. Backfilled missed days are capped at 31.
- Reminders: one scheduled task, `OneTask`, runs `conhost.exe --headless powershell.exe ... t.ps1 -Folder <folder> remind`, always on Windows PowerShell because toasts use WinRT, which PowerShell 7 lacks. Its triggers are a one-shot at the next timed routine task (up to 7 days ahead), logon, and resume from sleep (Power-Troubleshooter event 1), as in `auto-theme-switch`.
- The task is re-registered only by a `remind` run or when `routine.txt`'s write time differs from `Stamp` in `HKCU\Software\OneTask`, so a normal `t` stays fast. Nothing is armed unless setup has created that key.
- `remind` shows one toast for all tasks the routine code just made due (`$due`), so a wake after several due times gives one batched toast.
- `uninstall` unregisters the task and deletes the key; the policy restore runs only if the key holds `PrevPolicy`.
- `-Folder` is the task folder as is; `-Root` is a synced folder and means `<root>\Apps\one-task` (older profile lines use it). Without either, `$env:OneDrive\Apps\one-task`. Don't name locals `$folder` or `$root`: names are case-insensitive and would shadow the parameters.
- Setup detects synced folders from known places only (OneDrive env vars, `My Drive` on any drive or in the user folder, Dropbox `info.json`, `%USERPROFILE%\Dropbox`, `%USERPROFILE%\iCloudDrive`) and always offers "Other folder". Switching folders offers to move the files from the folder in the old profile line.
- Conflict copies (`^(todo|done|routine)[-_ (].*\.(txt|last|undo|age)$`, covering OneDrive, Dropbox, Google Drive and iCloud names) are only looked for by bare `t`, `t list` and `t merge`, which keeps capture fast and silent. `t merge` confirms before changing anything; it never merges `routine-*.txt`.
- Every write to `todo.txt` goes through `$commit`: it refuses when the file changed since it was read (`$seen`), appends the log lines, writes through `$save` (temp file, then `[IO.File]::Replace`), and stores the previous state in `todo.undo` (line 1 the old length of `done.txt`, line 2 the new write time of `todo.txt`, line 3 the command, then the old lines). `t undo` restores it and cuts `done.txt` back only if the list is untouched since. `t add` re-reads (`. $read`) before each line.
- Test hooks, read from the session: `$OneTaskNow` replaces the clock, `$OneTaskNoArm` stops the scheduled task being registered, and `$OneTaskAnswers` (a `[Collections.Queue]`) answers prompts. All prompts go through `$ask` and all output through `$say`, which holds the colour palette and honours `NO_COLOR`.
- PowerShell variable names are case-insensitive: don't reuse a name such as `$TODO`/`$todo` for two things.

## Rules for changes

- Stay compatible with Windows PowerShell 5.1 and PowerShell 7:
  - keep `t.ps1` pure ASCII (PS 5.1 misreads UTF-8 without a BOM); write other characters as `[char]0x....`
  - read and write data with `[IO.File]::ReadAllLines`/`WriteAllLines`/`AppendAllText`, not `Set-Content`/`Out-File`
  - use full parameter names, and wrap filtered results in `@()`
  - `$null` passed to a .NET `string` parameter becomes `""`; use `[NullString]::Value`
  - write `"${name}: "`, not `"$name: "`, which PowerShell reads as a scope prefix
  - a script block run with `&` cannot set the caller's variables; run it with `.` when it must (`. $read`)
  - wrap an `if` that yields lines in `@()` as well (`$x = @(if (...) { ReadAllLines(...) })`): an `if` expression unrolls a one-element array into a bare string, so `$x[0]` becomes its first character
- No dependencies: only built-in PowerShell and .NET.
- Bump `$OneTaskVersion` per the root versioning rules, and update the command table and Known limitations in `README.md`.

## Before finishing any change

Run `test.ps1` in both editions; it uses only a temp folder and removes it:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File test.ps1
pwsh -NoProfile -File test.ps1
```

Add a case for every behaviour you change. `Run <words>` returns what `t <words>` printed, joined with `|`; `Answers 'y', 'n'` queues replies to prompts; `At '<date time>'` moves the clock; `File todo.txt` returns a file's lines.

A script cannot check these, so do them by hand when you touch that area:

- Reminders, with the real clock: create `HKCU\Software\OneTask` with an empty `Stamp` and a temp `routine.txt` with one task two minutes ago and one in 30 minutes. The first `t` must register `OneTask` with logon, event and time triggers; a second `t` must not re-register. Add two more past-time tasks, run `Start-ScheduledTask OneTask` and check for one batched toast and `LastTaskResult` 0. Then uninstall (task and key gone) and restore any real install with `setup`.
- Setup detection: pipe `99` to `t.ps1 setup`; it prints the menu and stops without changing anything. Fake Google Drive, Dropbox and iCloud by pointing `USERPROFILE`/`LOCALAPPDATA` at a temp folder with those subfolders and a Dropbox `info.json`.
- `setup`/`uninstall`: pass `-Folder <temp>`, check both `profile.ps1` files, and confirm `uninstall` leaves profiles, policy and `HKCU\Software\OneTask` as they were.
- `t edit`: with `$env:EDITOR` set to `cmd /c echo` it must receive the file path.
