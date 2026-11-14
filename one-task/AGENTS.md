# AGENTS.md: one-task

Applies on top of the repo-root `AGENTS.md`.

## What it is

A terminal todo, command `t`, for a user who gets distracted easily. It shows one task, the one that matters now. It is kept very simple and grows only by features the owner asks for. Each feature must keep the core ideas below.

## Core ideas (do not break)

1. **One task visible.** Bare `t` prints only the first task (plus its note, and at most one dim hint). `t list`, `t find` and `t edit` are the only deliberate ways to see more.
2. **Plain text.** `todo.txt` is one task per line; the first task is the current one. Tasks that belong together sit indented under a parent line ending in a colon. No metadata, JSON or database; it must stay editable in Notepad or on a phone. The only other convention is ` // ` before a note. `routine.txt` has the same shape, with a schedule in front of each entry. Anything the tool needs to remember beyond that goes in its own side files (`routine.last`, `todo.undo`, `todo.age`), never in those two. Blank lines are ignored.
3. **Capture without interruption.** `t <text>` appends to the bottom (or to its parent) and prints `parked.`. It never shows the list and never asks a question. The only prompts in capture are the ones the user asks for (`t Parent:`) and the ones a routine entry needs because something is missing.
4. **A small vocabulary, one grammar.** `t [remind] [<when> <time>] [<Parent>:] [<task>]` captures; eleven verbs act (`list find done skip now del edit undo routine log help`), each with a one-letter form. A verb never parks: invalid input after a verb explains in one line and changes nothing. Quoted text (one argument containing a space) is always a task. Before adding a verb, look for a way to do it with the grammar or an existing verb.
5. **One selection rule.** `done`, `skip`, `now`, `del` (and `t r <sel> <schedule>`) take nothing (the current task), numbers, or one `Parent:`. No text matching in anything that changes data; `t find` gives the numbers. Only `t find` and `t log` match text.
6. **Done is a log.** `t done` appends `YYYY-MM-DD task` to `done.txt`, the routine appends `YYYY-MM-DD missed: task`, and `t del` appends `YYYY-MM-DD dropped: task`. Only reports (`t log`) read it back; nothing acts on it, and `t log` never writes.
7. **Sync is the file system.** Data lives in the task folder chosen at setup (by default `Apps\one-task\` in a OneDrive, Google Drive, Dropbox or iCloud Drive folder), never in this repo. No sync code, network calls, accounts or servers.
8. **Quiet until asked.** Opening a terminal runs nothing and prints nothing: `t` is a module that PowerShell loads the first time `t` is typed. The task shows when the user types `t`.
9. **Undo before confirm.** A change to one task happens at once, says what it did, and can be taken back with `t undo`. Deleting, and finishing several tasks at once, ask first; moving never asks. A batch is one undoable change.
10. **Command line first, same rules in the file.** Every common change to `todo.txt` and `routine.txt` is possible through `t`. What the command line accepts and what a hand-edited file accepts are the same; a hand-written line that does not fit is kept, never run, and reported (`t r`, or after `t e`/`t r e`).

## Design (keep intact)

### Script and install

- One file, `t.ps1`; the script stays in the repo. Only the function `t` is meant for the user; script-level variables are prefixed `OneTask`, since dot-sourcing puts them in the session.
- The version is `$OneTaskVersion` in `t.ps1`. There is deliberately no version command.
- The folder is a module, `OneTask`: `OneTask.psd1` declares the one function `t` (so PowerShell finds it without loading anything) and `OneTask.psm1` dot-sources `t.ps1` with the task folder stored in `HKCU\Software\OneTask` (`Folder`). The psm1 resolves the junction first, so `$OneTaskScript` is the repo path. `ModuleVersion` must equal `$OneTaskVersion`; `test.ps1` checks it.
- `t.ps1` acts when run as a script (`t.ps1 setup`, the reminder task) and only defines `t` when dot-sourced (the module, the tests): it checks `$MyInvocation.InvocationName`.
- `setup` creates a junction `OneTask` to this folder in each edition's user module folder, which `$modsOf` gets by running `powershell.exe` and `pwsh` (when installed) with the profile loaded and taking the first `$env:PSModulePath` entry (the last output line). A profile or `powershell.config.json` can move it out of Documents, so `-NoProfile` would be wrong. It falls back to `$docMods` (`Documents\WindowsPowerShell\Modules\OneTask` and `Documents\PowerShell\Modules\OneTask`, Documents via `GetFolderPath('MyDocuments')`; the PowerShell 7 one only if pwsh or `Documents\PowerShell` exists). This takes a few seconds, so only `setup` and `uninstall` do it. Setup then removes a `OneTask` junction left in a `$docMods` path it no longer uses. It keeps a correct link, replaces a link to elsewhere, and refuses to touch a real folder. It removes the profile line older versions wrote (ending in `$OneTaskMarker`, `# one-task`) and warns about other profile lines that load `t.ps1`. A junction is deleted by `$unlink`: it clears the read-only flag that OneDrive can set on the link, then `[IO.Directory]::Delete`, which never touches the target.
- `setup` changes the CurrentUser execution policy only when it would block the module, and saves the old value and edition in `HKCU\Software\OneTask`. `uninstall` restores it only if it is still `RemoteSigned`, removes the links (in the `$modsOf` folders and the `$docMods` paths), any old profile line, the scheduled task and the registry key, and keeps the task data.
- `-Folder` is the task folder as is (the module passes the stored one); `-Root` is a synced folder and means `<root>\Apps\one-task`. Without either, `$env:OneDrive\Apps\one-task`. Don't name locals `$folder` or `$root`: names are case-insensitive and would shadow the parameters.
- Setup detects synced folders from known places only (OneDrive env vars, `My Drive` on any drive or in the user folder, Dropbox `info.json`, `%USERPROFILE%\Dropbox`, `%USERPROFILE%\iCloudDrive`) and always offers "Other folder". Switching folders offers to move the files from the stored folder (or the one in an old profile line).

### Dispatch

- `$literal` is true when `t` got exactly one argument containing a space, which is what quoting produces; such text is parked as typed (no verb, no schedule). PowerShell strips the quotes, so this is the only way to see them.
- Otherwise the first word is looked up in `$short` (one-letter forms) and `$words`. A match is a command, whatever follows; anything else is `park`. `list`, `undo`, `help`, `merge`, `setup`, `uninstall` take nothing and say so.
- A leading `remind`, or a when and a time that `$schedOf` can parse, turns `park` into `routine new`. `--remind` is the internal command the scheduled task runs.
- PowerShell turns `a, b` and `mon,thu` into array arguments; `$a` joins them back with `, `, and `$glue` turns a leading `mon, thu` back into `mon,thu`.
- A command that can do nothing says why in one line; it never returns silently.

### Tasks and parents

- In memory the list is flat: a task of a parent is the string `Parent: task`. Only `$fromFile` (file lines to flat tasks) and `$toFile` (the reverse) know the block form, so ages, undo, `done.txt`, the routine and `$isOf` all work on plain lines. `$parentOf` gives the parent of a line, judged on the title (the part before ` // `) and the first `: `.
- `$group` keeps the tasks of one parent together, at the place of the first, with the first spelling of the name. It runs on read and in `$commit`, so appending `Parent: x` anywhere files it under its parent.
- Reading is liberal: a child is a line starting with whitespace or `- ` under a header; a header with no children is dropped; an indented line with no header is a plain task. `$lint` reports the last two after an editor session. Reading never writes.
- A plain task ending in a colon would read back as an empty header, so `$toFile` drops the colon.
- A task line is `title // note`. Duplicates compare titles case-insensitively.
- `park`: `t Parent:` collects lines at a prompt and adds them as one change; a new parent within a small edit distance (`$lev`) of an existing one is created as typed with a hint, never a prompt.
- `$select` implements the selection rule for tasks and, with another list, for `t r x`. It returns indexes or says what it expects.
- `skip`: a plain task goes to the bottom; a task of a parent to the end of its parent; when every task left of a parent is skipped, the block goes to the bottom. `now`: a task of a parent brings its block to the top with that task first; text is a new task at the top, or moves the task with exactly that title. Relative order inside a batch is kept.
- `t e [n] // note` and `t e <n> text` replace the old `note`/`reword`; a reworded task of a parent stays in its parent. `t e` alone runs the editor and always waits (`Start-Process -Wait` for Notepad), then re-reads, lints, and stores the result through `$commit` so it is tidy and undoable. Editor order: `$VISUAL`/`$EDITOR` (through `cmd /c`), `nvim`, `vim`, `nano`, `edit`, Notepad.
- `del` confirms even for the current task and logs `dropped:`.
- Every write to `todo.txt` goes through `$commit`: it refuses when the file changed since it was read (`$seen`), appends the log lines, regroups, writes through `$save` (temp file, then `[IO.File]::Replace`), stores the undo state, and maintains `todo.age`.
- `todo.undo`: line 1 what it covers (`todo`, `routine` or `both`), line 2 the old length of `done.txt`, line 3 the write times of the covered files after the change, line 4 the command, line 5 the number of todo lines that follow (flat tasks); the rest is `routine.txt` as it was. `t undo` asks first if those write times differ now, and cuts `done.txt` back only if they do not. Routine processing writes `todo.txt` only when the list changes, so it does not disturb this.
- `todo.age` is tool state: line 1 `hint <day>`, then `<day>TAB<skips>TAB<title>` per task. `$commit` maintains it (new titles start today, `skip` bumps the count of each skipped task, a reword carries the day over, titles are dropped once neither the list nor the undo state holds them). The variables are `$agePath` and `$ages`; a `$AGE`/`$age` pair once silently broke it.
- Hints only suggest: ages in `t list`, the skip nudge under the current task, one waiting hint a day after `done`. `t` never reorders the list on its own, because the order is the user's and phone edits would fight it.

### Routine

- `routine.txt` lines are `[remind] <when> <time> <task>`; a line ending in a colon is a block whose indented lines are its steps. `$parseLine` reads one line, `$readRoutine` the file. An entry has `Sched` (the schedule as stored), `Days` or `On` (a date, for one-time entries), `At`, `Remind`, `Text`, `Raw`, `Head`, `Names` (the task lines it adds), `Titles` (those without notes), `Key` (the block name, or the title), `Line`/`Last` and `Valid`.
- An entry is `Valid` only with a when and a time (and, for a block, at least one step). Invalid entries are skipped everywhere and never deleted; `$whyOf` gives the reason, using `$warnOf` (edit distance on day words, time-like words) for near misses. `$parseLine` runs on every `t`, so it must stay cheap; `$warnOf` runs only on demand.
- Parsing is liberal on purpose (full day names, ranges, `2pm`, `14.00`): accepting more forms prevents more mistakes than rejecting them. `$canon` stores every valid line in one form (`HH:mm`, a date for one-time entries, two-space steps) whenever `t` writes the file.
- `today`, `tomorrow` and `next <day>` are resolved against a base date: `$now.Date` on the command line, the file's last write date (`$rbase`) when read from `routine.txt`. Tool writes turn them into dates, so the base never shifts.
- Day names repeat. One-time entries (`On`) become due when `On + At` has passed: their tasks go to the top, their lines leave `routine.txt`, and they are **not** recorded in `routine.last`, so they are ordinary tasks from then on.
- `routine.last` is the tool's state: line 1 is the last routine day, then the titles of the repeating tasks added on it. On a new day those still on the list are removed and logged as missed, as are entries that never came up and the days on which `t` never ran (capped at 31). Routine work runs at the start of every `t` call, so it stays plain file IO and writes only when something changes.
- Routine tasks are identified by their title (`$isOf`: the entry's text, or a step `entry: ...`), so a note does not detach them.
- `routine new` asks for what is missing (when, task, a block's steps) and refuses a name (`Key`) already in the routine. `routine change` is either a move (`<numbers|Parent:> <schedule>`: tasks leave `todo.txt` without a log line; picked steps of one parent become one block; undo covers both files) or adding steps to a block (`Parent: [step]`). The two are told apart by whether the words after the selection are a complete schedule and nothing else.
- All routine writes go through `$writeRoutine`, which stores the undo state. The removal of a fired one-time entry is the exception: it is the tool's own bookkeeping.

### Reminders

- One scheduled task, `OneTask`, runs `conhost.exe --headless powershell.exe ... t.ps1 -Folder <folder> --remind`, always on Windows PowerShell because toasts use WinRT, which PowerShell 7 lacks. Its triggers are a one-shot at the next routine time (repeating entries up to 7 days ahead, one-time entries at any distance), logon, and resume from sleep (Power-Troubleshooter event 1), as in `auto-theme-switch`.
- The task is re-registered only by a `--remind` run or when `routine.txt`'s write time differs from `Stamp` in `HKCU\Software\OneTask`, so a normal `t` stays fast. Nothing is armed unless setup has created that key.
- `--remind` shows one toast naming the entries in `$dueShown`: those that just became due and have `remind`. Entries without it are added to the list silently.

### Sync, log, tests

- Conflict copies (`^(todo|done|routine)[-_ (].*\.(txt|last|undo|age)$`, covering OneDrive, Dropbox, Google Drive and iCloud names) are only looked for by bare `t`, `t list` and `t merge`, which keeps capture fast and silent. `t merge` confirms before changing anything; it never merges `routine-*.txt`.
- `t log` derives everything from `done.txt` lines matched with `$isOf`. The days a routine entry was due are its done days plus its missed days, so past schedules need not be known. `t log <text>` resolves the text to a known name (exact, or the one name that contains it or is contained in it; a parent stands for its tasks), lists the candidates when several match, and never parks.
- Test hooks, read from the session: `$OneTaskNow` replaces the clock, `$OneTaskNoArm` stops the scheduled task being registered and makes `--remind` print the names instead of showing a toast, and `$OneTaskAnswers` (a `[Collections.Queue]`) answers prompts. All prompts go through `$ask` and all output through `$say`, which holds the colour palette and honours `NO_COLOR`.

## Rules for changes

- Stay compatible with Windows PowerShell 5.1 and PowerShell 7:
  - keep `t.ps1` pure ASCII (PS 5.1 misreads UTF-8 without a BOM); write other characters as `[char]0x....`
  - read and write data with `[IO.File]::ReadAllLines`/`WriteAllLines`/`AppendAllText`, not `Set-Content`/`Out-File`
  - use full parameter names, and wrap filtered results in `@()`
  - `$null` passed to a .NET `string` parameter becomes `""`; use `[NullString]::Value`
  - write `"${name}: "`, not `"$name: "`, which PowerShell reads as a scope prefix
  - a script block run with `&` cannot set the caller's variables; run it with `.` when it must (`. $read`)
  - wrap an `if` that yields lines in `@()` as well (`$x = @(if (...) { ReadAllLines(...) })`): an `if` expression unrolls a one-element array into a bare string, so `$x[0]` becomes its first character
  - `@($null)` is an array holding one `$null`, so `$h[$k] = @($h[$k]) + $x` plants a null on first use; create the empty array first
  - variable names are case-insensitive: don't reuse a name such as `$TODO`/`$todo` for two things
- No dependencies: only built-in PowerShell and .NET.
- Bump `$OneTaskVersion` per the root versioning rules, and update the command tables and Known limitations in `README.md`. Keep `t help`, the usage comment at the top of `t.ps1` and the README saying the same thing.
- Not built on purpose: text matching in commands that change data; reminders for a single step of a block (give it its own entry); routine entries without a time; nested parents; goals or OKRs on top of `t log`; priorities or flags (line order is the priority); a `clean` command (tidying is automatic); anything shown or run on terminal open.

## Before finishing any change

Run `test.ps1` in both editions; it uses only a temp folder and removes it:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File test.ps1
pwsh -NoProfile -File test.ps1
```

Add a case for every behaviour you change. `Run <words>` returns what `t <words>` printed, joined with `|`; `Answers 'y', 'n'` queues replies to prompts; `At '<date time>'` moves the clock; `File todo.txt` returns a file's lines. An error that stops the run is reported as a failure.

A script cannot check these, so do them by hand when you touch that area:

- Reminders, with the real clock: create `HKCU\Software\OneTask` with an empty `Stamp` and a temp `routine.txt` with a `remind` entry two minutes ago and one in 30 minutes. The first `t` must register `OneTask` with logon, event and time triggers; a second `t` must not re-register. Add two more past-time `remind` entries, run `Start-ScheduledTask OneTask` and check for one batched toast and `LastTaskResult` 0. Then uninstall (task and key gone) and restore any real install with `setup`.
- Setup detection: pipe `99` to `t.ps1 setup`; it prints the menu and stops without changing anything. Fake Google Drive, Dropbox and iCloud by pointing `USERPROFILE`/`LOCALAPPDATA` at a temp folder with those subfolders and a Dropbox `info.json`.
- `setup`/`uninstall`: after `setup`, the `OneTask` entry in each edition's user module folder (`($env:PSModulePath -split ';')[0]` in a new shell with its profile) is a junction to this folder, no `OneTask` junction is left in a `Documents\...\Modules` folder that is no longer the module folder, no profile has a `# one-task` line, and a new shell of each edition shows `(Get-Command t).Source` as `OneTask` without importing anything; `t` works there. `uninstall` removes both links (the repo folder stays), the task and `HKCU\Software\OneTask`, and leaves the policy as it was. Restore a real install with `setup` afterwards.
- `t e` with no terminal editor on the PATH: Notepad opens, the terminal waits, and the task shows when Notepad closes.
