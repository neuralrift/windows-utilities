# t - one task at a time. Works in Windows PowerShell 5.1 and PowerShell 7.
# Usage: t | t <task> [// note] | t <Parent>: [<task>] | t "<text as typed>"
#        t list | t find <text> | t done [sel] | t del [sel] | t skip [sel] | t now <task|sel>   (sel: numbers or Parent:)
#        | t log [name] | t undo | t merge | t help
#        t edit | t edit [n] // <note> | t edit <n> <new text>
#        t routine [list] | t routine <line> | t routine add | t routine edit | t routine del <n|text>
#        t setup | t uninstall   (t --remind is run by the scheduled task)
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
    # One argument containing a space was quoted: it is task text as typed, whatever it starts with
    $literal = $args.Count -eq 1 -and $args[0] -is [string] -and $args[0].Contains(' ')
    # PowerShell turns "milk, eggs" or "mon,thu" into an array argument; put the commas back
    $a = @($args | ForEach-Object { if ($_ -is [array]) { $_ -join ', ' } else { [string]$_ } })
    # The first word is a verb (or its one-letter form) or the start of a task. A verb never parks.
    $short = @{ l = 'list'; f = 'find'; d = 'done'; s = 'skip'; n = 'now'; x = 'del'; e = 'edit'; u = 'undo'; r = 'routine'; g = 'log'; h = 'help'; '-h' = 'help'; '--help' = 'help'; '?' = 'help' }
    $words = 'list', 'find', 'done', 'skip', 'now', 'del', 'edit', 'undo', 'routine', 'log', 'help', 'merge', 'setup', 'uninstall', 'remind', '--remind'
    $cmd = ''; $rest = @()
    if ($a.Count) {
        $w = if ($short.ContainsKey($a[0])) { $short[$a[0]] } else { $a[0].ToLower() }
        if (-not $literal -and $w -in $words) { $cmd = $w; $rest = @($a | Select-Object -Skip 1) } else { $cmd = 'park'; $rest = $a }
    }
    # t routine [list|add|edit|del]: list, add and edit only count when alone, so
    # "t routine add tests" is the routine line "add tests"; anything else after "routine" is a line to add
    if ($cmd -eq 'routine') {
        $sub = if ($rest.Count) { $rest[0] } else { 'list' }
        if ($sub -eq 'del' -or ($sub -in 'list', 'add', 'edit' -and $rest.Count -le 1)) { $rest = @($rest | Select-Object -Skip 1) } else { $sub = 'add' }
        $cmd = "routine $sub"
    }

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
    # A task line is "title // note"; the note is optional. Duplicates are judged on the title alone.
    $titleOf = { param($s) ($s -split ' // ', 2)[0].Trim() }
    # The parent of a task line ("Report: Draft // note" -> "Report"), or nothing. Judged on the title only.
    $parentOf = { param($s) if ((& $titleOf $s) -match '^(?<p>[^:]+): .') { $Matches.p.Trim() } }
    # todo.txt holds a parent as a header line ("Report:") with its tasks indented under it. In memory the
    # list is flat, each child as "Report: Draft", so everything else works on plain lines.
    # File lines -> flat tasks. A child is indented (spaces, a tab) or starts with "- ".
    $fromFile = {
        param($lines)
        $head = $null
        foreach ($raw in $lines) {
            $text = ("$raw" -replace '\s+', ' ').Trim()
            if (-not $text) { continue }
            $kid = "$raw" -match '^(\s+|-\s+)'
            if ($kid -and $head) { "${head}: $($text -replace '^- ', '')" }
            elseif (-not $kid -and $text -match '^(?<h>[^:]+):$') { $head = $Matches.h.Trim() }
            else { if (-not $kid) { $head = $null }; $text }
        }
    }
    # Flat tasks -> file lines: one header for each run of tasks with the same parent
    $toFile = {
        param($flat)
        $cur = $null
        foreach ($l in $flat) {
            $p = & $parentOf $l
            if ($p) { if ($p -ne $cur) { $cur = $p; "${p}:" }; "  $($l.Substring($l.IndexOf(': ') + 2))" }
            else { $cur = $null; if ($l.EndsWith(':')) { $l.TrimEnd(':') } else { $l } }   # a bare "x:" would read back as an empty header
        }
    }
    # The tasks of one parent sit together, at the place of the first; the first spelling of its name wins
    $group = {
        param($flat)
        $order = @(); $kids = @{}; $name = @{}
        foreach ($l in $flat) {
            $p = & $parentOf $l
            if (-not $p) { $order += $l; continue }
            if (-not $kids.ContainsKey($p)) { $kids[$p] = @(); $name[$p] = $p; $order += "`t$p" }
            $kids[$p] = @($kids[$p]) + "$($name[$p]): $($l.Substring($l.IndexOf(': ') + 2))"
        }
        foreach ($o in $order) { if ($o.StartsWith("`t")) { $kids[$o.Substring(1)] } else { $o } }
    }
    # "parent: a / b // note" -> "parent: a // note", "parent: b"; anything without both "parent: " and " / " -> itself.
    # Call it as @(& $expand $text).
    $expand = {
        param($s)
        $p = "$s" -split ' // ', 2
        if ($p[0] -notmatch '^(?<parent>[^:/]+): (?<steps>.+\s/\s.+)$') { return "$s" }
        $parent = $Matches.parent.Trim()
        $out = @($Matches.steps -split '\s+/\s+' | Where-Object { $_.Trim() } | ForEach-Object { "${parent}: $($_.Trim())" })
        if ($p.Count -gt 1) { $out[0] += " // $($p[1])" }
        $out
    }
    # A task belongs to a routine entry when its title is the entry, or a step of it ("entry: step")
    $isOf = { param($line, $names) $x = & $titleOf $line; foreach ($n in $names) { if ($x -eq $n -or $x.StartsWith("${n}: ", [StringComparison]::OrdinalIgnoreCase)) { return $true } }; $false }
    $say = { param($text, $color, [switch]$NoNewline) if ($color -and -not $env:NO_COLOR) { Write-Host $text -ForegroundColor $color -NoNewline:$NoNewline } else { Write-Host $text -NoNewline:$NoNewline } }

    if ($rest.Count -and $cmd -in 'list', 'undo', 'help', 'merge', 'setup', 'uninstall', '--remind') {
        & $say "t $cmd takes nothing after it. To park that text, quote it: t `"$($a -join ' ')`"" Yellow; return
    }
    if ($cmd -eq 'remind') { & $say "t $cmd is not ready yet." Yellow; return }
    if ($cmd -notin 'setup', 'uninstall') {
        if (-not $dir) { & $say 'No task folder set. Run: t setup' Yellow; return }
        if (-not (Test-Path $TODO)) { New-Item $dir -ItemType Directory -Force | Out-Null; New-Item $TODO -ItemType File | Out-Null }
        $UNDO = Join-Path $dir 'todo.undo'
        $agePath  = Join-Path $dir 'todo.age'
        # Dot-run (. $read): sets $tasks, $before and $seen in this scope
        $read = {
            # Lines are tidied as they are read (extra spaces, blank lines); the file is rewritten on the next change
            $tasks  = @(& $group @(& $fromFile ([IO.File]::ReadAllLines($TODO))))
            $before = $tasks.Clone()
            $seen   = "$((Get-Item $TODO).LastWriteTimeUtc.Ticks)"
        }
        # Write to a temp file and swap it in, so a crash or a sync mid-write cannot truncate the file
        $save = {
            param($path, $lines)
            $tmp = "$path.tmp"
            [IO.File]::WriteAllLines($tmp, [string[]]$lines)
            try { if (Test-Path $path) { [IO.File]::Replace($tmp, $path, [NullString]::Value) } else { [IO.File]::Move($tmp, $path) } }
            catch { [IO.File]::WriteAllLines($path, [string[]]$lines); Remove-Item $tmp -ErrorAction SilentlyContinue }
        }
        . $read

        # Routine: on a new day, log yesterday's unfinished routine tasks as missed and add today's;
        # timed ones are added at the top on the first t at or after their time.
        # routine.last holds the date of the last routine day, then the tasks added on it.
        $ROUTINE = Join-Path $dir 'routine.txt'
        $LAST    = Join-Path $dir 'routine.last'   # PowerShell names are case-insensitive: no other $last/$state below
        $due     = @(); $dueShown = @()
        $d3   = 'sun', 'mon', 'tue', 'wed', 'thu', 'fri', 'sat'
        $full = 'sunday', 'monday', 'tuesday', 'tues', 'wednesday', 'weds', 'thursday', 'thur', 'thurs', 'friday', 'saturday'
        # Day number for "mon", "Monday", "tues"; -1 for anything else
        $dayOf = { param($s) $s = "$s".ToLower(); if ($s.Length -eq 3 -or $full -contains $s) { [array]::IndexOf($d3, $s.Substring(0, 3)) } else { -1 } }
        # "mon, thu 9:00 x" -> "mon,thu 9:00 x": PowerShell splits a comma list typed on the command line
        $glue = { param($l) [regex]::Replace("$l".Trim(), '(?i)^((sun|mon|tue|wed|thu|fri|sat)[a-z]*\s*,\s*)+', { param($m) $m.Value -replace '\s', '' }) }
        # Reads one routine line, "[days] [time] [quiet] task"; returns nothing for blank lines and # comments.
        # Days: daily, everyday, weekdays, weekends, mon,thu, monday, mon-fri. Time: 14:00, 14.00, 2pm, 2:30pm.
        # It runs on every t, so it stays cheap; mistyped days and times are spotted by $warnOf, on demand.
        $parseLine = {
            param($l, $n)
            $l = "$l".Trim()
            if (-not $l -or $l.StartsWith('#')) { return }
            $l = & $glue $l
            $w = @($l -split '\s+')
            $days = 0..6; $at = $null; $quiet = $false; $set = $null
            if ($w.Count -gt 1) {
                $f = $w[0].ToLower()
                if ($f -in 'daily', 'everyday') { $set = 0..6 }
                elseif ($f -in 'weekday', 'weekdays') { $set = 1..5 }
                elseif ($f -in 'weekend', 'weekends') { $set = 0, 6 }
                else {
                    $all = @(foreach ($part in $f -split ',') {
                        $ends = @($part -split '-' | ForEach-Object { & $dayOf $_ })
                        if ($ends -contains -1 -or $ends.Count -gt 2) { -1 }
                        elseif ($ends.Count -eq 2) { $i = $ends[0]; while ($true) { $i; if ($i -eq $ends[1]) { break }; $i = ($i + 1) % 7 } }
                        else { $ends[0] }
                    })
                    if ($all -notcontains -1) { $set = $all }
                }
                if ($null -ne $set) { $days = @($set | Sort-Object -Unique); $w = @($w | Select-Object -Skip 1) }
            }
            if ($w.Count -gt 1 -and $w[0] -match '^(?<h>\d{1,2})(?:[:.](?<m>\d{2}))?(?<ap>am|pm)?$' -and ($Matches.m -or $Matches.ap)) {
                $h = [int]$Matches.h; $m = [int]$Matches.m; $ap = $Matches.ap
                $ok = $m -le 59 -and $(if ($ap) { $h -ge 1 -and $h -le 12 } else { $h -le 23 })
                if ($ok) {
                    if ($ap) { $h = $h % 12; if ($ap -eq 'pm') { $h += 12 } }
                    $at = New-TimeSpan -Hours $h -Minutes $m
                    $w = @($w | Select-Object -Skip 1)
                }
            }
            # "quiet" after a time: the task still moves to the top then, without a notification
            if ($at -and $w.Count -gt 1 -and $w[0] -eq 'quiet') { $quiet = $true; $w = @($w | Select-Object -Skip 1) }
            # Names are the task lines the entry puts on the list (several when it has steps), Titles the same
            # without notes, Key the name it is known by (the parent when it has steps)
            $text  = $w -join ' '
            $steps = @(& $expand $text)
            $key   = if ($steps.Count -gt 1) { ($steps[0] -split ': ', 2)[0] } else { & $titleOf $text }
            [pscustomobject]@{ Days = @($days); Prefixed = $null -ne $set; At = $at; Quiet = $quiet; Text = $text; Names = $steps; Titles = @($steps | ForEach-Object { & $titleOf $_ }); Key = $key; Line = $n }
        }
        # Routine lines as written to routine.txt: comments kept, spaces tidied
        $tidy = { param($l) if ("$l".TrimStart().StartsWith('#')) { "$l".TrimEnd() } else { ("$l" -replace '\s+', ' ').Trim() } }
        $items = @()
        if (Test-Path $ROUTINE) {
            $n = 0
            $items = @(foreach ($l in [IO.File]::ReadAllLines($ROUTINE)) { $n++; & $parseLine $l $n })
            # @() around if: an if expression unrolls a one-element array into a bare string
            $memo  = @(if (Test-Path $LAST) { [IO.File]::ReadAllLines($LAST) })
            $prevDay = if ($memo.Count) { $memo[0] } else { '' }
            $added = @($memo | Select-Object -Skip 1)
            $log   = @()
            $onList = { param($title) [bool]@($tasks | Where-Object { & $isOf $_ @($title) }).Count }
            $newDay = $prevDay -lt $day
            if ($newDay) {
                if ($prevDay) {
                    $prev = [datetime]::ParseExact($prevDay, 'yyyy-MM-dd', $null)
                    foreach ($x in $added) { if (& $onList $x) { $log += "$prevDay missed: $x" } }
                    $tasks = @($tasks | Where-Object { -not (& $isOf $_ $added) })
                    foreach ($r in $items) { if ($r.At -and $r.Days -contains [int]$prev.DayOfWeek) { foreach ($x in $r.Titles) { if ($added -notcontains $x) { $log += "$prevDay missed: $x" } } } }
                    # Days without any t run (PC off), at most the last 31
                    $from = $prev.AddDays(1)
                    if ($from -lt $now.Date.AddDays(-31)) { $from = $now.Date.AddDays(-31) }
                    for ($x = $from; $x -lt $now.Date; $x = $x.AddDays(1)) {
                        foreach ($r in $items) { if ($r.Days -contains [int]$x.DayOfWeek) { foreach ($y in $r.Titles) { $log += "$($x.ToString('yyyy-MM-dd')) missed: $y" } } }
                    }
                }
                $new = @(foreach ($r in $items) { if (-not $r.At -and $r.Days -contains [int]$now.DayOfWeek) { foreach ($x in $r.Names) { if (-not (& $onList (& $titleOf $x))) { $x } } } })
                $added = @($new | ForEach-Object { & $titleOf $_ })
                $tasks = $new + $tasks
            }
            # Timed entries that are due and not yet added today; $dueShown names them for the reminder
            $due = @(foreach ($r in @($items | Where-Object { $_.At } | Sort-Object At, Line)) {
                if ($r.At -le $now.TimeOfDay -and $r.Days -contains [int]$now.DayOfWeek) {
                    $new = @($r.Names | Where-Object { $x = & $titleOf $_; $added -notcontains $x -and -not (& $onList $x) })
                    if ($new.Count) { if (-not $r.Quiet) { $dueShown += $r.Key }; $new }
                }
            })
            if ($newDay -or $due.Count) {
                $tasks = @(& $group ($due + $tasks))
                $added += @($due | ForEach-Object { & $titleOf $_ })
                if ($log.Count) { [IO.File]::AppendAllText($DONE, ($log -join "`r`n") + "`r`n") }
                & $save $TODO @(& $toFile $tasks)
                & $save $LAST (@($day) + $added)
            }

            # Reminders: one scheduled task, re-armed for the next timed routine task after every
            # reminder run and whenever routine.txt changes. Setup creates $key; without it nothing is armed.
            $stamp = "$((Get-Item $ROUTINE).LastWriteTimeUtc.Ticks)"
            if (-not $OneTaskNoArm -and (Test-Path $key) -and ($cmd -eq '--remind' -or (Get-ItemProperty $key).Stamp -ne $stamp)) {
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
                    -Action (New-ScheduledTaskAction -Execute conhost.exe -Argument "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$OneTaskScript`" -Folder `"$OneTaskDir`" --remind") `
                    -Trigger $trig `
                    -Settings (New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries) `
                    -Principal (New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited) | Out-Null
                Set-ItemProperty $key Stamp $stamp
            }
        }

        $before = $tasks.Clone()
        $seen   = "$((Get-Item $TODO).LastWriteTimeUtc.Ticks)"

        # Sync apps save conflicting edits as copies: todo-<PC>.txt (OneDrive), todo (<PC>'s conflicted copy ...).txt
        # (Dropbox), todo (1).txt or todo_conf(1).txt (Google Drive), todo 2.txt (iCloud). t and t list mention them, t merge merges them
        $copies = @(if ($cmd -in '', 'list', 'merge') { Get-ChildItem $dir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^(todo|done|routine)[-_ (].*\.(txt|last|undo|age)$' } })
    }

    $findDupe = { param($s) $k = & $titleOf $s; for ($i = 0; $i -lt $tasks.Count; $i++) { if ((& $titleOf $tasks[$i]) -eq $k) { return $i } }; -1 }
    # Describes when a routine entry runs, e.g. "weekdays at 14:00" or "every day, in the morning"
    $whenOf = {
        param($r)
        $day3 = 'sun', 'mon', 'tue', 'wed', 'thu', 'fri', 'sat'
        $w = switch ("$($r.Days | Sort-Object)") { '0 1 2 3 4 5 6' { 'every day' } '1 2 3 4 5' { 'weekdays' } '0 6' { 'weekends' } default { ($r.Days | Sort-Object | ForEach-Object { $day3[$_] }) -join ',' } }
        $w + $(if ($r.At) { " at $($r.At.ToString('hh\:mm'))" } else { ', in the morning' }) + $(if ($r.Quiet) { ', quiet' } else { '' })
    }
    # Says why a routine entry looks like a mistyped day or time, or nothing. Only for routine add and list.
    $lev = { param($a, $b) $p = 0..$b.Length; for ($i = 1; $i -le $a.Length; $i++) { $c = @($i) + @(1..$b.Length | ForEach-Object { 0 }); for ($j = 1; $j -le $b.Length; $j++) { $c[$j] = [Math]::Min([Math]::Min($p[$j] + 1, $c[$j - 1] + 1), $p[$j - 1] + [int]($a[$i - 1] -ne $b[$j - 1])) }; $p = $c }; $p[$b.Length] }
    $warnOf = {
        param($r)
        $words = @($r.Text -split '\s+')
        if ($words.Count -lt 2) { return }
        $f = $words[0].ToLower()
        if (-not $r.Prefixed -and -not $r.At) {
            if ($f -match '[,-]' -and @($f -split '[,-]' | Where-Object { (& $dayOf $_) -ge 0 }).Count) { return "'$f' looks like a list of days; use forms such as mon,thu or mon-fri" }
            foreach ($k in 'weekdays', 'weekends', 'everyday', 'sunday', 'monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday') { if ((& $lev $f $k) -eq 1) { return "'$f' looks like '$k'" } }
        }
        if (-not $r.At -and $f -match '^\d{1,2}([:.h]\d{2})?(a|p|am|pm)?$' -and $f -match '[:.hap]') { return "'$f' looks like a time; use forms such as 14:00 or 2pm" }
    }
    # One selection rule for done, del, skip and now (and routine del, on routine lines): nothing is the
    # current task, numbers ("1 3 5" or "1,3,5") are those tasks, "Parent:" is every task of that parent.
    # Returns indexes into $list; for anything else it says what is expected and returns nothing.
    $select = {
        param($verb, $list = $tasks, $listCmd = 't list')
        $list = @($list)
        if (-not $rest.Count) { return , @(0) }
        $nums = @($rest | ForEach-Object { "$_" -split '[,\s]+' } | Where-Object { $_ })
        if (@($nums -notmatch '^\d+$').Count -eq 0) {
            $p = @($nums | ForEach-Object { [int]$_ - 1 } | Sort-Object -Unique)
            if (@($p | Where-Object { $_ -lt 0 -or $_ -ge $list.Count }).Count) { & $say "No such number. See: $listCmd" Yellow; return }
            return , $p
        }
        $text = $rest -join ' '
        if ($text -match '^(?<p>[^:]+):$') {
            $name = $Matches.p.Trim()
            $p = @(for ($i = 0; $i -lt $list.Count; $i++) { if ((& $parentOf $list[$i]) -eq $name) { $i } })
            if ($p.Count) { return , $p }
            & $say "No parent '$name'. See: $listCmd" Yellow; return
        }
        & $say "t $verb takes numbers or a Parent: (find them with: t find <text>)" Yellow
    }
    # todo.undo holds what t undo needs for the last change: line 1 what it covers (todo, routine or both),
    # line 2 the length done.txt had, line 3 the write times of the covered files after the change, line 4 the
    # command, line 5 how many todo lines follow (flat tasks); the lines after those are routine.txt as it was.
    $ticksOf = {
        param($target)
        @(if ($target -ne 'routine') { "$((Get-Item $TODO).LastWriteTimeUtc.Ticks)" }
          if ($target -ne 'todo') { if (Test-Path $ROUTINE) { "$((Get-Item $ROUTINE).LastWriteTimeUtc.Ticks)" } else { '0' } }) -join ' '
    }
    $stash = {
        param($target, $len, $what, $oldTodo, $oldRoutine)
        [IO.File]::WriteAllLines($UNDO, [string[]](@($target, "$len", (& $ticksOf $target), $what, "$(@($oldTodo).Count)") + @($oldTodo) + @($oldRoutine)))
    }
    # What an edited todo.txt holds that cannot be kept as written; said once, after the editor closes
    $lint = {
        param($lines)
        $head = $null; $kids = 0; $n = 0
        foreach ($raw in $lines) {
            $n++
            $text = ("$raw" -replace '\s+', ' ').Trim()
            if (-not $text) { continue }
            $kid = "$raw" -match '^(\s+|-\s+)'
            if ($kid -and $head) { $kids++; continue }
            if ($kid) { "line $n was indented under no parent; kept as a task"; continue }
            if ($head -and -not $kids) { "${head}: had no tasks; removed" }
            if ($text -match '^(?<h>[^:]+):$') { $head = $Matches.h.Trim(); $kids = 0 } else { $head = $null }
        }
        if ($head -and -not $kids) { "${head}: had no tasks; removed" }
    }
    # Every change to todo.txt goes through here: refuse if the file changed since it was read (a sync or a
    # reminder), append to done.txt, write safely, and keep the previous state for t undo. Returns $true if written.
    $commit = {
        param($what, $logLines = @())
        if ("$((Get-Item $TODO).LastWriteTimeUtc.Ticks)" -ne $seen) { & $say 'todo.txt changed meanwhile (a sync or a reminder); nothing was changed. Run it again.' Yellow; return $false }
        $len = if (Test-Path $DONE) { (Get-Item $DONE).Length } else { 0 }
        if (@($logLines).Count) { [IO.File]::AppendAllText($DONE, (@($logLines) -join "`r`n") + "`r`n") }
        $tasks = @(& $group $tasks)
        & $save $TODO @(& $toFile $tasks)
        & $stash 'todo' $len $what $before @()
        # Ages: new titles start today; titles gone from the list are dropped, but only once t undo can no longer bring them back
        $ages = & $readAge
        $titles = @($tasks | ForEach-Object { & $titleOf $_ })
        $keep = $titles + @($before | ForEach-Object { & $titleOf $_ })
        if ($renamed -and $ages.ContainsKey($renamed[0])) { $ages[$renamed[1]] = @{ Day = $ages[$renamed[0]].Day; Skips = 0 } }
        foreach ($x in $titles) { if (-not $ages.ContainsKey($x)) { $ages[$x] = @{ Day = $day; Skips = 0 } } }
        foreach ($x in @($ages.Keys)) { if ($x -ne "`t" -and $keep -notcontains $x) { $ages.Remove($x) } }
        foreach ($x in @($bump)) { if ($x -and $ages.ContainsKey($x)) { $ages[$x].Skips++ } }
        & $writeAge $ages
        $true
    }
    # todo.age is the tool's own record of when each task was first seen and how often it was skipped:
    # line 1 "hint <day>" (the last day a waiting hint was shown), then "<day><TAB><skips><TAB><title>".
    # The table is title -> @{ Day; Skips }; the hint day sits under the key TAB, which cannot be a title.
    $readAge = {
        $h = @{}
        foreach ($l in @(if (Test-Path $agePath) { [IO.File]::ReadAllLines($agePath) })) {
            $p = $l -split "`t", 3
            if ($p.Count -eq 3) { $h[$p[2]] = @{ Day = $p[0]; Skips = [int]$p[1] } } elseif ($l -like 'hint *') { $h["`t"] = $l.Substring(5) }
        }
        $h
    }
    $writeAge = { param($h) & $save $agePath (@("hint $($h["`t"])") + @($h.Keys | Where-Object { $_ -ne "`t" } | Sort-Object | ForEach-Object { "$($h[$_].Day)`t$($h[$_].Skips)`t$_" })) }
    # "3w" or "5d" for a first-seen day; nothing for under three days
    $ageOf = { param($d) $n = ($now.Date - [datetime]::ParseExact($d, 'yyyy-MM-dd', $null)).Days; if ($n -ge 14) { "$([int][Math]::Floor($n / 7))w" } elseif ($n -ge 3) { "${n}d" } }

    # Prints the tasks at the given indexes as t list does: numbered, the tasks of a parent under its header
    $show = {
        param($idx)
        $first = @{}
        for ($i = 0; $i -lt $tasks.Count; $i++) { $x = & $titleOf $tasks[$i]; if (-not $first.ContainsKey($x)) { $first[$x] = $i + 1 } }
        $ages = & $readAge
        $cur = $null
        foreach ($i in $idx) {
            $parts = $tasks[$i] -split ' // ', 2
            $title = $parts[0].Trim()
            $p = & $parentOf $tasks[$i]
            $color = if ($i) { 'Gray' } else { 'Cyan' }
            if ($p -and $p -ne $cur) { & $say "   ${p}:" $(if ($i) { 'Gray' } else { 'Cyan' }) }
            $cur = $p
            $text = if ($p) { "  $($title.Substring($title.IndexOf(': ') + 2))" } else { $title }
            # After the task, dimmed: its note, and its age once it is three days old
            $dim = $(if ($parts.Count -gt 1) { "  // $($parts[1])" } else { '' }) + $(if ($ages[$title] -and ($x = & $ageOf $ages[$title].Day)) { "  $x" } else { '' })
            & $say "$($i + 1). $text" $color -NoNewline
            if ($first[$title] -ne $i + 1) { & $say $dim DarkGray -NoNewline; & $say "  (same as #$($first[$title]))" Yellow }
            else { & $say $dim DarkGray }
        }
    }

    $logLines = @(); $doneMsg = $null; $allDone = @(); $bump = $null; $renamed = $null; $editMsg = $null
    switch ($cmd) {
        '' {
            if ($tasks.Count) {
                $parts = $tasks[0] -split ' // ', 2
                $parent = & $parentOf $tasks[0]
                $left = if ($parent) { @($tasks | Where-Object { & $isOf $_ @($parent) }).Count } else { 0 }
                if ($left -gt 1) { & $say "$([char]0x25B6) $($parts[0])" Cyan -NoNewline; & $say "  ($left steps left)" DarkGray }
                else { & $say "$([char]0x25B6) $($parts[0])" Cyan }
                if ($parts.Count -gt 1) { & $say "  $($parts[1])" DarkGray }
                # A nudge, never a prompt: a task skipped again and again is probably too big or not wanted
                $e = if (Test-Path $agePath) { (& $readAge)[$parts[0].Trim()] }
                if ($e -and $e.Skips -ge 3) { & $say "skipped $($e.Skips) times: too big, or not wanted? (t e to reword it, t del to drop it)" DarkGray }
            }
            elseif (-not $OneTaskOpening) { & $say 'Nothing to do. Add one: t <task>' DarkGray }
            if ($copies.Count) { & $say 'Your sync app saved a conflict copy. Run: t merge' Yellow }
            return
        }
        'help' {
            @(
                'Capture'
                '  t <task> [// note]       park a task at the bottom'
                '  t <Parent>: <task>       park it under a parent (made if new)'
                '  t <Parent>:              type several tasks for a parent'
                '  t "<text>"               park the text as typed, even if it starts with a verb'
                'Verbs'
                '  t                        show the current task'
                '  t list   | l             all tasks, numbered'
                '  t find   | f <text>      tasks containing the text, with their numbers'
                '  t done   | d [sel]       finish'
                '  t skip   | s [sel]       later: a step goes to the end of its parent, anything else to the bottom'
                '  t now    | n <sel|task>  to the top (a step brings its parent); text is a new task at the top'
                '  t del    | x [sel]       remove (logged as dropped)'
                '                           sel: nothing = the current task, numbers (2 5), or a Parent:'
                '  t edit   | e             open todo.txt in your editor'
                '  t e [n] // <note>        add a note (to the current task, or to task n)'
                '  t e <n> <new text>       reword task n'
                '  t undo   | u             take back the last change'
                '  t log    | g [name]      what you finished; how well a routine is kept'
                '  t routine| r             the routine; t routine <line> adds, t routine del <n> removes'
                '  t help   | h             this help'
                'Rare'
                '  t merge | t setup | t uninstall'
            ) | ForEach-Object { if ($_.StartsWith(' ')) { & $say $_ } else { & $say $_ Cyan } }
            & $say "A verb never parks. Text with ' ; # | & or `$ needs quotes: t `"don't forget`"" DarkGray
            return
        }
        'log' {
            # The one place done.txt is read back: reports only, nothing acts on it.
            # t log: this week, and how each routine entry was kept. t log <name>: one routine entry, or the
            # tasks called "<name>" or "<name>: ...".
            $hist = @(foreach ($l in @(if (Test-Path $DONE) { [IO.File]::ReadAllLines($DONE) })) {
                if ($l -match '^(\d{4}-\d{2}-\d{2}) (missed: |dropped: )?(.+)$') {
                    $d = $Matches[1]; $k = if ($Matches[2]) { $Matches[2].Substring(0, $Matches[2].Length - 2) } else { 'done' }; $x = $Matches[3]
                    [pscustomobject]@{ Day = $d; Kind = $k; Title = & $titleOf $x }
                }
            })
            $since  = $now.Date.AddDays(-27).ToString('yyyy-MM-dd')
            $monday = $now.Date.AddDays(-(([int]$now.DayOfWeek + 6) % 7)).ToString('yyyy-MM-dd')
            # The days in the last 4 weeks on which <name> was logged: kept when it was done and nothing of it missed.
            # Done plus missed days are the days it was due, so earlier schedules need not be known.
            $daysOf = {
                param($name)
                $mine = @($hist | Where-Object { $_.Kind -ne 'dropped' -and $_.Day -ge $since -and (& $isOf $_.Title @($name)) })
                @($mine | Group-Object Day | Sort-Object Name | ForEach-Object { [pscustomobject]@{ Day = $_.Name; Kept = -not @($_.Group | Where-Object { $_.Kind -eq 'missed' }).Count } })
            }
            $statOf = {
                param($days)
                $kept = @($days | Where-Object { $_.Kept }).Count
                $streak = 0
                for ($i = $days.Count - 1; $i -ge 0 -and $days[$i].Kept; $i--) { $streak++ }
                $pct = if ($days.Count) { [int][Math]::Round(100 * $kept / $days.Count) } else { 0 }
                [pscustomobject]@{ Total = $days.Count; Kept = $kept; Pct = $pct; Streak = $streak; Color = $(if ($pct -ge 80) { 'Green' } elseif ($pct -ge 50) { 'Yellow' } else { 'Red' }) }
            }
            if ($rest.Count) {
                $name  = $rest -join ' '
                $mine  = @($hist | Where-Object { & $isOf $_.Title @($name) })
                $entry = @($items | Where-Object { $_.Key -eq $name })[0]
                if (-not $mine.Count -and -not $entry) {
                    # "log" also starts real tasks ("log hours"): with no history for the text, it is one
                    if ((& $findDupe "log $name") -ge 0) { & $say 'already on your list.' DarkGray; return }
                    $tasks += "log $name"
                    if (& $commit 'park') { & $say "parked. (no history for '$name')" DarkGray }
                    return
                }
                if ($entry -or @($mine | Where-Object { $_.Kind -eq 'missed' }).Count) {
                    & $say $(if ($entry) { "$($entry.Key)  $(& $whenOf $entry)" } else { $name })
                    $days = @(& $daysOf $name)
                    if (-not $days.Count) { & $say 'nothing logged in the last 4 weeks.' DarkGray; return }
                    $st = & $statOf $days
                    & $say "last 4 weeks: $($st.Kept) of $($st.Total) days ($($st.Pct)%), streak $($st.Streak)" $st.Color
                    # The last 20 days it was due, oldest first, in fives: x kept, . missed
                    $marks = @($days | Select-Object -Last 20 | ForEach-Object { if ($_.Kept) { 'x' } else { '.' } })
                    & $say (@(for ($i = 0; $i -lt $marks.Count; $i += 5) { $marks[$i..([Math]::Min($i + 4, $marks.Count - 1))] -join ' ' }) -join '  ') DarkGray
                } else {
                    $done = @($mine | Where-Object { $_.Kind -eq 'done' })
                    $drop = @($mine | Where-Object { $_.Kind -eq 'dropped' }).Count
                    $week = @($done | Where-Object { $_.Day -ge $monday }).Count
                    & $say ("${name}: $($done.Count) done ($week this week)" + $(if ($done.Count) { ", last on $($done[-1].Day)" } else { '' }) + $(if ($drop) { ", $drop dropped" } else { '' }))
                }
                return
            }
            $wk = @($hist | Where-Object { $_.Day -ge $monday })
            & $say "this week: $(@($wk | Where-Object { $_.Kind -eq 'done' }).Count) done, $(@($wk | Where-Object { $_.Kind -eq 'dropped' }).Count) dropped, $(@($wk | Where-Object { $_.Kind -eq 'missed' }).Count) missed"
            $keys = @($items | ForEach-Object { $_.Key } | Select-Object -Unique)
            if ($keys.Count) {
                & $say 'routine, last 4 weeks:'
                $pad = ($keys | ForEach-Object { $_.Length } | Measure-Object -Maximum).Maximum
                foreach ($k in $keys) {
                    $st = & $statOf @(& $daysOf $k)
                    if ($st.Total) { & $say "  $($k.PadRight($pad))  $($st.Kept) of $($st.Total) days  $($st.Pct)%  streak $($st.Streak)" $st.Color }
                    else { & $say "  $($k.PadRight($pad))  nothing logged yet" DarkGray }
                }
            }
            return
        }
        'undo' {
            $u = @(if (Test-Path $UNDO) { [IO.File]::ReadAllLines($UNDO) })
            if ($u.Count -lt 5 -or $u[0] -notin 'todo', 'routine', 'both') { Remove-Item $UNDO -ErrorAction SilentlyContinue; & $say 'Nothing to undo.' DarkGray; return }
            $target = $u[0]; $n = [int]$u[4]
            $same = $u[2] -eq (& $ticksOf $target)
            if (-not $same -and (& $ask 'Your files changed since then. Undo anyway? [y/N]') -ne 'y') { return }
            if ($target -ne 'routine') { & $save $TODO @(& $toFile @($u | Select-Object -Skip 5 | Select-Object -First $n)) }
            if ($target -ne 'todo') { & $save $ROUTINE @($u | Select-Object -Skip (5 + $n)) }
            # done.txt is cut back only when nothing else has touched the files, so routine "missed:" lines are never lost
            if ($same -and (Test-Path $DONE) -and (Get-Item $DONE).Length -gt [long]$u[1]) { $fs = [IO.File]::OpenWrite($DONE); $fs.SetLength([long]$u[1]); $fs.Close() }
            elseif (-not $same) { & $say 'done.txt was left as it is.' DarkGray }
            Remove-Item $UNDO
            & $say "undone: $($u[3])" DarkGray
            t
            return
        }
        'done' {
            if (-not $tasks.Count) { & $say 'Nothing to do. Add one: t <task>' DarkGray; return }
            $pick = & $select 'done'
            if ($null -eq $pick) { return }
            $pick = @($pick)
            # One task is done at once (t undo takes it back); several are shown first
            if ($pick.Count -gt 1) {
                $pick | ForEach-Object { & $say "  $($tasks[$_])" }
                if ((& $ask 'Mark done? [y/N]') -ne 'y') { return }
                $doneMsg = "done: $($pick.Count) tasks"
            } elseif ($rest.Count) { $doneMsg = "done: $(& $titleOf $tasks[$pick[0]])" }
            $logLines = @($pick | ForEach-Object { "$day $($tasks[$_])" })
            $parents = @($pick | ForEach-Object { & $parentOf $tasks[$_] } | Where-Object { $_ } | Select-Object -Unique)
            $tasks = @(for ($i = 0; $i -lt $tasks.Count; $i++) { if ($i -notin $pick) { $tasks[$i] } })
            $allDone = @($parents | Where-Object { $p = $_; -not @($tasks | Where-Object { & $isOf $_ @($p) }).Count })
        }
        'del' {
            if (-not $tasks.Count) { & $say 'Nothing to do. Add one: t <task>' DarkGray; return }
            $pick = & $select 'del'
            if ($null -eq $pick) { return }
            $pick = @($pick)
            $pick | ForEach-Object { & $say "  $($tasks[$_])" }
            if ((& $ask 'Delete? [y/N]') -ne 'y') { return }
            $logLines = @($pick | ForEach-Object { "$day dropped: $($tasks[$_])" })
            $tasks = @(for ($i = 0; $i -lt $tasks.Count; $i++) { if ($i -notin $pick) { $tasks[$i] } })
        }
        'skip' {
            # A plain task goes to the bottom of the list. A task of a parent goes to the end of its parent, so
            # the group stays together; when every task left of a parent is skipped, the group goes to the bottom.
            if (-not $tasks.Count) { & $say 'Nothing to do. Add one: t <task>' DarkGray; return }
            if ($tasks.Count -eq 1) { & $say 'Only one task on your list.' DarkGray; return }
            $pick = & $select 'skip'
            if ($null -eq $pick) { return }
            $sel = @{}; foreach ($i in @($pick)) { $sel[$i] = $true }
            $stay = @{}   # parent -> how many of its tasks are not skipped
            for ($i = 0; $i -lt $tasks.Count; $i++) { $p = & $parentOf $tasks[$i]; if ($p -and -not $sel[$i]) { $stay[$p] = 1 + $stay[$p] } }
            $keep = @(); $late = @{}; $tail = @()
            for ($i = 0; $i -lt $tasks.Count; $i++) {
                $p = & $parentOf $tasks[$i]
                if (-not $sel[$i]) { $keep += $tasks[$i] }
                elseif ($p -and $stay[$p]) { if (-not $late.ContainsKey($p)) { $late[$p] = @() }; $late[$p] += $tasks[$i] }
                else { $tail += $tasks[$i] }
            }
            $new = @(for ($i = 0; $i -lt $keep.Count; $i++) {
                $keep[$i]
                $p = & $parentOf $keep[$i]
                if ($p -and $late[$p] -and ($i + 1 -eq $keep.Count -or (& $parentOf $keep[$i + 1]) -ne $p)) { $late[$p] }
            }) + $tail
            if (($new -join "`n") -ceq ($tasks -join "`n")) { & $say 'Nothing to move.' DarkGray; return }
            $bump = @(@($pick) | ForEach-Object { & $titleOf $tasks[$_] })
            $tasks = $new
        }
        'now' {
            # Numbers or "Parent:" move those tasks to the top; a task of a parent brings its whole group, with
            # that task first. Any other text is a new task at the top (or moves the task with exactly that title).
            if (-not $rest.Count) { & $say 'Usage: t now <task>, t now <numbers> or t now <Parent>:' Yellow; return }
            $text = $rest -join ' '
            if ($text -match '^[\d,\s]+$' -or $text -match '^[^:]+:$') {
                $pick = & $select 'now'
                if ($null -eq $pick) { return }
            } else {
                $i = & $findDupe $text
                if ($i -ge 0) { & $say 'Already on your list; moved to the top.' DarkGray; $pick = @($i) }
                else { $tasks = @($text) + $tasks; $pick = @(0) }
            }
            $sel = @{}; foreach ($i in @($pick)) { $sel[$i] = $true }
            $front = @(); $moved = @{}
            foreach ($i in @($pick)) {
                $p = & $parentOf $tasks[$i]
                if (-not $p) { $front += $tasks[$i]; continue }
                if ($moved[$p]) { continue }
                $moved[$p] = $true
                $all = @(for ($j = 0; $j -lt $tasks.Count; $j++) { if ((& $parentOf $tasks[$j]) -eq $p) { $j } })
                $front += @($all | Where-Object { $sel[$_] } | ForEach-Object { $tasks[$_] }) + @($all | Where-Object { -not $sel[$_] } | ForEach-Object { $tasks[$_] })
            }
            $tasks = $front + @(for ($i = 0; $i -lt $tasks.Count; $i++) { $p = & $parentOf $tasks[$i]; if (-not $sel[$i] -and -not ($p -and $moved[$p])) { $tasks[$i] } })
        }
        'find' {
            if (-not $rest.Count) { & $say 'Usage: t find <text>' Yellow; return }
            $text = $rest -join ' '
            $idx = @(for ($i = 0; $i -lt $tasks.Count; $i++) { if ($tasks[$i].IndexOf($text, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $i } })
            if (-not $idx.Count) { & $say "Nothing matches '$text'." DarkGray; return }
            & $show $idx
            return
        }
        'list' {
            if (-not $tasks.Count) { & $say 'Nothing to do. Add one: t <task>' DarkGray; return }
            & $show @(0..($tasks.Count - 1))
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
                        $newTasks += @(& $fromFile $lines | Where-Object { $tasks -notcontains $_ -and $gone -notcontains $_ -and -not (& $isOf $_ @($items | ForEach-Object { $_.Key; $_.Titles })) })
                        $drop += $c
                    }
                    '^done' { $newDone += @($lines | Where-Object { $doneLines -notcontains $_ }); $drop += $c }
                    '\.(last|undo|age)$' { $drop += $c }   # the tool's own state; the main files win
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
            $tasks += $newTasks
            if (-not (& $commit 'merge' $newDone)) { return }
            $drop | Remove-Item
            t
            return
        }
        { $_ -in 'edit', 'routine edit' } {
            if ($rest.Count) {
                # t e [n] // <note> adds a note; t e <n> <new text> rewords. Without a number, "//" means the current task.
                $text = $rest -join ' '
                if ($text -notmatch '^(?:(?<n>\d+) )?// (?<note>.+)$' -and $text -notmatch '^(?<n>\d+) (?<new>.+)$') { & $say 'Usage: t e | t e [n] // <note> | t e <n> <new text>' Yellow; return }
                $note = $Matches.note; $new = $Matches.new
                $i = if ($Matches.n) { [int]$Matches.n - 1 } else { 0 }
                if (-not $tasks.Count) { & $say 'Nothing to do. Add one: t <task>' DarkGray; return }
                if ($i -lt 0 -or $i -ge $tasks.Count) { & $say 'No such number. See: t list' Yellow; return }
                if ($note) { $tasks[$i] = if ($tasks[$i] -match ' // ') { "$($tasks[$i]); $note" } else { "$($tasks[$i]) // $note" } }
                else {
                    # A task of a parent stays in its parent. The note is kept unless the new text brings its own
                    # ("x // new note") or ends with "//" (no note).
                    $old = $tasks[$i] -split ' // ', 2
                    $p = & $parentOf $tasks[$i]
                    if ($p) { $new = "${p}: $new" }
                    $line = if ($new -match ' // ') { $new } elseif ($new -match '\s*//$') { ($new -replace '\s*//$', '').Trim() } elseif ($old.Count -gt 1) { "$new // $($old[1])" } else { $new }
                    $j = & $findDupe $line
                    if ($j -ge 0 -and $j -ne $i) { & $say "already on your list (#$($j + 1))." DarkGray; return }
                    $renamed = @((& $titleOf $tasks[$i]), (& $titleOf $line))
                    $tasks[$i] = $line
                }
                if ($i) { $editMsg = "#$($i + 1): $($tasks[$i])" }
                break
            }
            # A terminal editor first: $VISUAL/$EDITOR, then nvim, vim, nano, Microsoft Edit; Notepad as the fallback.
            # t waits for the editor, Notepad included, so the edit can be checked and taken back with t undo.
            $file = if ($cmd -eq 'edit') { $TODO } else { $ROUTINE }
            $old = @(if (Test-Path $file) { [IO.File]::ReadAllLines($file) })
            $ed = @($env:VISUAL, $env:EDITOR | Where-Object { $_ })
            if ($ed.Count) { & $env:ComSpec /c "$($ed[0]) `"$file`"" }   # cmd parses an editor command with its own arguments
            elseif ($c = Get-Command nvim, vim, nano, edit -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1) { & $c.Source $file }
            else { Start-Process notepad "`"$file`"" -Wait }
            $raw = @(if (Test-Path $file) { [IO.File]::ReadAllLines($file) })
            if (($raw -join "`n") -cne ($old -join "`n")) {
                if ($cmd -eq 'edit') {
                    & $lint $raw | ForEach-Object { & $say $_ Yellow }
                    # Stored in the tidy form through $commit, which also keeps the undo state and the ages
                    $tasks = @(& $fromFile $raw)
                    $seen = "$((Get-Item $TODO).LastWriteTimeUtc.Ticks)"
                    if (-not (& $commit 'edit')) { return }
                } else {
                    $len = if (Test-Path $DONE) { (Get-Item $DONE).Length } else { 0 }
                    & $stash 'routine' $len 'routine edit' @() $old
                }
            }
            t   # show the task again, and re-arm reminders if the routine changed
            return
        }
        'routine list' {
            if (-not $items.Count) { & $say 'No routine yet. Add one: t routine <task>' DarkGray; return }
            for ($i = 0; $i -lt $items.Count; $i++) {
                & $say "$($i + 1). $($items[$i].Text)" -NoNewline
                $warn = & $warnOf $items[$i]
                if ($warn) { & $say "  $(& $whenOf $items[$i])" DarkGray -NoNewline; & $say "  ? $warn" Yellow }
                else { & $say "  $(& $whenOf $items[$i])" DarkGray }
            }
            return
        }
        'routine add' {
            # One line from the command line, or several typed at a prompt (any characters) until an empty line
            $lines = @(if (Test-Path $ROUTINE) { [IO.File]::ReadAllLines($ROUTINE) })
            $count = $lines.Count
            # Dot-run for each line, so it can add to $lines and $items
            $addLine = {
                param($l)
                $r = & $parseLine $l 0
                if (-not $r) { return }
                # A near miss is refused on the command line; at the prompt it can be added as written
                $warn = & $warnOf $r
                if ($warn) {
                    & $say "  $warn" Yellow
                    if ($rest.Count) { & $say '  Not added. To add it as written, type it at the prompt: t routine add' Yellow; return }
                    if ((& $ask '  Add it as written? [y/N]') -ne 'y') { return }
                }
                if (@($items | ForEach-Object { $_.Key }) -contains $r.Key) { & $say "  already in your routine: $($r.Key)" DarkGray; return }
                $lines += & $glue $l
                $items += $r
                & $say "  added to your routine: $($r.Text) ($(& $whenOf $r))" DarkGray
            }
            if ($rest.Count) { . $addLine ($rest -join ' ') } else { while ($line = "$(& $ask 'Routine')".Trim()) { . $addLine $line } }
            if ($lines.Count -gt $count) { & $save $ROUTINE @($lines | ForEach-Object { & $tidy $_ }) }
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
            & $save $ROUTINE @($lines | ForEach-Object { & $tidy $_ })
            & $say "  removed $($gone.Count) from your routine." DarkGray
            return
        }
        '--remind' {
            # Run by the OneTask scheduled task. The routine code above has already put due tasks on top
            # and re-armed the task; this shows them, batched into one toast (several after a wake).
            if (-not $dueShown.Count -or $PSVersionTable.PSEdition -ne 'Desktop') { return }
            $null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
            $null = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom, ContentType = WindowsRuntime]
            $lines = @(if ($dueShown.Count -eq 1) { $dueShown[0] } else { "$($dueShown.Count) tasks due"; $dueShown -join ', ' })
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
                    '# Optional prefixes: weekdays, weekends, or days such as mon,thu or mon-fri; then a time'
                    '# (14:00 or 2pm) to add the task at that time instead of in the morning; then quiet for'
                    '# no notification. Steps: name: a / b. Examples:'
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
        'park' {
            $text = $rest -join ' '
            $have = @($tasks | ForEach-Object { & $parentOf $_ } | Where-Object { $_ } | Select-Object -Unique)
            # "Report:" alone asks for its tasks, so they can hold any characters; they are added as one change
            $bulk = if (-not $literal -and $text -match '^(?<p>[^:]+):$') { $Matches.p.Trim() }
            $p = if ($bulk) { $bulk } else { & $parentOf $text }
            $known = @($have | Where-Object { $_ -eq $p })[0]
            $near = if ($p -and -not $known) { @($have | Where-Object { (& $lev $_.ToLower() $p.ToLower()) -le $(if ($p.Length -ge 5) { 2 } else { 1 }) })[0] }
            if ($bulk) {
                $typed = @(while ($line = "$(& $ask 'Task')".Trim()) { $line })
                . $read   # a reminder or a sync may have changed the file while the prompt was open
                $new = @($typed | ForEach-Object { "${bulk}: $_" } | Where-Object { (& $findDupe $_) -lt 0 } | Select-Object -Unique)
                if (-not $new.Count) { & $say $(if ($typed.Count) { 'already on your list.' } else { 'Nothing added.' }) DarkGray; return }
                $tasks += $new
                if (-not (& $commit 'park')) { return }
                & $say "Added $($new.Count) task$(if ($new.Count -gt 1) { 's' }) under $(if ($known) { $known } else { $bulk })." DarkGray
            } else {
                $i = & $findDupe $text
                if ($i -ge 0) { & $say "already on your list (#$($i + 1))." DarkGray; return }
                $tasks += $text
                if (-not (& $commit 'park')) { return }
                & $say $(if ($known) { "parked under $known." } else { 'parked.' }) DarkGray
            }
            if ($near) { & $say "new group '$p' (close to '$near'; t undo)" DarkGray }
            return
        }
    }
    if (-not (& $commit $cmd $logLines)) { return }
    if ($doneMsg) { & $say "$doneMsg  (t undo to revert)" Green }
    if ($editMsg) { & $say $editMsg DarkGray }
    foreach ($p in $allDone) { & $say "${p}: all steps done." Green }
    t
    # After a done, at most once a day: point at the task that has waited longest (three weeks or more).
    # t suggests; it never reorders the list itself.
    if ($cmd -eq 'done') {
        $ages = & $readAge
        if ($ages["`t"] -ne $day) {
            $limit = $now.Date.AddDays(-21).ToString('yyyy-MM-dd')
            $old = $null
            for ($i = 1; $i -lt $tasks.Count; $i++) {
                $e = $ages[(& $titleOf $tasks[$i])]
                if ($e -and $e.Day -le $limit -and (-not $old -or $e.Day -lt $old.Day)) { $old = @{ Day = $e.Day; Index = $i } }
            }
            if ($old) {
                $weeks = [int][Math]::Floor(($now.Date - [datetime]::ParseExact($old.Day, 'yyyy-MM-dd', $null)).Days / 7)
                & $say "waiting $weeks weeks: $(& $titleOf $tasks[$old.Index])  (t now $($old.Index + 1))" DarkGray
                $ages["`t"] = $day
                & $writeAge $ages
            }
        }
    }
}

# Bare t shows the one task whenever a terminal opens; an empty list stays silent there
if ($Command) { t @Command } else { $OneTaskOpening = $true; t; $OneTaskOpening = $false }
