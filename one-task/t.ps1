# t - one task at a time. Works in Windows PowerShell 5.1 and PowerShell 7.
# Usage: t | t <task> [// note] | t add | t done [n ...|text] | t del [n ...|text] | t top <n|text> | t skip
#        t now <task> | t note <text> | t split <a> / <b> | t list | t edit [routine] | t merge | t help
#        t routine [list] | t routine <line> | t routine add | t routine del <n|text>
#        t setup | t uninstall   (t remind is run by the scheduled task)
[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$Folder,   # the task folder, used as is (what setup writes to the profile line)
    [string]$Root,     # a synced folder; tasks go in its Apps\one-task
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Command
)

$OneTaskVersion = '1.0.0'
$OneTaskScript  = $PSCommandPath
$OneTaskDir     = if ($Folder) { $Folder } elseif ($Root) { Join-Path $Root 'Apps\one-task' } elseif ($env:OneDrive) { Join-Path $env:OneDrive 'Apps\one-task' } else { '' }
$OneTaskMarker  = '# one-task'

function t {
    # PowerShell turns "milk, eggs" or "mon,thu" into an array argument; put the commas back
    $a    = @($args | ForEach-Object { if ($_ -is [array]) { $_ -join ', ' } else { [string]$_ } })
    $cmd  = if ($a.Count) { $a[0] } else { '' }
    $rest = @($a | Select-Object -Skip 1)
    # t routine [list|add|del] ...: alone or "list" lists, "del" removes, anything else is a routine line to add
    if ($cmd -eq 'routine') {
        $sub = if ($rest.Count) { $rest[0] } else { 'list' }
        if ($sub -in 'list', 'add', 'del') { $rest = @($rest | Select-Object -Skip 1) } else { $sub = 'add' }
        $cmd = "routine $sub"
        if ($sub -eq 'list' -and $rest.Count) { $cmd = 'routine add'; $rest = @('list') + $rest }   # "t routine list x" is a line
    }
    if ($cmd -eq 'edit' -and $rest.Count -eq 1 -and $rest[0] -in 'routine', 'routines') { $cmd = 'edit routine'; $rest = @() }
    # Commands that take no text only count when typed alone: "t list groceries" is parked
    if ($rest.Count -and $cmd -in 'list', 'edit', 'remind', 'merge', 'skip', 'add', 'help', '-h', '--help', '?', 'setup', 'uninstall') { $cmd = 'park' }
    if ($cmd -in '-h', '--help', '?') { $cmd = 'help' }

    $dir   = $OneTaskDir
    $TODO  = Join-Path "$dir\" 'todo.txt'
    $DONE  = Join-Path "$dir\" 'done.txt'
    $docs  = [Environment]::GetFolderPath('MyDocuments')
    $profs = @("$docs\WindowsPowerShell\profile.ps1", "$docs\PowerShell\profile.ps1")
    $key   = 'HKCU:\Software\OneTask'
    $now   = if ($OneTaskNow) { [datetime]$OneTaskNow } else { Get-Date }   # $OneTaskNow fakes the clock in tests
    $day   = $now.ToString('yyyy-MM-dd')
    # Test hooks: $OneTaskNow fakes the clock, $OneTaskNoArm leaves the scheduled task alone,
    # $OneTaskAnswers (a [Collections.Queue]) answers prompts in order
    $ask = { param($prompt) if ($OneTaskAnswers -is [Collections.Queue]) { if ($OneTaskAnswers.Count) { "$($OneTaskAnswers.Dequeue())" } else { '' } } else { Read-Host $prompt } }
    # One palette: Cyan current task, Gray other tasks, DarkGray notes and hints, Green done or on track,
    # Yellow needs attention, Red missed or error. NO_COLOR (any value) turns colour off.
    $say = { param($text, $color, [switch]$NoNewline) if ($color -and -not $env:NO_COLOR) { Write-Host $text -ForegroundColor $color -NoNewline:$NoNewline } else { Write-Host $text -NoNewline:$NoNewline } }

    if ($cmd -notin 'setup', 'uninstall') {
        if (-not $dir) { & $say 'No task folder set. Run: t setup' Yellow; return }
        if (-not (Test-Path $TODO)) { New-Item $dir -ItemType Directory -Force | Out-Null; New-Item $TODO -ItemType File | Out-Null }
        $tasks = @([IO.File]::ReadAllLines($TODO) | Where-Object { $_.Trim() })

        # Routine: on a new day, log yesterday's unfinished routine tasks as missed and add today's;
        # timed ones are added at the top on the first t at or after their time.
        # routine.last holds the date of the last routine day, then the tasks added on it.
        $ROUTINE = Join-Path $dir 'routine.txt'
        $LAST    = Join-Path $dir 'routine.last'   # PowerShell names are case-insensitive: no other $last/$state below
        $due     = @()
        # Reads one routine line, "[days] [HH:MM] task"; returns nothing for blank lines and # comments
        $parseLine = {
            param($l, $n)
            $d = 'sun|mon|tue|wed|thu|fri|sat'
            $w = @(("$l".Trim() -replace "(?<=\b($d))\s*,\s*(?=($d)\b)", ',') -split '\s+')   # "mon, thu" -> "mon,thu"
            if (-not "$l".Trim() -or $w[0].StartsWith('#')) { return }
            $names = @{ sun = 0; mon = 1; tue = 2; wed = 3; thu = 4; fri = 5; sat = 6 }
            $days = 0..6; $at = $null
            if ($w.Count -gt 1 -and $w[0] -match "^(daily|weekdays|weekends|(($d),?)+)$") {
                $days = switch ($w[0]) { 'daily' { 0..6 } 'weekdays' { 1..5 } 'weekends' { 0, 6 } default { @($w[0] -split ',' | Where-Object { $_ } | ForEach-Object { $names[$_] }) } }
                $w = @($w | Select-Object -Skip 1)
            }
            if ($w.Count -gt 1 -and $w[0] -match '^([01]?\d|2[0-3]):[0-5]\d$') { $at = [timespan]$w[0]; $w = @($w | Select-Object -Skip 1) }
            [pscustomobject]@{ Days = @($days); At = $at; Text = $w -join ' '; Line = $n }
        }
        $items = @()
        if (Test-Path $ROUTINE) {
            $n = 0
            $items = @(foreach ($l in [IO.File]::ReadAllLines($ROUTINE)) { $n++; & $parseLine $l $n })
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
            if (-not $OneTaskNoArm -and (Test-Path $key) -and ($cmd -eq 'remind' -or (Get-ItemProperty $key).Stamp -ne $stamp)) {
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
                    -Action (New-ScheduledTaskAction -Execute conhost.exe -Argument "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$OneTaskScript`" -Folder `"$OneTaskDir`" remind") `
                    -Trigger $trig `
                    -Settings (New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries) `
                    -Principal (New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited) | Out-Null
                Set-ItemProperty $key Stamp $stamp
            }
        }

        # Sync apps save conflicting edits as copies: todo-<PC>.txt (OneDrive), todo (<PC>'s conflicted copy ...).txt
        # (Dropbox), todo (1).txt or todo_conf(1).txt (Google Drive), todo 2.txt (iCloud). t and t list mention them, t merge merges them
        $copies = @(if ($cmd -in '', 'list', 'merge') { Get-ChildItem $dir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^(todo|done|routine)[-_ (].*\.(txt|last)$' } })
    }

    # A task line is "title // note"; the note is optional. Duplicates are judged on the title alone.
    $titleOf = { param($s) ($s -split ' // ', 2)[0].Trim() }
    $findDupe = { param($s) $k = & $titleOf $s; for ($i = 0; $i -lt $tasks.Count; $i++) { if ((& $titleOf $tasks[$i]) -eq $k) { return $i } }; -1 }
    # Describes when a routine entry runs, e.g. "weekdays at 14:00" or "every day, in the morning"
    $whenOf = {
        param($r)
        $day3 = 'sun', 'mon', 'tue', 'wed', 'thu', 'fri', 'sat'
        $w = switch ("$($r.Days | Sort-Object)") { '0 1 2 3 4 5 6' { 'every day' } '1 2 3 4 5' { 'weekdays' } '0 6' { 'weekends' } default { ($r.Days | Sort-Object | ForEach-Object { $day3[$_] }) -join ',' } }
        $w + $(if ($r.At) { " at $($r.At.ToString('hh\:mm'))" } else { ', in the morning' })
    }
    # Picks entries of $list by numbers, or by text when exactly one contains it; says why when it cannot
    # (done, del and top on tasks; routine del on routine lines)
    $select = {
        param($verb, $list = $tasks, $listCmd = 't list')
        $list = @($list)
        if (@($rest -notmatch '^\d+$').Count -eq 0) {
            $p = @($rest | ForEach-Object { [int]$_ - 1 } | Sort-Object -Unique)
            if (@($p | Where-Object { $_ -lt 0 -or $_ -ge $list.Count }).Count) { & $say "No such number. See: $listCmd" Yellow; return }
            return , $p
        }
        $text = $rest -join ' '
        $p = @(0..($list.Count - 1) | Where-Object { $list[$_].IndexOf($text, [StringComparison]::OrdinalIgnoreCase) -ge 0 })
        if (-not $p.Count) { & $say "Nothing matches '$text'." Yellow; return }
        if ($p.Count -gt 1) {
            $p | ForEach-Object { & $say "$($_ + 1). $($list[$_])" }
            & $say "Several match. Use: t $verb <number>" DarkGray
            return
        }
        , $p
    }

    switch ($cmd) {
        '' {
            if ($tasks.Count) {
                $parts = $tasks[0] -split ' // ', 2
                & $say "$([char]0x25B6) $($parts[0])" Cyan
                if ($parts.Count -gt 1) { & $say "  $($parts[1])" DarkGray }
            }
            elseif (-not $OneTaskOpening) { & $say 'Nothing to do. Add one: t <task>' DarkGray }
            if ($copies.Count) { & $say 'Your sync app saved a conflict copy. Run: t merge' Yellow }
            return
        }
        'help' {
            @(
                't                        show the current task'
                't <task> [// note]       park a task at the bottom, optionally with a note'
                't add                    type tasks one per line, any characters; empty line ends'
                't now <task>             put a task at the top'
                't done [n ...|text]      log the current task, or the chosen ones, as done'
                't del [n ...|text]       remove the current task, or the chosen ones (logged as dropped)'
                't top <n|text>           make a task the current one'
                't skip                   move the current task to the bottom'
                't note <text>            add a note to the current task'
                't split <a> / <b> ...    replace the current task with its steps'
                't list                   all tasks, numbered'
                't routine <line>         add to the routine: [weekdays|weekends|mon,thu] [HH:MM] task'
                't routine add            type routine lines, any characters; empty line ends'
                't routine [list]         the routine, numbered, with when each runs'
                't routine del <n|text>   remove from the routine'
                't edit [routine]         open todo.txt (or routine.txt) in your editor'
                't merge                  merge conflict copies from your sync app'
                't setup | t uninstall    install or remove'
            ) | ForEach-Object { & $say $_ }
            & $say "Tasks with ' ; # | & or `$ need quotes (t `"don't forget`") or t add." DarkGray
            return
        }
        'done' {
            if (-not $tasks.Count) { return }
            $pick = @(0)
            if ($rest.Count) {
                $pick = & $select 'done'
                if ($null -eq $pick) { return }
                $pick | ForEach-Object { & $say "  $($tasks[$_])" }
                if ((& $ask 'Mark done? [y/N]') -ne 'y') { return }
            }
            $pick | ForEach-Object { [IO.File]::AppendAllText($DONE, "$day $($tasks[$_])`r`n") }
            $tasks = @(for ($i = 0; $i -lt $tasks.Count; $i++) { if ($i -notin $pick) { $tasks[$i] } })
        }
        'del' {
            if (-not $tasks.Count) { return }
            $pick = @(0)
            if ($rest.Count) { $pick = & $select 'del'; if ($null -eq $pick) { return } }
            $pick | ForEach-Object { & $say "  $($tasks[$_])" }
            if ((& $ask 'Delete? [y/N]') -ne 'y') { return }
            $pick | ForEach-Object { [IO.File]::AppendAllText($DONE, "$day dropped: $($tasks[$_])`r`n") }
            $tasks = @(for ($i = 0; $i -lt $tasks.Count; $i++) { if ($i -notin $pick) { $tasks[$i] } })
        }
        'top' {
            if (-not $rest.Count) { & $say 'Usage: t top <number|text>' Yellow; return }
            $pick = & $select 'top'
            if ($null -eq $pick) { return }
            if (@($pick).Count -gt 1) { & $say 'Choose one task.' Yellow; return }
            $tasks = @($tasks[$pick[0]]) + @(for ($i = 0; $i -lt $tasks.Count; $i++) { if ($i -ne $pick[0]) { $tasks[$i] } })
        }
        'skip' {
            if (-not $tasks.Count) { return }
            $tasks = @($tasks | Select-Object -Skip 1) + $tasks[0]
        }
        'now' {
            if (-not $rest.Count) { return }
            $new = $rest -join ' '
            $i = & $findDupe $new
            if ($i -ge 0) { & $say 'Already on your list; moved to the top.' DarkGray; $new = $tasks[$i]; $tasks = @(for ($j = 0; $j -lt $tasks.Count; $j++) { if ($j -ne $i) { $tasks[$j] } }) }
            $tasks = @($new) + $tasks
        }
        'note' {
            if (-not $tasks.Count) { return }
            $text = if ($rest.Count) { $rest -join ' ' } else { & $ask 'Note' }
            if (-not "$text".Trim()) { return }
            $tasks[0] = if ($tasks[0] -match ' // ') { "$($tasks[0]); $text" } else { "$($tasks[0]) // $text" }
        }
        'split' {
            # PowerShell treats ";" as a statement separator, so steps are separated by " / "
            $steps = @(($rest -join ' ') -split '\s+/\s+' | Where-Object { $_.Trim() })
            if (-not $tasks.Count -or $steps.Count -lt 2) { & $say 'Usage: t split <step> / <step> ...' Yellow; return }
            $parts = $tasks[0] -split ' // ', 2   # the note stays with the first step
            $new = @($steps | ForEach-Object { "$($parts[0]): $($_.Trim())" })
            if ($parts.Count -gt 1) { $new[0] += " // $($parts[1])" }
            $tasks = $new + @($tasks | Select-Object -Skip 1)
        }
        'add' {
            # & $ask takes the line as typed, so ' ; # | & and $ need no quoting
            while ($line = "$(& $ask 'Task')".Trim()) {
                $i = & $findDupe $line
                if ($i -ge 0) { & $say "  already on your list (#$($i + 1))." DarkGray; continue }
                $tasks += $line
                [IO.File]::WriteAllLines($TODO, [string[]]$tasks)
                & $say '  parked.' DarkGray
            }
            return
        }
        'list' {
            if (-not $tasks.Count) { & $say 'Nothing to do. Add one: t <task>' DarkGray; return }
            for ($i = 0; $i -lt $tasks.Count; $i++) {
                $parts = $tasks[$i] -split ' // ', 2
                & $say "$($i + 1). $($parts[0])" $(if ($i) { 'Gray' } else { 'Cyan' }) -NoNewline
                & $say $(if ($parts.Count -gt 1) { "  // $($parts[1])" } else { '' }) DarkGray
            }
            if ($copies.Count) { & $say 'Your sync app saved a conflict copy. Run: t merge' Yellow }
            return
        }
        'merge' {
            if (-not $copies.Count) { & $say 'No conflict copies.' DarkGray; return }
            $doneLines = @(if (Test-Path $DONE) { [IO.File]::ReadAllLines($DONE) })
            $newTasks = @(); $newDone = @(); $drop = @()
            foreach ($c in $copies) {
                $lines = @([IO.File]::ReadAllLines($c.FullName) | Where-Object { $_.Trim() })
                switch -Regex ($c.Name) {
                    '^todo' {
                        # Skip tasks finished (or missed) since a week before the copy was written, so they are not
                        # brought back, and routine tasks, which the routine adds itself
                        $since = $c.LastWriteTime.AddDays(-7).ToString('yyyy-MM-dd')
                        $gone = @($doneLines | Where-Object { $_.Length -gt 11 -and $_.Substring(0, 10) -ge $since } | ForEach-Object { $_.Substring(11) -replace '^missed: ', '' })
                        $newTasks += @($lines | Where-Object { $tasks -notcontains $_ -and $gone -notcontains $_ -and @($items).Text -notcontains $_ })
                        $drop += $c
                    }
                    '^done' { $newDone += @($lines | Where-Object { $doneLines -notcontains $_ }); $drop += $c }
                    '\.last$' { $drop += $c }   # the tool's own state; the main routine.last wins
                    default { & $say "$($c.Name): compare it with routine.txt (t routine), then delete it." Yellow }
                }
            }
            if (-not $drop.Count) { return }
            $newTasks = @($newTasks | Select-Object -Unique)
            $newDone  = @($newDone | Select-Object -Unique)
            if ($newTasks.Count) { & $say 'Add to the bottom of todo.txt:'; $newTasks | ForEach-Object { & $say "  $_" } }
            if ($newDone.Count) { & $say "Add $($newDone.Count) line(s) to done.txt" }
            & $say "Then delete: $(($drop | ForEach-Object { $_.Name }) -join ', ')"
            if ((& $ask 'Merge? [y/N]') -ne 'y') { return }
            if ($newDone.Count) { [IO.File]::AppendAllText($DONE, ($newDone -join "`r`n") + "`r`n") }
            $drop | Remove-Item
            $tasks += $newTasks
        }
        { $_ -in 'edit', 'edit routine' } {
            # A terminal editor first: $VISUAL/$EDITOR, then nvim, vim, nano, Microsoft Edit; Notepad as the fallback
            $file = if ($cmd -eq 'edit') { $TODO } else { $ROUTINE }
            $ed = @($env:VISUAL, $env:EDITOR | Where-Object { $_ })
            if ($ed.Count) { & $env:ComSpec /c "$($ed[0]) `"$file`"" }   # cmd parses an editor command with its own arguments
            elseif ($c = Get-Command nvim, vim, nano, edit -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1) { & $c.Source $file }
            else { notepad $file; return }
            t   # show the task again, and re-arm reminders if the routine changed
            return
        }
        'routine list' {
            if (-not $items.Count) { & $say 'No routine yet. Add one: t routine <task>' DarkGray; return }
            for ($i = 0; $i -lt $items.Count; $i++) {
                & $say "$($i + 1). $($items[$i].Text)" -NoNewline
                & $say "  $(& $whenOf $items[$i])" DarkGray
            }
            return
        }
        'routine add' {
            # One line from the command line, or several typed at a prompt (any characters) until an empty line
            $new = @(if ($rest.Count) { $rest -join ' ' } else { while ($line = "$(& $ask 'Routine')".Trim()) { $line } })
            $lines = @(if (Test-Path $ROUTINE) { [IO.File]::ReadAllLines($ROUTINE) })
            $count = $lines.Count
            foreach ($l in $new) {
                $r = & $parseLine $l 0
                if (-not $r) { continue }
                if (@($items).Text -contains $r.Text) { & $say "  already in your routine: $($r.Text)" DarkGray; continue }
                $lines += ("$l".Trim() -replace '(?<=\b(sun|mon|tue|wed|thu|fri|sat))\s*,\s*(?=(sun|mon|tue|wed|thu|fri|sat)\b)', ',')
                $items += $r
                & $say "  added to your routine: $($r.Text) ($(& $whenOf $r))" DarkGray
            }
            if ($lines.Count -gt $count) { [IO.File]::WriteAllLines($ROUTINE, [string[]]$lines) }
            return
        }
        'routine del' {
            if (-not $rest.Count) { & $say 'Usage: t routine del <number|text>  (numbers from t routine list)' Yellow; return }
            if (-not $items.Count) { & $say 'Your routine is empty.' DarkGray; return }
            $pick = & $select 'routine del' (@($items).Text) 't routine list'
            if ($null -eq $pick) { return }
            $pick | ForEach-Object { & $say "  $($items[$_].Text)  $(& $whenOf $items[$_])" }
            if ((& $ask 'Remove from your routine? [y/N]') -ne 'y') { return }
            $gone = @($pick | ForEach-Object { $items[$_].Line })
            $n = 0
            $lines = @(foreach ($l in [IO.File]::ReadAllLines($ROUTINE)) { $n++; if ($n -notin $gone) { $l } })
            [IO.File]::WriteAllLines($ROUTINE, [string[]]$lines)
            & $say "  removed $($gone.Count) from your routine." DarkGray
            return
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
            # -Folder or -Root (from the command line, or from the profile line when run as t setup) wins;
            # otherwise pick one of the synced folders found on this PC, or any other folder
            $target = if ($Folder) { $Folder } elseif ($Root) { Join-Path $Root 'Apps\one-task' } else { '' }
            if (-not $target) {
                $found = [ordered]@{}
                $add = { param($name, $path) if ($path -and -not $found.Contains($name) -and @($found.Values) -notcontains $path -and (Test-Path $path)) { $found[$name] = $path } }
                & $add 'OneDrive (personal)' $env:OneDriveConsumer
                & $add 'OneDrive (work)' $env:OneDriveCommercial
                & $add 'OneDrive' $env:OneDrive
                foreach ($d in Get-PSDrive -PSProvider FileSystem) { & $add "Google Drive ($($d.Name):)" (Join-Path $d.Root 'My Drive') }
                & $add 'Google Drive' (Join-Path $env:USERPROFILE 'My Drive')
                & $add 'Google Drive (old app)' (Join-Path $env:USERPROFILE 'Google Drive')
                foreach ($j in "$env:LOCALAPPDATA\Dropbox\info.json", "$env:APPDATA\Dropbox\info.json") {
                    try { $info = Get-Content $j -Raw -ErrorAction Stop | ConvertFrom-Json; & $add 'Dropbox' $info.personal.path; & $add 'Dropbox (business)' $info.business.path } catch { }
                }
                & $add 'Dropbox' (Join-Path $env:USERPROFILE 'Dropbox')
                & $add 'iCloud Drive' (Join-Path $env:USERPROFILE 'iCloudDrive')

                $keys = @($found.Keys)
                for ($i = 0; $i -lt $keys.Count; $i++) { & $say "$($i + 1). $($keys[$i])  $($found[$keys[$i]])" }
                & $say "$($keys.Count + 1). Other folder"
                $n = & $ask 'Where should your tasks live? [1]'
                if (-not $n) { $n = '1' }
                if ($n -match '^\d+$' -and [int]$n -ge 1 -and [int]$n -le $keys.Count) { $target = Join-Path $found[$keys[[int]$n - 1]] 'Apps\one-task' }
                elseif ($n -eq "$($keys.Count + 1)") { $target = "$(& $ask 'Folder for your tasks (used as is)')".Trim().Trim('"') }
                if (-not $target) { & $say 'No folder chosen; setup stopped.' Yellow; return }
            }
            New-Item $target -ItemType Directory -Force | Out-Null
            $target = (Resolve-Path $target).Path
            $dir = $target

            # Offer to bring the tasks over from the folder the old profile line used
            $prev = @(Get-Content $profs -ErrorAction SilentlyContinue | Where-Object { $_.EndsWith($OneTaskMarker) })
            if ($prev.Count -and $prev[0] -match "-(Folder|Root) '((?:[^']|'')*)'") {
                $from = $Matches[2].Replace("''", "'")
                if ($Matches[1] -eq 'Root') { $from = Join-Path $from 'Apps\one-task' }
                if ($from -ne $target -and (Test-Path (Join-Path $from 'todo.txt')) -and -not (Test-Path (Join-Path $target 'todo.txt')) -and
                    (& $ask "Move your tasks from $from? [y/N]") -eq 'y') { Get-ChildItem $from -File | Move-Item -Destination $target }
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

            # Documents, and so the profiles, may sync between PCs, so the line is skipped where the script path does not exist
            $s = $OneTaskScript.Replace("'", "''")
            $line = "if (Test-Path '$s') { . '$s' -Folder '$($target.Replace("'", "''"))' }  $OneTaskMarker"
            $hasPwsh = [bool](Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue)
            foreach ($p in $profs) {
                if ($p -eq $profs[1] -and -not $hasPwsh -and -not (Test-Path (Split-Path $p))) { continue }
                $lines = @(if (Test-Path $p) { [IO.File]::ReadAllLines($p) | Where-Object { -not $_.EndsWith($OneTaskMarker) } })
                New-Item (Split-Path $p) -ItemType Directory -Force | Out-Null
                [IO.File]::WriteAllLines($p, [string[]]($lines + $line), (New-Object Text.UTF8Encoding $true))
                & $say "Profile: $p"
            }
            Get-ChildItem ($profs | Split-Path) -Filter '*profile.ps1' -ErrorAction SilentlyContinue |
                Select-String -Pattern '[\\/"'' ]t\.ps1' | Where-Object { -not $_.Line.EndsWith($OneTaskMarker) } |
                ForEach-Object { & $say "Old t line, remove it: $($_.Path):$($_.LineNumber)" Yellow }

            # The profile only runs if the execution policy allows local scripts
            $gpo  = @('MachinePolicy', 'UserPolicy' | ForEach-Object { "$(Get-ExecutionPolicy -Scope $_)" } | Where-Object { $_ -ne 'Undefined' })
            $user = "$(Get-ExecutionPolicy -Scope CurrentUser)"
            $eff  = if ($gpo.Count) { $gpo[0] } elseif ($user -ne 'Undefined') { $user } else { "$(Get-ExecutionPolicy -Scope LocalMachine)" }
            if ($eff -eq 'Undefined') { $eff = if ($PSVersionTable.PSEdition -eq 'Core') { 'RemoteSigned' } else { 'Restricted' } }
            if ($eff -in 'Restricted', 'AllSigned') {
                if ($gpo.Count) { & $say "Group Policy sets the execution policy to $eff, so the profile cannot load t." Yellow }
                else {
                    Set-ItemProperty $key PrevPolicy $user
                    Set-ItemProperty $key Edition $PSVersionTable.PSEdition
                    # Errors when the Process scope overrides it (as with -ExecutionPolicy Bypass); checked below instead
                    try { Set-ExecutionPolicy RemoteSigned -Scope CurrentUser -Force -ErrorAction Stop } catch { }
                    if ("$(Get-ExecutionPolicy -Scope CurrentUser)" -eq 'RemoteSigned') { & $say "Execution policy (CurrentUser): $user -> RemoteSigned" }
                    else { & $say 'Could not set the execution policy to RemoteSigned.' Yellow }
                }
            }
            & $say "Tasks: $dir. Open a new terminal to see your task." DarkGray
            return
        }
        'uninstall' {
            foreach ($p in $profs) {
                if (-not (Test-Path $p)) { continue }
                $lines = @([IO.File]::ReadAllLines($p) | Where-Object { -not $_.EndsWith($OneTaskMarker) })
                if (@($lines | Where-Object { $_.Trim() }).Count) { [IO.File]::WriteAllLines($p, [string[]]$lines, (New-Object Text.UTF8Encoding $true)) }
                else { Remove-Item $p }
                & $say "Profile cleaned: $p"
            }
            if (Get-ScheduledTask OneTask -ErrorAction SilentlyContinue) { Unregister-ScheduledTask OneTask -Confirm:$false; & $say 'Reminder task removed' }
            if (Test-Path $key) {
                $k = Get-ItemProperty $key
                if ($k.PrevPolicy -and $k.Edition -ne $PSVersionTable.PSEdition) { & $say "Run uninstall from the shell that ran setup ($($k.Edition) edition) to restore the execution policy." Yellow; return }
                # Only restore if nobody changed it since setup
                if ($k.PrevPolicy -and "$(Get-ExecutionPolicy -Scope CurrentUser)" -eq 'RemoteSigned') {
                    try { Set-ExecutionPolicy $k.PrevPolicy -Scope CurrentUser -Force -ErrorAction Stop } catch { }
                    & $say "Execution policy (CurrentUser) restored to $($k.PrevPolicy)"
                }
                Remove-Item $key -Recurse
            }
            if ($dir) { & $say "Your tasks were kept in $dir" DarkGray }
            return
        }
        default {
            $i = & $findDupe ($a -join ' ')
            if ($i -ge 0) { & $say "already on your list (#$($i + 1))." DarkGray; return }
            $tasks += ($a -join ' ')
            [IO.File]::WriteAllLines($TODO, [string[]]$tasks)
            & $say 'parked.' DarkGray
            return
        }
    }
    [IO.File]::WriteAllLines($TODO, [string[]]$tasks)
    t
}

# Bare t shows the one task whenever a terminal opens; an empty list stays silent there
if ($Command) { t @Command } else { $OneTaskOpening = $true; t; $OneTaskOpening = $false }
