# Auto Theme Switch

Switches Windows to dark mode at sunset and light mode at sunrise. One PowerShell script, no dependencies, no persistent process.

## How it works

- Sunrise/sunset is computed locally from your latitude/longitude (no API, no data files).
- `auto` applies day/night only when the phase has changed, so a manual `toggle` holds until the next sunrise/sunset.
- After each run, `auto` re-registers a single Task Scheduler task `ThemeSwitch` with these triggers:
  - a one-shot at the next sunrise/sunset
  - at logon
  - on resume from sleep

  The logon and resume triggers cover a missed transition (PC off or asleep).
- Theme change = registry write (`AppsUseLightTheme`, `SystemUsesLightTheme`) + `WM_SETTINGCHANGE` broadcast, so apps repaint immediately.
- The task runs via `conhost.exe --headless`, so no console window flashes.

## Requirements

- Windows 11 (developed and tested on 11 build 22631) and the built-in Windows PowerShell 5.1.
- `conhost.exe --headless` is what keeps the scheduled run silent. On older Windows 10 builds it may be missing and a console window can flash.

## Setup (once, no elevation needed)

Clone or download the repo, then run from the `auto-theme-switch` folder:

```powershell
powershell -ExecutionPolicy Bypass -File themeswitch.ps1 setup
```

Location comes from Windows (Settings > Privacy > Location must be on). Windows may return a coarse IP-based position, which is fine, since being off by 50 km changes sunrise/sunset by under a minute. To set it explicitly, or if Windows location is unavailable:

```powershell
powershell -ExecutionPolicy Bypass -File themeswitch.ps1 setup -Lat 51.5074 -Lng -0.1278
```

Re-run `setup` if you move, or if you move/rename the script folder, since the task stores the script's path.

## Commands

| Command | Does |
|---|---|
| `setup [-Lat -Lng]` | Saves location to `HKCU\Software\ThemeSwitch`, applies the current phase, registers the task |
| `auto` | Default; run by the task. Applies the phase if changed and schedules the next transition |
| `toggle` | Flips light/dark manually |
| `status` | Prints computed sunrise/sunset and current phase; changes nothing |
| `uninstall` | Removes the task, saved settings and log, and resets the theme to light |

## Manual toggle shortcut

Create a shortcut with this target (use your own path; optionally assign a hotkey in the shortcut's properties, which allows Ctrl+Alt combinations):

```
conhost.exe --headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\path\to\auto-theme-switch\themeswitch.ps1" toggle
```

Or, with [AutoHotkey v2](https://www.autohotkey.com/), bind it to Win+\:

```autohotkey
#Requires AutoHotkey v2.0
#\::Run('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\path\to\auto-theme-switch\themeswitch.ps1" toggle', , 'Hide')
```

## Troubleshooting

- Check `themeswitch.log` next to the script. Every run appends one line, including errors; entries older than 7 days are dropped.

## Known limitations

- **Execution policy:** `-ExecutionPolicy Bypass` on the command line can be overridden by Group Policy on managed machines.
- **Language mode:** the theme broadcast uses `Add-Type`, which needs PowerShell full language mode. AppLocker or constrained-language policies would break it.
- **No unlock trigger:** session-unlock triggers require elevation, so catch-up relies on logon, resume from sleep and the one-shot trigger.
- **Time zones:** the sun calculation assumes the local date matches the UTC date at sunrise and sunset. That holds across Europe, Africa, Asia and Australia but may be off by a day in the Americas.
- **Polar regions:** polar day/night (no sunrise or sunset) is not handled and makes the calculation fail.
- **Moving the script:** the task stores the script's path, so re-run `setup` after moving or renaming the folder.
- **Coarse location:** Windows may return an approximate (IP-based) position. This shifts sunrise/sunset by about a minute or two; pass `-Lat`/`-Lng` to pin it.
- **Accuracy:** sun times come from a simple almanac algorithm and are typically within 2 minutes of published values.
