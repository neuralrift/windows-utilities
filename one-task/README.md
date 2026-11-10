# One Task

A terminal todo that shows **one task**: the one that matters now. Every new terminal shows it; nothing in normal use shows the whole list. One PowerShell script, no dependencies, plain-text data synced by your cloud storage.

## How it works

- The command is `t`. The script lives in this repo; your profile dot-sources it, so every new terminal prints the current task. With nothing to do, a new terminal prints nothing; typing `t` still says so.
- Tasks live in the task folder chosen at setup, by default `Apps\one-task\` in your OneDrive, Google Drive, Dropbox or iCloud Drive folder:
  - `todo.txt`: one task per line, line 1 is the current task. Edit it in Notepad or on your phone; blank lines are ignored.
  - `done.txt`: a log of `YYYY-MM-DD task` lines, and `YYYY-MM-DD missed: task` for routine tasks left undone. Nothing reads it back.
  - `routine.txt`: your daily routine (see below). `routine.last` is the tool's own record of the current routine day; leave it alone.
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

| Command | Does |
|---|---|
| `t` | Shows the current task |
| `t <text>` | Parks a task at the bottom; never asks anything |
| `t done` | Logs the current task to `done.txt` and shows the next one |
| `t done 2 4` | Logs tasks 2 and 4 (numbers from `t list`), after confirmation |
| `t done <text>` | Logs the one task containing the text, after confirmation; if several match, prints them with their numbers |
| `t skip` | Moves the current task to the bottom |
| `t now <text>` | Puts a task at the top (for interruptions) |
| `t split <a> / <b> / <c>` | Replaces the current task with its steps, e.g. `write report: a`, `write report: b` |
| `t list` | Shows all tasks, numbered |
| `t edit` | Opens `todo.txt` in Notepad |
| `t routine` | Opens `routine.txt` in Notepad |
| `t merge` | Merges conflict copies left by your sync app, after confirmation (see below) |
| `t setup` | See Setup |
| `t uninstall` | Removes the profile lines and restores the execution policy; keeps your tasks |

`t remind` is run by the reminder task; you don't need it.

`list`, `edit`, `routine`, `remind`, `merge`, `skip`, `setup` and `uninstall` only act when typed alone, so `t list groceries` parks a task.

## Daily routine

`routine.txt` holds tasks you do regularly, one per line. Lines starting with `#` are ignored. Each line may start with a day prefix and then a time:

| Line | Added |
|---|---|
| `review inbox` | Every day, in the morning |
| `weekdays standup prep` | Monday to Friday, in the morning |
| `weekends gym` | Saturday and Sunday, in the morning |
| `weekdays 14:00 timesheet` | Monday to Friday, at 14:00 |
| `mon,thu 17:00 call supplier` | Monday and Thursday, at 17:00 |

- On the first `t` of a day, untimed routine tasks for that day go to the top of `todo.txt`, in file order.
- A timed task goes to the top at its time, with a Windows notification (see Reminders). If no reminder ran, it goes to the top on the first `t` after its time.
- Each day starts fresh: routine tasks from the previous day that are still in `todo.txt` are removed and logged as `YYYY-MM-DD missed: task` in `done.txt`. So are timed tasks whose time never came up in a terminal, and every routine task of days on which `t` never ran (up to the last 31 days).
- A routine task already in `todo.txt` is not added twice.

## Reminders

A Task Scheduler task, `OneTask`, runs `t remind` silently (`conhost.exe --headless`, no elevation). It has three triggers:

- a one-shot at the next timed routine task (looking up to 7 days ahead)
- at logon
- on resume from sleep

Each run puts the due timed tasks at the top of `todo.txt` and shows one notification: the task itself, or "3 tasks due" with their names after a wake or logon. Only today's tasks fire late; earlier days are logged as missed. Every run re-arms the one-shot for the next timed task.

The task is armed by the first `t` after `setup`, and again by the first `t` after `routine.txt` changes, which takes about a second once. Do Not Disturb holds the notifications as usual.

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
- a `routine.last` copy: deleted; it is the tool's own state.
- a `routine.txt` copy: not merged. Compare it with `t routine` and delete it yourself.

Merged copies are deleted; most sync apps keep them in their recycle bin.

## Uninstall

```powershell
t uninstall
```

Run it from the same shell edition that ran `setup` (Windows PowerShell or PowerShell 7) so it can restore the execution policy. It removes the `# one-task` profile lines (and a `profile.ps1` left empty) and the `OneTask` scheduled task, restores the previous CurrentUser execution policy if it is still `RemoteSigned`, and deletes `HKCU\Software\OneTask`. Your `todo.txt`, `done.txt` and `routine.txt` are kept on purpose; delete the task folder yourself if you no longer want them.

## Known limitations

- **Reserved first words:** a task cannot start with `done`, `now` or `split`, nor be exactly `list`, `edit`, `routine`, `skip`, `setup` or `uninstall`.
- **Routine prefixes:** in `routine.txt`, a first word such as `sat` or `weekdays` followed by more text is read as a day prefix, and `HH:MM` as a time. A routine task that should start with such a word cannot.
- **Routine tasks are matched by text:** editing a routine line, or the task in `todo.txt`, during the day turns that day's copy into a normal task that is not removed or logged as missed.
- **Routine edits from another device:** the reminder schedule updates at the next `t` on this PC, or at the next reminder, logon or wake. Until then a new timed task can fire late.
- **Notification source:** notifications show as coming from Windows PowerShell, because the tool registers no app of its own.
- **Reserved first word:** `remind` cannot be parked as a one-word task.
- **Two PCs on the same day:** if both start a new routine day before the files sync, `done.txt` can get duplicate `missed:` lines.
- **PowerShell syntax in tasks:** characters such as `;`, `#`, `|`, `&`, `(` and `$` are interpreted by PowerShell. Quote the task (`t 'pay rent; call bank'`) or use `t edit`.
- **Stale numbers:** `t done <n>` uses the current file, which may have changed since `t list` (another terminal, or a sync). The confirmation shows the tasks before anything is logged.
- **Several PCs:** if Documents is synced (OneDrive folder backup does this), the profile line is shared too. It is skipped on a PC where the script path does not exist, so clone the repo to the same path on each PC. The task folder path must match as well.
- **Google Drive streaming:** in the default streaming mode files are online-only, so the first `t` after a restart can be slow while they download. Mark the task folder "Available offline" to avoid it.
- **Sync app detection:** only the default locations are found. Pick "Other folder" for anything else.
- **Merging is by text:** a task changed on both PCs comes back as two tasks; a task finished more than a week before the copy was written can come back. Both show in the confirmation before anything changes.
- **Group Policy:** an execution policy set by Group Policy cannot be changed by `setup`; it reports this instead.
- **`done.txt` grows** by one short line per finished task and is never pruned; it is your record.
