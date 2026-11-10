# t - one task at a time. Works in Windows PowerShell 5.1 and PowerShell 7.
# Usage: t | t <task> | t done [n ...|text] | t skip | t now <task> | t split <a> / <b>
#        t list | t edit | t routine | t merge | t setup | t uninstall   (t remind is run by the scheduled task)
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
    if ($rest.Count -and $cmd -in 'list', 'edit', 'routine', 'remind', 'merge', 'skip', 'setup', 'uninstall') { $cmd = 'park' }

    $dir   = if ($OneTaskRoot) { Join-Path $OneTaskRoot 'Apps\one-task' } else { '' }
    $TODO  = Join-Path "$dir\" 'todo.txt'
    $DONE  = Join-Path "$dir\" 'done.txt'
    $docs  = [Environment]::GetFolderPath('MyDocuments')
    $profs = @("$docs\WindowsPowerShell\profile.ps1", "$docs\PowerShell\profile.ps1")
    $key   = 'HKCU:\Software\OneTask'
    $now   = if ($OneTaskNow) { [datetime]$OneTaskNow } else { Get-Date }   # $OneTaskNow fakes the clock in tests
    $day   = $now.ToString('yyyy-MM-dd')

    if ($cmd -notin 'setup', 'uninstall') {
        if (-not $dir) { Write-Host 'No OneDrive folder found. Run: t setup' -ForegroundColor Yellow; return }
        if (-not (Test-Path $TODO)) { New-Item $dir -ItemType Directory -Force | Out-Null; New-Item $TODO -ItemType File | Out-Null }
        $tasks = @([IO.File]::ReadAllLines($TODO) | Where-Object { $_.Trim() })

        # Routine: on a new day, log yesterday's unfinished routine tasks as missed and add today's;
        # timed ones are added at the top on the first t at or after their time.
        # routine.last holds the date of the last routine day, then the tasks added on it.
        $ROUTINE = Join-Path $dir 'routine.txt'
        $LAST    = Join-Path $dir 'routine.last'   # PowerShell names are case-insensitive: no other $last/$state below
        $due     = @()
        if (Test-Path $ROUTINE) {
            $names = @{ sun = 0; mon = 1; tue = 2; wed = 3; thu = 4; fri = 5; sat = 6 }
            $n = 0
            $items = foreach ($l in [IO.File]::ReadAllLines($ROUTINE)) {
                $n++
                $w = @($l.Trim() -split '\s+')
                if (-not $l.Trim() -or $w[0].StartsWith('#')) { continue }
                $days = 0..6; $at = $null
                if ($w.Count -gt 1 -and $w[0] -match '^(daily|weekdays|weekends|((sun|mon|tue|wed|thu|fri|sat),?)+)$') {
                    $days = switch ($w[0]) { 'daily' { 0..6 } 'weekdays' { 1..5 } 'weekends' { 0, 6 } default { @($w[0] -split ',' | Where-Object { $_ } | ForEach-Object { $names[$_] }) } }
                    $w = @($w | Select-Object -Skip 1)
                }
                if ($w.Count -gt 1 -and $w[0] -match '^([01]?\d|2[0-3]):[0-5]\d$') { $at = [timespan]$w[0]; $w = @($w | Select-Object -Skip 1) }
                [pscustomobject]@{ Days = @($days); At = $at; Text = $w -join ' '; Line = $n }
            }
            $items = @($items)
            # @() around if: an if expression unrolls a one-element array into a bare string
            $memo  = @(if (Test-Path $LAST) { [IO.File]::ReadAllLines($LAST) })
            $prevDay = if ($memo.Count) { $memo[0] } else { '' }
            $added = @($memo | Select-Object -Skip 1)
            $log   = @()
            $newDay = $prevDay -lt $day
            if ($newDay) {
                if ($prevDay) {
                    $prev = [datetime]::ParseExact($prevDay, 'yyyy-MM-dd', $null)
                    foreach ($t in $added) { if ($tasks -contains $t) { $log += "$prevDay missed: $t" } }
                    $tasks = @($tasks | Where-Object { $added -notcontains $_ })
                    foreach ($r in $items) { if ($r.At -and $r.Days -contains [int]$prev.DayOfWeek -and $added -notcontains $r.Text) { $log += "$prevDay missed: $($r.Text)" } }
                    # Days without any t run (PC off), at most the last 31
                    $from = $prev.AddDays(1)
                    if ($from -lt $now.Date.AddDays(-31)) { $from = $now.Date.AddDays(-31) }
                    for ($x = $from; $x -lt $now.Date; $x = $x.AddDays(1)) {
                        foreach ($r in $items) { if ($r.Days -contains [int]$x.DayOfWeek) { $log += "$($x.ToString('yyyy-MM-dd')) missed: $($r.Text)" } }
                    }
                }
                $added = @($items | Where-Object { -not $_.At -and $_.Days -contains [int]$now.DayOfWeek -and $tasks -notcontains $_.Text } | ForEach-Object { $_.Text })
                $tasks = $added + $tasks
            }
            $due = @($items | Where-Object { $_.At -and $_.At -le $now.TimeOfDay -and $_.Days -contains [int]$now.DayOfWeek -and $added -notcontains $_.Text -and $tasks -notcontains $_.Text } |
                Sort-Object At, Line | ForEach-Object { $_.Text })
            if ($newDay -or $due.Count) {
                $tasks = $due + $tasks
                $added += $due
                if ($log.Count) { [IO.File]::AppendAllText($DONE, ($log -join "`r`n") + "`r`n") }
                [IO.File]::WriteAllLines($TODO, [string[]]$tasks)
                [IO.File]::WriteAllLines($LAST, [string[]](@($day) + $added))
            }

            # Reminders: one scheduled task, re-armed for the next timed routine task after every
            # reminder run and whenever routine.txt changes. Setup creates $key; without it nothing is armed.
            $stamp = "$((Get-Item $ROUTINE).LastWriteTimeUtc.Ticks)"
            if ((Test-Path $key) -and ($cmd -eq 'remind' -or (Get-ItemProperty $key).Stamp -ne $stamp)) {
                $next = $null
                for ($x = 0; $x -le 7 -and -not $next; $x++) {
                    $d = $now.Date.AddDays($x)
                    $next = @($items | Where-Object { $_.At -and $_.Days -contains [int]$d.DayOfWeek -and $d + $_.At -gt $now } | ForEach-Object { $d + $_.At } | Sort-Object) | Select-Object -First 1
                }
                $user   = "$env:USERDOMAIN\$env:USERNAME"
                $resume = New-CimInstance -CimClass (Get-CimClass MSFT_TaskEventTrigger root/Microsoft/Windows/TaskScheduler) -ClientOnly -Property @{
                    Enabled      = $true
                    Subscription = '<QueryList><Query Id="0" Path="System"><Select Path="System">*[System[Provider[@Name=''Microsoft-Windows-Power-Troubleshooter''] and EventID=1]]</Select></Query></QueryList>'
                }
                $trig = @((New-ScheduledTaskTrigger -AtLogOn -User $user), $resume)
                if ($next) { $trig += New-ScheduledTaskTrigger -Once -At $next }
                # Always Windows PowerShell: toasts need WinRT, which PowerShell 7 lacks
                Register-ScheduledTask OneTask -Force `
                    -Action (New-ScheduledTaskAction -Execute conhost.exe -Argument "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$OneTaskScript`" -Root `"$OneTaskRoot`" remind") `
                    -Trigger $trig `
                    -Settings (New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries) `
                    -Principal (New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited) | Out-Null
                Set-ItemProperty $key Stamp $stamp
            }
        }

        # OneDrive saves conflicting edits as copies such as todo-<PC>.txt; t and t list mention them, t merge merges them
        $copies = @(if ($cmd -in '', 'list', 'merge') { Get-ChildItem $dir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^(todo|done|routine)-.+\.(txt|last)$' } })
    }

    switch ($cmd) {
        '' {
            if ($tasks.Count) { Write-Host "$([char]0x25B6) $($tasks[0])" -ForegroundColor Cyan }
            elseif (-not $OneTaskOpening) { Write-Host 'Nothing to do. Add one: t <task>' -ForegroundColor DarkGray }
            if ($copies.Count) { Write-Host 'OneDrive saved a conflict copy. Run: t merge' -ForegroundColor Yellow }
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
            if ($copies.Count) { Write-Host 'OneDrive saved a conflict copy. Run: t merge' -ForegroundColor Yellow }
            return
        }
        'merge' {
            if (-not $copies.Count) { Write-Host 'No conflict copies.' -ForegroundColor DarkGray; return }
            $doneLines = @(if (Test-Path $DONE) { [IO.File]::ReadAllLines($DONE) })
            $newTasks = @(); $newDone = @(); $drop = @()
            foreach ($c in $copies) {
                $lines = @([IO.File]::ReadAllLines($c.FullName) | Where-Object { $_.Trim() })
                switch -Regex ($c.Name) {
                    '^todo-' {
                        # Skip tasks finished (or missed) since a week before the copy was written, so they are not
                        # brought back, and routine tasks, which the routine adds itself
                        $since = $c.LastWriteTime.AddDays(-7).ToString('yyyy-MM-dd')
                        $gone = @($doneLines | Where-Object { $_.Length -gt 11 -and $_.Substring(0, 10) -ge $since } | ForEach-Object { $_.Substring(11) -replace '^missed: ', '' })
                        $newTasks += @($lines | Where-Object { $tasks -notcontains $_ -and $gone -notcontains $_ -and @($items).Text -notcontains $_ })
                        $drop += $c
                    }
                    '^done-' { $newDone += @($lines | Where-Object { $doneLines -notcontains $_ }); $drop += $c }
                    '\.last$' { $drop += $c }   # the tool's own state; the main routine.last wins
                    default { Write-Host "$($c.Name): compare it with routine.txt (t routine), then delete it." -ForegroundColor Yellow }
                }
            }
            if (-not $drop.Count) { return }
            $newTasks = @($newTasks | Select-Object -Unique)
            $newDone  = @($newDone | Select-Object -Unique)
            if ($newTasks.Count) { Write-Host 'Add to the bottom of todo.txt:'; $newTasks | ForEach-Object { Write-Host "  $_" } }
            if ($newDone.Count) { Write-Host "Add $($newDone.Count) line(s) to done.txt" }
            Write-Host "Then delete: $(($drop | ForEach-Object { $_.Name }) -join ', ')"
            if ((Read-Host 'Merge? [y/N]') -ne 'y') { return }
            if ($newDone.Count) { [IO.File]::AppendAllText($DONE, ($newDone -join "`r`n") + "`r`n") }
            $drop | Remove-Item
            $tasks += $newTasks
        }
        'edit' { notepad $TODO; return }
        'routine' {
            if (-not (Test-Path $ROUTINE)) { Write-Host 'No routine.txt yet. Run: t setup' -ForegroundColor Yellow; return }
            notepad $ROUTINE; return
        }
        'remind' {
            # Run by the OneTask scheduled task. The routine code above has already put due tasks on top
            # and re-armed the task; this shows them, batched into one toast (several after a wake).
            if (-not $due.Count -or $PSVersionTable.PSEdition -ne 'Desktop') { return }
            $null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
            $null = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom, ContentType = WindowsRuntime]
            $lines = @(if ($due.Count -eq 1) { $due[0] } else { "$($due.Count) tasks due"; $due -join ', ' })
            $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
            $xml.LoadXml('<toast><visual><binding template="ToastGeneric">' + (($lines | ForEach-Object { "<text>$([Security.SecurityElement]::Escape($_))</text>" }) -join '') + '</binding></visual></toast>')
            $app = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
            [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($app).Show([Windows.UI.Notifications.ToastNotification]::new($xml))
            return
        }
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
            $r = Join-Path $dir 'routine.txt'
            if (-not (Test-Path $r)) {
                [IO.File]::WriteAllLines($r, [string[]]@(
                    '# Routine: one task per line, added to your list every day. Lines starting with # are ignored.'
                    '# Optional prefixes: weekdays, weekends, or days such as mon,thu; then a time (HH:MM)'
                    '# to add the task at that time instead of in the morning. Examples:'
                    '#   review inbox'
                    '#   weekdays standup prep'
                    '#   weekdays 14:00 timesheet'
                    '#   mon,thu 17:00 call supplier'))
            }
            # The next t arms the reminder task once this key exists and its Stamp differs from routine.txt
            if (-not (Test-Path $key)) { New-Item $key | Out-Null }
            Set-ItemProperty $key Stamp ''

            # Profiles may sync between PCs through OneDrive, so the line is skipped where the script path does not exist
            $s = $OneTaskScript.Replace("'", "''")
            $line = "if (Test-Path '$s') { . '$s' -Root '$($base.Replace("'", "''"))' }  $OneTaskMarker"
            $hasPwsh = [bool](Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue)
            foreach ($p in $profs) {
                if ($p -eq $profs[1] -and -not $hasPwsh -and -not (Test-Path (Split-Path $p))) { continue }
                $lines = @(if (Test-Path $p) { [IO.File]::ReadAllLines($p) | Where-Object { -not $_.EndsWith($OneTaskMarker) } })
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
            if (Get-ScheduledTask OneTask -ErrorAction SilentlyContinue) { Unregister-ScheduledTask OneTask -Confirm:$false; Write-Host 'Reminder task removed' }
            if (Test-Path $key) {
                $k = Get-ItemProperty $key
                if ($k.PrevPolicy -and $k.Edition -ne $PSVersionTable.PSEdition) { Write-Host "Run uninstall from the shell that ran setup ($($k.Edition) edition) to restore the execution policy." -ForegroundColor Yellow; return }
                # Only restore if nobody changed it since setup
                if ($k.PrevPolicy -and "$(Get-ExecutionPolicy -Scope CurrentUser)" -eq 'RemoteSigned') {
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

# Bare t shows the one task whenever a terminal opens; an empty list stays silent there
if ($Command) { t @Command } else { $OneTaskOpening = $true; t; $OneTaskOpening = $false }
