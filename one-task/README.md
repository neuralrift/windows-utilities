# One Task

A terminal todo that shows **one task**: the one that matters now. Every new terminal shows it; nothing in normal use shows the whole list. One PowerShell script, no dependencies, plain-text data synced by your cloud storage.

## How it works

- The command is `t`. The script lives in this repo; your profile dot-sources it, so every new terminal prints the current task. With nothing to do, a new terminal prints nothing; typing `t` still says so.
- Tasks live in the task folder chosen at setup, by default `Apps\one-task\` in your OneDrive, Google Drive, Dropbox or iCloud Drive folder:
  - `todo.txt`: one task per line, the first is the current task. Tasks that belong together sit indented under a parent line (see Parents). Any text editor works, on the PC or your phone; blank lines are ignored.
  - `done.txt`: a log of `YYYY-MM-DD task` lines, `YYYY-MM-DD missed: task` for routine tasks left undone, and `YYYY-MM-DD dropped: task` for deleted ones. Only `t log` reads it back.
  - `routine.txt`: tasks that come back, daily or once (see Routine).
  - `routine.last`, `todo.undo` and `todo.age`: the tool's own records (the current routine day, the state before your last change, and when each task was first seen); leave them alone.
- Sync between PCs is the sync app's job; the tool has no sync code, network calls or accounts.

## Requirements

- Windows 11 with the built-in Windows PowerShell 5.1; PowerShell 7 is supported too.
- A synced folder: OneDrive (personal or work), Google Drive for desktop, Dropbox (personal or business) or iCloud Drive. Any other folder works too, but then nothing syncs it.
- An execution policy that lets your profile run local scripts (`RemoteSigned`). `setup` sets this for the current user if needed.

## Setup (once, no elevation needed)

Clone or download the repo, then run from the `one-task` folder in Windows PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File t.ps1 setup
```

`setup`:

- lists the synced folders it finds and asks where your tasks should live:
  - OneDrive personal and work (from Windows' `OneDriveConsumer`/`OneDriveCommercial` settings)
  - Google Drive (a `My Drive` folder at the root of a drive such as `G:`, or in your user folder)
  - Dropbox personal and business (from Dropbox's own `info.json`, or `%USERPROFILE%\Dropbox`)
  - iCloud Drive (`%USERPROFILE%\iCloudDrive`)
  - Other folder: any path you type, used as is
- uses `Apps\one-task\` inside a synced folder, or your folder as is; skip the question with `setup -Folder <folder>` (used as is) or `setup -Root <synced folder>` (adds `Apps\one-task`)
- if you switch folders, offers to move your task files from the old one
- creates a commented `routine.txt` template
- adds one line, marked `# one-task`, to the all-hosts profile (`profile.ps1`) of Windows PowerShell and, if installed, PowerShell 7, so it also works in VS Code's terminal
- creates `HKCU\Software\OneTask`, after which the next `t` registers the reminder task (see Reminders)
- sets the CurrentUser execution policy to `RemoteSigned` only if the current one would block the profile, and remembers the old value in `HKCU\Software\OneTask`

Re-running `setup` is safe; it replaces its line. Re-run it if you move the repo folder. `t setup` from a terminal keeps the current task folder; to choose again, run the script directly as above.

## Commands

Everything you type after `t` is either a task to remember or one of eleven verbs.

```
t [remind] [<when> <time>] [<Parent>:] [<task>]
```

**Capture**

| You type | What happens |
|---|---|
| `t buy milk` | Parks the task at the bottom; never asks anything. A task already on the list is not added again |
| `t call bank // ask about the fee` | Parks it with a note (see Notes) |
| `t Report: draft` | Parks it under the parent `Report`, creating the parent if needed (see Parents) |
| `t Report:` | Asks for several tasks for `Report`, one per line, until an empty line |
| `t weekdays 14:00 timesheet` | A when and a time make it a routine entry (see Routine) |
| `t remind tomorrow 9am call bank` | The same, with a notification |
| `t "list the options"` | Quoted text is parked as typed, even if it starts with a verb or a schedule |

**Verbs**

| Verb | Short | Does |
|---|---|---|
| `t` | | Shows the current task |
| `t list` | `l` | All tasks, numbered, grouped under their parents, with notes and ages |
| `t find <text>` | `f` | The tasks containing the text, with their list numbers |
| `t done [sel]` | `d` | Logs the task to `done.txt` and shows the next one |
| `t skip [sel]` | `s` | Moves the task down (see Parents for what "down" means in a group) |
| `t now <sel>` | `n` | Moves tasks to the top |
| `t now <task>` | `n` | Puts a new task at the top, for interruptions. If a task has exactly that title, moves it instead |
| `t del [sel]` | `x` | Removes tasks after confirmation, logging them as `dropped:` |
| `t edit` | `e` | Opens `todo.txt` in your editor |
| `t e // <note>`, `t e 3 // <note>` | | Adds a note to the current task, or to task 3 |
| `t e 3 <new text>` | | Rewords task 3. Its note stays; end with `//` to drop the note, or give `text // new note` to replace it |
| `t undo` | `u` | Takes back the last change: to your tasks, to the routine, or made in the editor |
| `t routine` | `r` | Your routine (see Routine) |
| `t log [name]` | `g` | What you finished, and how well a routine is kept (see Log) |
| `t help` | `h` | Lists all of this (also `-h`, `--help`, `?`) |

Rarely needed: `t merge` (see Conflict copies), `t setup`, `t uninstall`.

**Selection.** `done`, `skip`, `now` and `del` take the same three forms:

| You type | Acts on |
|---|---|
| nothing (`t done`) | The current task |
| numbers (`t done 2 5` or `t done 2,5`) | Those tasks, as numbered by `t list` or `t find` |
| a parent (`t done Report:`) | Every task of that parent |

Anything else is refused with one line and nothing changes. To act on a task you only remember part of, run `t find <text>` and use its number. One task is changed at once; several are shown first and need a `y`, except when they are only moved.

**A verb never parks.** `t list groceries` does not add a task; it tells you that `list` takes nothing. To park text that starts with a verb, a one-letter short form or a schedule, quote it: `t "list groceries"`, `t "log hours"`.

`t edit` uses a terminal editor when it finds one: `$env:VISUAL` or `$env:EDITOR` if set, otherwise the first of `nvim`, `vim`, `nano` and `edit` (Microsoft Edit) on your PATH, and Notepad as the fallback. `t` waits until you close the editor, tells you about anything it could not keep as written (an indented line with no parent, a parent with no tasks), and shows your current task. Tasks you delete in the editor are removed, not logged. `t undo` takes the whole edit back.

Colours carry one meaning each: cyan for the current task, grey for other tasks, dim grey for notes and hints, green for done or on track, yellow for something that needs attention, red for missed or errors. The words say the same thing, so nothing depends on colour. Set the `NO_COLOR` environment variable to turn colours off.

## Notes

A task can carry a note after ` // ` on the same line:

```
call bank // ask about the late fee
```

`t` shows the note dimmed under the current task, and `t list` shows it after the task. Add one when you park the task, or later with `t e // ask about the late fee`; a second note is appended after `; `. Duplicates are judged on the part before ` // `.

## Parents

A parent holds tasks that belong together. In `todo.txt` it is a line ending in a colon, with its tasks indented under it:

```
buy milk
Report:
  draft // due monday
  review
  send
call dentist
```

- `t Report: draft` adds to the parent, wherever it is in the list; `t Report:` asks for several tasks. The parent's name is matched exactly, ignoring case. If a new name is very close to an existing one, `t` adds it and says so (`new group 'Reprot' (close to 'Report'; t undo)`).
- Each task of a parent is an ordinary task with its own number. `t` shows the current one as `Report: draft  (3 steps left)` and says `Report: all steps done.` after the last. A parent with no tasks left disappears.
- When you edit the file by hand, indent with spaces, a tab or `- `; `t` stores two spaces. The next line that is not indented ends the parent. Blank lines mean nothing.

The tasks of a parent always stay together, which decides what moving them means:

| You type | Effect |
|---|---|
| `t skip` on a plain task | It goes to the bottom of the list |
| `t skip` on a task of a parent | It goes to the end of its parent |
| `t skip` on the last task left of a parent, or `t skip Report:` | The whole parent goes to the bottom of the list |
| `t now 4` on a task of a parent | Its parent comes to the top, with that task first |
| `t now Report:` | The parent comes to the top, its order unchanged |
| `t done Report:`, `t del Report:` | All its tasks, after confirmation |

Any task whose text contains `: ` is stored under a parent, so `t fix: login bug` becomes a parent `fix` with one task. It reads and behaves the same.

## Routine

A routine entry is a task that comes back. Put a **when** and a **time** in front of a task and it goes to `routine.txt` instead of your list:

| You type | Result |
|---|---|
| `t weekdays 14:00 timesheet` | Monday to Friday at 14:00, `timesheet` goes to the top of your list |
| `t remind mon,thu 17:00 call supplier` | The same on Mondays and Thursdays, with a Windows notification |
| `t remind weekdays 07:00 Morning:` | A group: `t` asks for its tasks, and all of them go to the top at 07:00 |
| `t remind today 19:00 email the landlord` | Once, today |
| `t tomorrow 9am call bank` | Once, tomorrow |
| `t remind next fri 17:00 submit expenses` | Once, on the coming Friday |
| `t 2026-11-20 10:00 renew licence` | Once, on that date |

- **When, repeating:** `daily` or `everyday`, `weekdays`, `weekends`, short or full day names (`mon`, `Monday`), lists (`mon,thu`) and ranges (`mon-fri`, `fri-mon`). A day name always means every week.
- **When, once:** `today`, `tomorrow`, `next <day>` (the first such day after today, so a week ahead when today is that day) or a date as `YYYY-MM-DD`.
- **Time:** `14:00`, `14.00`, `2pm` or `2:30pm`; stored as `14:00`.
- **`remind`** in front adds the notification. Without it the task only moves to the top at its time.
- Both a when and a time are needed. `t daily review of sales` has no time, so it is parked as an ordinary task.
- What is missing is asked for, never guessed: `t remind Report: send` asks when, `t remind daily 08:00` asks for the task.

Managing it:

| You type | Does |
|---|---|
| `t r` | Shows the routine, numbered, with when each entry runs |
| `t r 3 weekdays 09:00` | Moves task 3 from your list into the routine. Takes numbers or a `Parent:`, then `[remind] <when> <time>` |
| `t r 4 tomorrow 9am` | Puts task 4 away until tomorrow at 9 |
| `t r Morning: floss` | Adds a task to the routine group `Morning`; `t r Morning:` asks for several |
| `t r x 2` (or `t r del 2 5`) | Removes entries after confirmation |
| `t r e` (or `t r edit`) | Opens `routine.txt` in your editor |

`routine.txt` is plain text in the same shape as `todo.txt`, so you can edit it on any device:

```
weekdays 14:00 timesheet
remind mon,thu 17:00 call supplier
remind 2026-11-20 10:00 renew licence
remind weekdays 07:00 Morning:
  stretch
  plan the day
```

The same rules hold there as on the command line. A line without both a when and a time never runs; it is kept, `t r` marks it with a yellow `?` and the reason, and `t r e` tells you when you close the editor. `today`, `tomorrow` and `next <day>` written by hand count from the day the file was saved, and `t` replaces them with the date the next time it writes the file. Lines starting with `#` are ignored.

How a repeating entry runs:

- At its time the task goes to the top of your list: when the reminder runs, or on the first `t` after that time.
- Each day starts fresh. Routine tasks from the previous day that are still on your list are removed and logged as `YYYY-MM-DD missed: task` in `done.txt`. So are entries whose time never came up, and every entry of days on which `t` never ran (up to the last 31 days).
- A routine task already on your list is not added twice.
- A group puts each of its tasks on the list; each is done, or logged as missed, on its own, and the reminder names the group once.
- An entry added during the day whose time has already passed shows up at the next `t`.

A one-time entry goes to the top at its time too, then leaves `routine.txt` and is an ordinary task: it stays until you finish it and is never logged as missed. If the PC was off, it arrives at the next start.

## Reminders

A Task Scheduler task, `OneTask`, runs `t --remind` silently (`conhost.exe --headless`, no elevation). It has three triggers:

- a one-shot at the next routine time (looking up to 7 days ahead for repeating entries, and at every one-time entry)
- at logon
- on resume from sleep

Each run puts the due tasks at the top of `todo.txt` and, for entries with `remind`, shows one notification: the task itself, or "3 tasks due" with their names after a wake or logon. Only today's repeating entries fire late; earlier days are logged as missed. Every run re-arms the one-shot.

The task is armed by the first `t` after `setup`, and again by the first `t` after `routine.txt` changes, which takes about a second once. Do Not Disturb holds the notifications as usual.

## Log

`t log` reads `done.txt` and reports; it never changes anything.

```
this week: 12 done, 1 dropped, 3 missed
routine, last 4 weeks:
  timesheet  16 of 20 days  80%  streak 3
  Morning     9 of 20 days  45%  streak 0
```

`t log timesheet` shows one routine entry: the days it was kept out of the days it was due, the current streak, and a row of marks for the last 20 of those days (`x` kept, `.` missed), oldest first. A group counts as kept on a day only when none of its tasks was missed. The figures are green from 80%, yellow from 50% and red below.

For a name that is not in the routine, `t log blog` counts the finished tasks called `blog` or filed under the parent `blog`:

```
blog: 3 done (1 this week), last on 2026-11-06
```

The name can be typed with or without its colon, and part of it is enough: `t log morning routine` and `t log morn` both find `Morning`. If several names match, they are listed with their counts; if none does, `t log` says so and lists your routine names.

## Hints

`t` keeps the order you give the list and never reorders it, but it points things out in one dim line:

- `t list` shows how long a task has been on the list once it is three days old (`5d`, `3w`).
- When the current task has been skipped three times: `skipped 3 times: too big, or not wanted? (t e to reword it, t del to drop it)`
- After a `t done`, at most once a day, the task that has waited longest, if that is three weeks or more: `waiting 5 weeks: renew passport  (t now 7)`.

## Conflict copies

If two PCs change the same file before it syncs, the sync app keeps both and saves one as a copy:

| Sync app | Copy name |
|---|---|
| OneDrive | `todo-<PC>.txt` |
| Dropbox | `todo (<PC>'s conflicted copy <date>).txt` |
| Google Drive | `todo (1).txt` or `todo_conf(1).txt` |
| iCloud Drive | `todo 2.txt` |

`t` and `t list` then print a one-line notice; capture (`t <text>`) never does. `t merge` shows what it will do and asks first:

- a `todo` copy: its tasks that are not already in `todo.txt` go to the bottom. It skips tasks logged in `done.txt` from a week before the copy onwards, so finished tasks don't come back, and routine tasks, which the routine adds itself.
- a `done` copy: its lines that are not already in `done.txt` are appended.
- a copy of `routine.last`, `todo.undo` or `todo.age`: deleted; they are the tool's own state.
- a `routine.txt` copy: not merged. Compare it with `t r` and delete it yourself.

Merged copies are deleted; most sync apps keep them in their recycle bin.

## Uninstall

```powershell
t uninstall
```

Run it from the same shell edition that ran `setup` (Windows PowerShell or PowerShell 7) so it can restore the execution policy. It removes the `# one-task` profile lines (and a `profile.ps1` left empty) and the `OneTask` scheduled task, restores the previous CurrentUser execution policy if it is still `RemoteSigned`, and deletes `HKCU\Software\OneTask`. Everything in the task folder is kept on purpose; delete the folder yourself if you no longer want your tasks.

## Known limitations

- **Tidying:** `t` trims tasks, collapses runs of spaces and stores indentation as two spaces when it next changes `todo.txt` or `routine.txt`; comments in `routine.txt` are kept. `t list` marks a task that repeats an earlier one with `(same as #n)`.
- **Reserved first words:** the verbs (`list`, `find`, `done`, `skip`, `now`, `del`, `edit`, `undo`, `routine`, `log`, `help`, `merge`, `setup`, `uninstall`, `remind`), their one-letter forms (`l f d s n x e u r g h`) and a when followed by a time are never parked as a task. Quote such a task: `t "log hours"`. A single quoted word is not enough to tell it apart, so a task cannot be exactly one of those words.
- **`: ` makes a parent:** a task such as `fix: login bug` is stored under a parent `fix`. A task that ends in a colon loses the colon.
- **One level of parents:** a parent cannot hold another parent.
- **Routine entries need a time:** there is no "some time today" entry; pick a time. One-time entries need one as well.
- **A day name repeats:** `fri 17:00` is every Friday. For this Friday only, use `next fri` (or `today`/`tomorrow`, or the date).
- **No reminder for a single step of a group:** the group arrives as a whole at its time. Give a step its own entry if it needs its own time.
- **Routine tasks are matched by name:** a note keeps a task a routine task. Rewording it, or editing its line in `routine.txt`, during the day turns that day's copy into a normal task that is not removed or logged as missed.
- **Routine edits from another device:** the reminder schedule updates at the next `t` on this PC, or at the next reminder, logon or wake. Until then a new entry can fire late.
- **Ages are per PC and per wording:** a task's age starts when `t` on this PC first changes the list with the task on it, and starts again if you reword it in an editor (`t e <n> <text>` keeps it).
- **The log matches by name:** rewording a routine entry or a task name starts a new history. Days the PC was off count as missed (up to 31), so a holiday lowers the figures.
- **Notification source:** notifications show as coming from Windows PowerShell, because the tool registers no app of its own.
- **Two PCs on the same day:** if both start a new routine day before the files sync, `done.txt` can get duplicate `missed:` lines, and a one-time entry can arrive on both.
- **PowerShell syntax in tasks:** `'`, `;`, `#`, `|`, `&`, `(` and `$` are read by PowerShell before `t` runs; a lone `'` makes it wait for a closing quote (`>>`). Quote the task (`t "don't forget"`), or type it at the prompt of `t Parent:`, which takes the line as typed.
- **Stale numbers:** `t done <n>` uses the current file, which may have changed since `t list` (another terminal, or a sync). It says which task it logged; `t undo` takes a wrong one back.
- **Undo is one step.** It covers the last change `t` made to your tasks or your routine, and an edit made through `t e` or `t r e`. It does not bring back merged conflict copies or a one-time entry that has arrived. If the files changed in between (a sync, a reminder, a new routine day), it asks first and leaves `done.txt` alone.
- **Changes from outside:** if `todo.txt` changes while `t` waits for your answer (a sync or a reminder), `t` changes nothing and asks you to run the command again.
- **The editor blocks the terminal:** `t e` waits until the editor closes, Notepad included.
- **Several PCs:** if Documents is synced (OneDrive folder backup does this), the profile line is shared too. It is skipped on a PC where the script path does not exist, so clone the repo to the same path on each PC. The task folder path must match as well.
- **Google Drive streaming:** in the default streaming mode files are online-only, so the first `t` after a restart can be slow while they download. Mark the task folder "Available offline" to avoid it.
- **Sync app detection:** only the default locations are found. Pick "Other folder" for anything else.
- **Merging is by text:** a task changed on both PCs comes back as two tasks; a task finished more than a week before the copy was written can come back. Both show in the confirmation before anything changes.
- **Group Policy:** an execution policy set by Group Policy cannot be changed by `setup`; it reports this instead.
- **`done.txt` grows** by one short line per finished task and is never pruned; it is your record.
