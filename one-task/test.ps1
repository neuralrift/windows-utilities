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
function Answers { $script:OneTaskAnswers = New-Object Collections.Queue (, [object[]]@($args | ForEach-Object { $_ })) }   # Answers 'y', 'n' or Answers 'y' 'n'
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
    Is 'split'        (Run split a / b)          "$arrow write report: a|  (2 steps left)|  ask Sam"
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

    # --- step 3: commands ---
    Reset 'a', 'b', 'c'
    Is 'now number'     (Run now 3)                  "$arrow c"
    Is 'now order'      (File todo.txt)              'c|a|b'
    Is 'now bad'        (Run now 9)                  'No such number. See: t list'
    Is 'now dupe'       (Run now B)                  "Already on your list; moved to the top.|$arrow b"
    Is 'now new'        (Run now fix bug)            "$arrow fix bug"
    Is 'now alone'      (Run now)                    'Usage: t now <task>, or t now <number> to move a task to the top'
    Is 'top parks'      (Run top 2)                  'parked.'
    Reset 'call bank // ask fee'
    Is 'reword'         (Run reword phone the bank)  "$arrow phone the bank|  ask fee"
    Run reword phone the bank // | Out-Null
    Is 'reword clears'  (File todo.txt)              'phone the bank'
    Is 'skip one'       (Run skip)                   'Only one task on your list.'
    Answers 'x', 'y', ''
    Is 'split prompt'   (Run split)                  "$arrow phone the bank: x|  (2 steps left)"
    Is 'split file 2'   (File todo.txt)              'phone the bank: x|phone the bank: y'
    Reset
    Is 'skip empty'     (Run skip)                   'Nothing to do. Add one: t <task>'
    Is 'done empty'     (Run done)                   'Nothing to do. Add one: t <task>'
    Is 'routine add x'  (Run routine add tests)      '  added to your routine: add tests (every day, in the morning)'
    Is 'routine edit x' (Run routine edit slides)    '  added to your routine: edit slides (every day, in the morning)'
    Is 'routine list x' (Run routine list of chores) '  added to your routine: list of chores (every day, in the morning)'
    Answers 'weekdays 14:00 timesheet', ''
    Is 'routine prompt' (Run routine add)            '  added to your routine: timesheet (weekdays at 14:00)'
    Answers 'y'
    Is 'routine del'    (Run routine del 1)          '  add tests  every day, in the morning|  removed 1 from your routine.'
    Is 'help'           ((Run help).Split('|')[0])   'Every day'

    # --- step 4: steps ---
    Reset
    Is 'inline steps'   (Run report: draft / review / send)   'parked 3 steps.'
    Is 'steps file'     (File todo.txt)                       'report: draft|report: review|report: send'
    Is 'steps left'     (Run)                                 "$arrow report: draft|  (3 steps left)"
    Is 'steps again'    (Run report: draft / review)          'already on your list (#1).'
    Is 'no parent'      (Run call mom / dad)                  'parked.'
    Is 'now steps'      (Run now fix: find / patch)           "$arrow fix: find|  (2 steps left)"
    Run done | Out-Null
    Is 'last step'      (Run done)                            "fix: all steps done.|$arrow report: draft|  (3 steps left)"
    Reset
    Is 'steps + note'   (Run trip: book / pack // by friday)  'parked 2 steps.'
    Is 'note on first'  (File todo.txt)                       'trip: book // by friday|trip: pack'
    Reset -Routine 'weekdays 07:00 morning: stretch / shower', 'weekdays plan: review / pick' -Now '2026-11-09 06:00'
    Is 'routine steps'  (File todo.txt)                       ''
    Run | Out-Null
    Is 'untimed steps'  (File todo.txt)                       'plan: review|plan: pick'
    At '2026-11-09 07:30'; Run | Out-Null
    Is 'timed steps'    (File todo.txt)                       'morning: stretch|morning: shower|plan: review|plan: pick'
    Run done | Out-Null
    At '2026-11-09 08:00'; Run | Out-Null
    Is 'no re-add'      (File todo.txt)                       'morning: shower|plan: review|plan: pick'
    At '2026-11-10 06:00'; Run | Out-Null
    Is 'step missed'    (File done.txt)                       '2026-11-09 morning: stretch|2026-11-09 missed: plan: review|2026-11-09 missed: plan: pick|2026-11-09 missed: morning: shower'
    Is 'steps fresh'    (File todo.txt)                       'plan: review|plan: pick'
    Is 'routine shows'  (Run routine)                         '1. morning: stretch / shower|  weekdays at 07:00|2. plan: review / pick|  weekdays, in the morning'
    Is 'routine key'    (Run routine morning: other / thing)  '  already in your routine: morning'

    # --- step 5: routine parsing ---
    Reset
    Is 'full day'     (Run routine Monday 2pm standup)       '  added to your routine: standup (mon at 14:00)'
    Is 'range'        (Run routine mon-fri 9.30 mail)        '  added to your routine: mail (weekdays at 09:30)'
    Is 'wrap range'   (Run routine fri-mon walk)             '  added to your routine: walk (sun,mon,fri,sat, in the morning)'
    Is 'everyday'     (Run routine everyday 12am backup)     '  added to your routine: backup (every day at 00:00)'
    Is 'typo day'     (Run routine weekdys 14:00 x)          "  'weekdys' looks like 'weekdays'|  Not added. To add it as written, type it at the prompt: t routine add"
    Is 'typo list'    (Run routine mon,thr 9:00 x)           "  'mon,thr' looks like a list of days; use forms such as mon,thu or mon-fri|  Not added. To add it as written, type it at the prompt: t routine add"
    Is 'bad time'     (Run routine 25:00 x)                  "  '25:00' looks like a time; use forms such as 14:00 or 2pm|  Not added. To add it as written, type it at the prompt: t routine add"
    Is 'bad time 2'   (Run routine weekdays 13pm x)          "  '13pm' looks like a time; use forms such as 14:00 or 2pm|  Not added. To add it as written, type it at the prompt: t routine add"
    Is 'not a time'   (Run routine 10 pushups)               '  added to your routine: 10 pushups (every day, in the morning)'
    Is 'not a day'    (Run routine weekly report)            '  added to your routine: weekly report (every day, in the morning)'
    Is 'the'          (Run routine the review)               '  added to your routine: the review (every day, in the morning)'
    Is 'quiet'        (Run routine weekdays 14:00 quiet ts)  '  added to your routine: ts (weekdays at 14:00, quiet)'
    Answers '25:00 odd name', 'y', ''
    Is 'as written'   (Run routine add)                      "  '25:00' looks like a time; use forms such as 14:00 or 2pm|  added to your routine: 25:00 odd name (every day, in the morning)"
    Is 'list warns'   ((Run routine).Split('|')[-1])         "  ? '25:00' looks like a time; use forms such as 14:00 or 2pm"
    Reset -Routine '# keep me', '  weekdays   14:00   spaced  '
    Run routine stretch | Out-Null
    Is 'routine tidy' (File routine.txt)                     '# keep me|weekdays 14:00 spaced|stretch'
    Reset '  spaced    out  ', '', 'x'
    Run y | Out-Null
    Is 'cleaned'      (File todo.txt)                        'spaced out|x|y'
    Reset 'a', 'b // n', 'a'
    Is 'same as'      (Run list)                             '1. a||2. b|  // n|3. a||  (same as #1)'
    Reset -Routine 'weekdays 14:00 quiet timesheet', 'weekdays 14:00 loud one' -Now '2026-11-09 14:30'
    Run | Out-Null
    Is 'quiet on top' (File todo.txt)                        'timesheet|loud one'

    # --- step 6: ages and nudges ---
    Reset 'a', 'b'
    1..6 | ForEach-Object { Run skip | Out-Null }          # a is skipped three times and back on top
    Is 'skip nudge'     (Run)             "$arrow a|skipped 3 times: split it (t split), reword it, or drop it (t del)?"
    Run reword a better | Out-Null
    Is 'reword resets'  (Run)             "$arrow a better"
    Reset 'old one'
    Run new one | Out-Null
    Is 'no age yet'     (Run list)        '1. old one||2. new one|'
    At '2026-11-14 09:00'
    Is 'age days'       (Run list)        '1. old one|  5d|2. new one|  5d'
    At '2026-12-07 09:00'
    Run fresh // note | Out-Null
    Is 'age weeks'      (Run list)        '1. old one|  4w|2. new one|  4w|3. fresh|  // note'
    Reset 'a', 'b', 'c'
    Run d | Out-Null
    At '2026-12-07 09:00'
    Is 'waiting hint'   (Run done)        "$arrow b|waiting 4 weeks: c  (t now 2)"
    Is 'hint once'      (Run done)        "$arrow c"
    Run undo | Out-Null
    Is 'age survives'   (Run list)        '1. b|  4w|2. c|  4w|3. d|  4w'

    # --- step 7: log ---
    Reset
    [IO.File]::WriteAllLines("$dir\done.txt", [string[]]('2026-11-02 gym', '2026-11-03 missed: gym', '2026-11-04 gym // legs', '2026-11-05 gym', '2026-11-06 blog: post one', '2026-10-01 gym', '2026-11-09 dropped: blog: idea'))
    Is 'log name'      (Run log gym)     'gym|last 4 weeks: 3 of 4 days (75%), streak 2|x . x x'
    Is 'log prefix'    (Run log blog)    'blog: 1 done (0 this week), last on 2026-11-06, 1 dropped'
    Is 'log unknown'   (Run log hours)   "parked. (no history for 'hours')"
    Is 'log parked'    (File todo.txt)   'log hours'
    Is 'log week'      (Run log)         'this week: 0 done, 1 dropped, 0 missed'
    Reset -Routine 'weekdays 14:00 timesheet', 'weekdays 07:00 morning: stretch / shower', 'weekends gym'
    [IO.File]::WriteAllLines("$dir\done.txt", [string[]]('2026-11-05 timesheet', '2026-11-06 missed: timesheet', '2026-11-06 morning: stretch', '2026-11-06 missed: morning: shower', '2026-11-05 morning: stretch', '2026-11-05 morning: shower'))
    Is 'log routine'   (Run log timesheet)   'timesheet  weekdays at 14:00|last 4 weeks: 1 of 2 days (50%), streak 0|x .'
    Is 'log steps'     (Run log morning)     'morning  weekdays at 07:00|last 4 weeks: 1 of 2 days (50%), streak 0|x .'
    Is 'log empty'     (Run log gym)         'gym  weekends, in the morning|nothing logged in the last 4 weeks.'
    Is 'log overview'  (Run log)             'this week: 0 done, 0 dropped, 0 missed|routine, last 4 weeks:|  timesheet  1 of 2 days  50%  streak 0|  morning    1 of 2 days  50%  streak 0|  gym        nothing logged yet'
} finally {
    Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
}
if ($fail) { Write-Host "$fail of $count failed ($($PSVersionTable.PSEdition))" -ForegroundColor Red; exit 1 }
Write-Host "$count passed ($($PSVersionTable.PSEdition))"
