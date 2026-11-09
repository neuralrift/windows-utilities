# t - one task at a time. Works in Windows PowerShell 5.1 and PowerShell 7.
# Usage: t | t <task> | t done [n ...|text] | t skip | t now <task> | t split <a> / <b>
#        t list | t edit | t setup | t uninstall
[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$Root,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Command
)

$OneTaskVersion = '1.0.0'
$OneTaskScript  = $PSCommandPath
$OneTaskRoot    = if ($Root) { $Root } else { $env:OneDrive }
$OneTaskMarker  = '# one-task'

function t {
    $a    = @($args | ForEach-Object { [string]$_ })
    $cmd  = if ($a.Count) { $a[0] } else { '' }
    $rest = @($a | Select-Object -Skip 1)
    # Commands that take no text only count when typed alone: "t list groceries" is parked
    if ($rest.Count -and $cmd -in 'list', 'edit', 'skip', 'setup', 'uninstall') { $cmd = 'park' }

    $dir   = if ($OneTaskRoot) { Join-Path $OneTaskRoot 'Apps\one-task' } else { '' }
    $TODO  = Join-Path "$dir\" 'todo.txt'
    $DONE  = Join-Path "$dir\" 'done.txt'
    $docs  = [Environment]::GetFolderPath('MyDocuments')
    $profs = @("$docs\WindowsPowerShell\profile.ps1", "$docs\PowerShell\profile.ps1")
    $key   = 'HKCU:\Software\OneTask'

    if ($cmd -notin 'setup', 'uninstall') {
        if (-not $dir) { Write-Host 'No OneDrive folder found. Run: t setup' -ForegroundColor Yellow; return }
        if (-not (Test-Path $TODO)) { New-Item $dir -ItemType Directory -Force | Out-Null; New-Item $TODO -ItemType File | Out-Null }
        $tasks = @([IO.File]::ReadAllLines($TODO) | Where-Object { $_.Trim() })
    }

    switch ($cmd) {
        '' {
            if ($tasks.Count) { Write-Host "$([char]0x25B6) $($tasks[0])" -ForegroundColor Cyan }
            else { Write-Host 'Nothing to do. Add one: t <task>' -ForegroundColor DarkGray }
            return
        }
        'done' {
            if (-not $tasks.Count) { return }
            $pick = @(0)
            if ($rest.Count) {
                if (@($rest -notmatch '^\d+$').Count -eq 0) {
                    $pick = @($rest | ForEach-Object { [int]$_ - 1 } | Sort-Object -Unique)
                    if (@($pick | Where-Object { $_ -lt 0 -or $_ -ge $tasks.Count }).Count) { Write-Host 'No such task number. See: t list' -ForegroundColor Yellow; return }
                } else {
                    $text = $rest -join ' '
                    $pick = @(0..($tasks.Count - 1) | Where-Object { $tasks[$_].IndexOf($text, [StringComparison]::OrdinalIgnoreCase) -ge 0 })
                    if (-not $pick.Count) { Write-Host "No task matches '$text'." -ForegroundColor Yellow; return }
                    if ($pick.Count -gt 1) {
                        $pick | ForEach-Object { Write-Host "$($_ + 1). $($tasks[$_])" }
                        Write-Host 'Several match. Use: t done <number>' -ForegroundColor DarkGray
                        return
                    }
                }
                $pick | ForEach-Object { Write-Host "  $($tasks[$_])" }
                if ((Read-Host 'Mark done? [y/N]') -ne 'y') { return }
            }
            $day = Get-Date -Format yyyy-MM-dd
            $pick | ForEach-Object { [IO.File]::AppendAllText($DONE, "$day $($tasks[$_])`r`n") }
            $tasks = @(for ($i = 0; $i -lt $tasks.Count; $i++) { if ($i -notin $pick) { $tasks[$i] } })
        }
        'skip' {
            if (-not $tasks.Count) { return }
            $tasks = @($tasks | Select-Object -Skip 1) + $tasks[0]
        }
        'now' {
            if (-not $rest.Count) { return }
            $tasks = @($rest -join ' ') + $tasks
        }
        'split' {
            # PowerShell treats ";" as a statement separator, so steps are separated by " / "
            $parts = @(($rest -join ' ') -split '\s+/\s+' | Where-Object { $_.Trim() })
            if (-not $tasks.Count -or $parts.Count -lt 2) { Write-Host 'Usage: t split <step> / <step> ...' -ForegroundColor Yellow; return }
            $tasks = @($parts | ForEach-Object { "$($tasks[0]): $($_.Trim())" }) + @($tasks | Select-Object -Skip 1)
        }
        'list' {
            if (-not $tasks.Count) { Write-Host 'Nothing to do. Add one: t <task>' -ForegroundColor DarkGray; return }
            for ($i = 0; $i -lt $tasks.Count; $i++) { Write-Host "$($i + 1). $($tasks[$i])" -ForegroundColor $(if ($i) { 'Gray' } else { 'Cyan' }) }
            return
        }
        'edit' { notepad $TODO; return }
        'setup' {
            # A -Root passed on the command line or by the profile line wins; otherwise ask when there are several OneDrives
            $base = $Root
            if (-not $base) {
                $drives = @($env:OneDriveConsumer, $env:OneDriveCommercial, $env:OneDrive | Where-Object { $_ } | Select-Object -Unique)
                if (-not $drives.Count) { Write-Host 'No OneDrive folder found. Run the script with: setup -Root <folder>' -ForegroundColor Yellow; return }
                $base = $drives[0]
                if ($drives.Count -gt 1) {
                    for ($i = 0; $i -lt $drives.Count; $i++) { Write-Host "$($i + 1). $($drives[$i])" }
                    $n = Read-Host 'Which OneDrive holds your tasks? [1]'
                    if ($n -match '^\d+$' -and [int]$n -ge 1 -and [int]$n -le $drives.Count) { $base = $drives[[int]$n - 1] }
                }
            }
            $dir = Join-Path $base 'Apps\one-task'
            New-Item $dir -ItemType Directory -Force | Out-Null
            foreach ($f in 'todo.txt', 'done.txt') {
                $old = Join-Path $base $f
                if ((Test-Path $old) -and -not (Test-Path (Join-Path $dir $f)) -and (Read-Host "Move $old to $dir? [y/N]") -eq 'y') { Move-Item $old $dir }
            }

            # Profiles may sync between PCs through OneDrive, so the line is skipped where the script path does not exist
            $s = $OneTaskScript.Replace("'", "''")
            $line = "if (Test-Path '$s') { . '$s' -Root '$($base.Replace("'", "''"))' }  $OneTaskMarker"
            $hasPwsh = [bool](Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue)
            foreach ($p in $profs) {
                if ($p -eq $profs[1] -and -not $hasPwsh -and -not (Test-Path (Split-Path $p))) { continue }
                $lines = if (Test-Path $p) { @([IO.File]::ReadAllLines($p) | Where-Object { -not $_.EndsWith($OneTaskMarker) }) } else { @() }
                New-Item (Split-Path $p) -ItemType Directory -Force | Out-Null
                [IO.File]::WriteAllLines($p, [string[]]($lines + $line), (New-Object Text.UTF8Encoding $true))
                Write-Host "Profile: $p"
            }
            Get-ChildItem ($profs | Split-Path) -Filter '*profile.ps1' -ErrorAction SilentlyContinue |
                Select-String -Pattern '[\\/"'' ]t\.ps1' | Where-Object { -not $_.Line.EndsWith($OneTaskMarker) } |
                ForEach-Object { Write-Host "Old t line, remove it: $($_.Path):$($_.LineNumber)" -ForegroundColor Yellow }

            # The profile only runs if the execution policy allows local scripts
            $gpo  = @('MachinePolicy', 'UserPolicy' | ForEach-Object { "$(Get-ExecutionPolicy -Scope $_)" } | Where-Object { $_ -ne 'Undefined' })
            $user = "$(Get-ExecutionPolicy -Scope CurrentUser)"
            $eff  = if ($gpo.Count) { $gpo[0] } elseif ($user -ne 'Undefined') { $user } else { "$(Get-ExecutionPolicy -Scope LocalMachine)" }
            if ($eff -eq 'Undefined') { $eff = if ($PSVersionTable.PSEdition -eq 'Core') { 'RemoteSigned' } else { 'Restricted' } }
            if ($eff -in 'Restricted', 'AllSigned') {
                if ($gpo.Count) { Write-Host "Group Policy sets the execution policy to $eff, so the profile cannot load t." -ForegroundColor Yellow }
                else {
                    New-Item $key -Force | Out-Null
                    Set-ItemProperty $key PrevPolicy $user
                    Set-ItemProperty $key Edition $PSVersionTable.PSEdition
                    # Errors when the Process scope overrides it (as with -ExecutionPolicy Bypass); checked below instead
                    try { Set-ExecutionPolicy RemoteSigned -Scope CurrentUser -Force -ErrorAction Stop } catch { }
                    if ("$(Get-ExecutionPolicy -Scope CurrentUser)" -eq 'RemoteSigned') { Write-Host "Execution policy (CurrentUser): $user -> RemoteSigned" }
                    else { Write-Host 'Could not set the execution policy to RemoteSigned.' -ForegroundColor Yellow }
                }
            }
            Write-Host "Tasks: $dir. Open a new terminal to see your task." -ForegroundColor DarkGray
            return
        }
        'uninstall' {
            foreach ($p in $profs) {
                if (-not (Test-Path $p)) { continue }
                $lines = @([IO.File]::ReadAllLines($p) | Where-Object { -not $_.EndsWith($OneTaskMarker) })
                if (@($lines | Where-Object { $_.Trim() }).Count) { [IO.File]::WriteAllLines($p, [string[]]$lines, (New-Object Text.UTF8Encoding $true)) }
                else { Remove-Item $p }
                Write-Host "Profile cleaned: $p"
            }
            if (Test-Path $key) {
                $k = Get-ItemProperty $key
                if ($k.Edition -ne $PSVersionTable.PSEdition) { Write-Host "Run uninstall from the shell that ran setup ($($k.Edition) edition) to restore the execution policy." -ForegroundColor Yellow; return }
                # Only restore if nobody changed it since setup
                if ("$(Get-ExecutionPolicy -Scope CurrentUser)" -eq 'RemoteSigned') {
                    try { Set-ExecutionPolicy $k.PrevPolicy -Scope CurrentUser -Force -ErrorAction Stop } catch { }
                    Write-Host "Execution policy (CurrentUser) restored to $($k.PrevPolicy)"
                }
                Remove-Item $key -Recurse
            }
            if ($dir) { Write-Host "Your tasks were kept in $dir" -ForegroundColor DarkGray }
            return
        }
        default {
            $tasks += ($a -join ' ')
            [IO.File]::WriteAllLines($TODO, [string[]]$tasks)
            Write-Host 'parked.' -ForegroundColor DarkGray
            return
        }
    }
    [IO.File]::WriteAllLines($TODO, [string[]]$tasks)
    t
}

if ($Command) { t @Command } else { t }   # bare t shows the one task whenever a terminal opens
