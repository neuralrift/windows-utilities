# AGENTS.md: auto-theme-switch

Applies on top of the repo-root `AGENTS.md`.

## What it is

A single PowerShell 5.1 script, `themeswitch.ps1`, that switches Windows between dark and light mode at sunset and sunrise. No dependencies; keep it a single file.

## Design (keep intact)

- Sun times are computed locally from lat/lng (almanac algorithm); there is no API or data file.
- The location is saved in `HKCU\Software\ThemeSwitch` (`Lat`, `Lng`, `Phase`). `setup` takes it from Windows location, falling back to `-Lat`/`-Lng`; never hardcode a location.
- `auto` is state-based and idempotent: it applies the theme only when `Phase` changes, so a manual `toggle` holds until the next transition. `toggle` must not touch `Phase`.
- One Task Scheduler task, `ThemeSwitch`, re-registered by every `auto` run with: a one-shot trigger at the next transition, logon, and resume from sleep (Power-Troubleshooter event 1). It always re-arms, even if applying the theme fails.
- Session-unlock triggers are deliberately not used because they require elevation.
- The theme is applied by writing `AppsUseLightTheme`/`SystemUsesLightTheme` and broadcasting `WM_SETTINGCHANGE` (`ImmersiveColorSet`).
- The task runs via `conhost.exe --headless powershell.exe ...` so no console flashes.
- `uninstall` removes the task, registry key and log, and resets the theme to light.
- `themeswitch.log` is written next to the script and pruned to the last 7 days on every write.

## When changing the script

- Update the command table, Requirements and Known limitations in `README.md` to match.
- If a change alters the task's trigger set or action, re-run `setup` to re-register it.
- Test with `status` first (changes nothing); restore your previous state after testing `setup`/`uninstall`.
- Everything must work without elevation on Windows 11.
