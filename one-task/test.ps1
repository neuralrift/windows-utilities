# test.ps1 - regression tests for t.ps1. Touches only a temp folder; never the profile, registry or scheduled task.
# Run in both editions:
#   powershell -NoProfile -ExecutionPolicy Bypass -File test.ps1
#   pwsh -NoProfile -File test.ps1
$tmpRoot = [IO.Path]::GetTempPath()
Get-ChildItem $tmpRoot -Directory -Filter 'one-task-test-*' -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force   # leftovers of crashed runs
$dir = Join-Path $tmpRoot "one-task-test-$PID"
$fail = 0; $count = 0
$arrow = [char]0x25B6
$OneTaskNoArm = $true
$env:NO_COLOR = '1'

# 2026-11-09 is a Monday
function Reset([string[]]$Todo = @(), [string[]]$Routine, [string]$Now = '2026-11-09 09:00') {
    Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
    New-Item $dir -ItemType Directory | Out-Null
    [IO.File]::WriteAllLines("$dir\todo.txt", $Todo)
    if ($Routine) { [IO.File]::WriteAllLines("$dir\routine.txt", $Routine) }
    $script:OneTaskNow = [datetime]$Now
    $script:OneTaskAnswers = $null
}
function At([string]$Now) { $script:OneTaskNow = [datetime]$Now }
function Answers { $script:OneTaskAnswers = New-Object Collections.Queue (, [object[]]$args) }
# Output lines joined with "|". A piece printed without a newline is its own element.
function Run { (t @args 6>&1 | ForEach-Object { "$_" }) -join '|' }
function File([string]$Name) { if (Test-Path "$dir\$Name") { [IO.File]::ReadAllLines("$dir\$Name") -join '|' } else { '' } }
function Is([string]$Name, $Actual, $Expected) {
    $script:count++
    if ("$Actual" -cne "$Expected") { $script:fail++; Write-Host "FAIL $Name`n  expected: $Expected`n  actual:   $Actual" -ForegroundColor Red }
}

try {
    Reset
    . "$PSScriptRoot\t.ps1" -Folder $dir

    # --- basics ---
    Is 'empty'        (Run)                      'Nothing to do. Add one: t <task>'
    Is 'park'         (Run write report)         'parked.'
    Is 'dupe'         (Run Write Report)         'already on your list (#1).'
    Is 'park 2'       (Run call bank)            'parked.'
    Is 'show'         (Run)                      "$arrow write report"
    Is 'skip'         (Run skip)                 "$arrow call bank"
    Is 'done'         (Run done)                 "$arrow write report"
    Is 'done.txt'     (File done.txt)            '2026-11-09 call bank'
    Is 'list word'    (Run list groceries)       'parked.'
    Is 'todo.txt'     (File todo.txt)            'write report|list groceries'
    Is 'list'         (Run list)                 '1. write report||2. list groceries|'
    Answers 'n'
    Is 'del no'       (Run del 2)                '  list groceries'
    Is 'del kept'     (File todo.txt)            'write report|list groceries'
    Answers 'y'
    Is 'del yes'      (Run del 2)                "  list groceries|$arrow write report"
    Is 'del logged'   (File done.txt)            '2026-11-09 call bank|2026-11-09 dropped: list groceries'
    Is 'note'         (Run note ask Sam)         "$arrow write report|  ask Sam"
    Is 'split'        (Run split a / b)          "$arrow write report: a|  ask Sam"
    Is 'split file'   (File todo.txt)            'write report: a // ask Sam|write report: b'
    Is 'help word'    (Run help Sam move)        'parked.'
    Is 'commas'       (Run buy milk, eggs)       'parked.'
    Is 'commas file'  ((File todo.txt) -replace '^.*\|', '')   'buy milk, eggs'

    # --- routine ---
    Reset -Routine 'review inbox', 'weekdays 14:00 timesheet'
    Is 'routine day'  (Run list)                 '1. review inbox|'
    At '2026-11-09 14:30'
    Is 'timed'        (Run list)                 '1. timesheet||2. review inbox|'
    At '2026-11-10 08:00'
    Run | Out-Null
    Is 'missed'       (File done.txt)            '2026-11-09 missed: review inbox|2026-11-09 missed: timesheet'
    Is 'fresh copy'   (File todo.txt)            'review inbox'
    Is 'routine list' (Run routine)              '1. review inbox|  every day, in the morning|2. timesheet|  weekdays at 14:00'
    Is 'routine dupe' (Run routine Review Inbox) '  already in your routine: Review Inbox'

    # --- step 2: reliability ---
    Reset -Routine 'review inbox'
    Run note check finance | Out-Null
    At '2026-11-10 09:00'; Run | Out-Null
    Is 'note: one copy'   (File todo.txt)      'review inbox'
    Is 'note: missed'     (File done.txt)      '2026-11-09 missed: review inbox'
    Reset -Routine 'review inbox'
    Run split a / b | Out-Null
    At '2026-11-10 09:00'; Run | Out-Null
    Is 'split: replaced'  (File todo.txt)      'review inbox'
    Reset 'a'
    Run b | Out-Null
    Is 'no tmp left'      (Test-Path "$dir\todo.txt.tmp")   'False'
    Reset 'a', 'b', 'c'
    Run done | Out-Null
    Is 'undo done'        (Run undo)           "undone: done|$arrow a"
    Is 'undo todo'        (File todo.txt)      'a|b|c'
    Is 'undo done.txt'    (File done.txt)      ''
    Is 'undo twice'       (Run undo)           'Nothing to undo.'
    Run skip | Out-Null; Run undo | Out-Null
    Is 'undo skip'        (File todo.txt)      'a|b|c'
    Is 'done by number'   (Run done 2)         "done: b  (t undo to revert)|$arrow a"
    Is 'done by text'     (Run done c)         "done: c  (t undo to revert)|$arrow a"
    Run undo | Out-Null
    Is 'undo by text'     (File todo.txt)      'a|c'
    Answers 'y'
    Is 'done several'     (Run done 1 2)       '  a|  c|done: 2 tasks  (t undo to revert)|Nothing to do. Add one: t <task>'
    Is 'undo word'        (Run undo the mess)  'parked.'
    Run x | Out-Null; Run undo | Out-Null
    Is 'undo park'        (File todo.txt)      'undo the mess'
} finally {
    Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
}
if ($fail) { Write-Host "$fail of $count failed ($($PSVersionTable.PSEdition))" -ForegroundColor Red; exit 1 }
Write-Host "$count passed ($($PSVersionTable.PSEdition))"
