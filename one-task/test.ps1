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
    Reset 'a'
    Is 'load is silent' ((. "$PSScriptRoot\t.ps1" -Folder $dir 6>&1 | ForEach-Object { "$_" }) -join '|')   ''
    Is 'manifest'       ((Import-PowerShellDataFile "$PSScriptRoot\OneTask.psd1").ModuleVersion)   $OneTaskVersion
    Is 'exports t'      ("$((Import-PowerShellDataFile "$PSScriptRoot\OneTask.psd1").FunctionsToExport)")   't'
    Reset

    # --- basics ---
    Is 'empty'        (Run)                      'Nothing to do. Add one: t <task>'
    Is 'park'         (Run write report)         'parked.'
    Is 'dupe'         (Run Write Report)         'already on your list (#1).'
    Is 'park 2'       (Run call bank)            'parked.'
    Is 'show'         (Run)                      "$arrow write report"
    Is 'skip'         (Run skip)                 "$arrow call bank"
    Is 'done'         (Run done)                 "$arrow write report"
    Is 'done.txt'     (File done.txt)            '2026-11-09 call bank'
    Is 'list word'    (Run list groceries)       't list takes nothing after it. To park that text, quote it: t "list groceries"'
    Is 'literal'      (Run 'list groceries')     'parked.'
    Is 'todo.txt'     (File todo.txt)            'write report|list groceries'
    Is 'list'         (Run list)                 '1. write report||2. list groceries|'
    Answers 'n'
    Is 'del no'       (Run del 2)                '  list groceries'
    Is 'del kept'     (File todo.txt)            'write report|list groceries'
    Answers 'y'
    Is 'del yes'      (Run del 2)                "  list groceries|$arrow write report"
    Is 'del logged'   (File done.txt)            '2026-11-09 call bank|2026-11-09 dropped: list groceries'
    Is 'help word'    (Run help Sam move)        't help takes nothing after it. To park that text, quote it: t "help Sam move"'
    Is 'commas'       (Run buy milk, eggs)       'parked.'
    Is 'commas file'  ((File todo.txt) -replace '^.*\|', '')   'buy milk, eggs'

    # --- routine ---
    Reset -Routine 'daily 08:00 review inbox', 'remind weekdays 14:00 timesheet', 'no schedule line'
    Is 'routine due'  (Run list)                 '1. review inbox|'
    At '2026-11-09 14:30'
    Is 'timed'        (Run list)                 '1. timesheet||2. review inbox|'
    At '2026-11-10 07:00'
    Run | Out-Null
    Is 'missed'       (File done.txt)            '2026-11-09 missed: review inbox|2026-11-09 missed: timesheet'
    Is 'cleared'      (File todo.txt)            ''
    Is 'routine list' (Run routine)              '1. review inbox|  every day at 08:00|2. timesheet|  weekdays at 14:00, reminder|3. no schedule line|  ? needs days and a time, e.g. weekdays 09:00'
    Is 'routine dupe' (Run daily 9am Review Inbox) 'already in your routine: Review Inbox.'
    Is 'invalid idle' (File todo.txt)            ''

    # --- step 2: reliability ---
    Reset -Routine 'daily 08:00 review inbox'
    Run | Out-Null
    [IO.File]::WriteAllLines("$dir\todo.txt", [string[]]'review inbox // check finance')
    At '2026-11-10 09:00'; Run | Out-Null
    Is 'note: one copy'   (File todo.txt)      'review inbox'
    Is 'note: missed'     (File done.txt)      '2026-11-09 missed: review inbox'
    Reset -Routine 'daily 08:00 review inbox'
    Run | Out-Null
    [IO.File]::WriteAllLines("$dir\todo.txt", [string[]]('review inbox:', '  a', '  b'))
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
    Is 'done by text'     (Run done c)         't done takes numbers or a Parent: (find them with: t find <text>)'
    Run done 2 | Out-Null
    Run undo | Out-Null
    Is 'undo by text'     (File todo.txt)      'a|c'
    Answers 'y'
    Is 'done several'     (Run done 1 2)       '  a|  c|done: 2 tasks  (t undo to revert)|Nothing to do. Add one: t <task>'
    Is 'undo word'        (Run undo the mess)  't undo takes nothing after it. To park that text, quote it: t "undo the mess"'
    Is 'undo literal'     (Run 'undo the mess')  'parked.'
    Run xx | Out-Null; Run undo | Out-Null
    Is 'undo park'        (File todo.txt)      'undo the mess'

    # --- step 3: commands ---
    Reset 'a', 'b', 'c'
    Is 'now number'     (Run now 3)                  "$arrow c"
    Is 'now order'      (File todo.txt)              'c|a|b'
    Is 'now bad'        (Run now 9)                  'No such number. See: t list'
    Is 'now dupe'       (Run now B)                  "Already on your list; moved to the top.|$arrow b"
    Is 'now new'        (Run now fix bug)            "$arrow fix bug"
    Is 'now alone'      (Run now)                    'Usage: t now <task>, t now <numbers> or t now <Parent>:'
    Is 'top parks'      (Run top 2)                  'parked.'
    Reset 'phone the bank'
    Is 'skip one'       (Run skip)                   'Only one task on your list.'
    Reset
    Is 'skip empty'     (Run skip)                   'Nothing to do. Add one: t <task>'
    Is 'done empty'     (Run done)                   'Nothing to do. Add one: t <task>'
    Is 'help'           ((Run help).Split('|')[0])   'Capture'

    # --- step 4: steps ---
    Reset
    Is 'under new'      (Run report: draft)        'parked.'
    Is 'under known'    (Run Report: review)       'parked under report.'
    Answers 'send', "don't forget", 'draft', ''
    Is 'bulk'           (Run report:)              'Added 2 tasks under report.'
    Is 'steps file'     (File todo.txt)            "report:|  draft|  review|  send|  don't forget"
    Is 'steps left'     (Run)                      "$arrow report: draft|  (4 steps left)"
    Is 'steps again'    (Run report: draft)        'already on your list (#1).'
    Run undo | Out-Null
    Is 'bulk undo'      (File todo.txt)            'report:|  draft|  review'
    Is 'near hint'      (Run reprot: x)            "parked.|new group 'reprot' (close to 'report'; t undo)"
    Is 'no parent'      (Run call mom / dad)       'parked.'
    Is 'literal verb'   (Run 'done the dishes')    'parked.'
    Answers ''
    Is 'bulk empty'     (Run chores:)              'Nothing added.'
    Reset 'fix:', '  find', '  patch', 'other'
    Run done | Out-Null
    Is 'last step'      (Run done)                 "fix: all steps done.|$arrow other"
    Reset 'a', 'b'
    Is 'short l'        (Run l)                    (Run list)
    Is 'short s'        (Run s)                    "$arrow b"
    Is 'short d'        (Run d)                    "$arrow a"
    Is 'short u'        (Run u)                    "undone: done|$arrow b"
    Is 'short h'        ((Run h).Split('|')[0])    'Capture'
    Is 'old verb parks' (Run note it down)         'parked.'
    Is 'skip text'      (Run skip this)            't skip takes numbers or a Parent: (find them with: t find <text>)'

    # --- tidying ---
    Reset '  spaced    out  ', '', 'x'
    Run y | Out-Null
    Is 'cleaned'      (File todo.txt)                        'spaced out|x|y'
    Reset 'a', 'b // n', 'a'
    Is 'same as'      (Run list)                             '1. a||2. b|  // n|3. a||  (same as #1)'

    # --- step 6: ages and nudges ---
    Reset 'a', 'b'
    1..6 | ForEach-Object { Run skip | Out-Null }          # a is skipped three times and back on top
    Is 'skip nudge'     (Run)             "$arrow a|skipped 3 times: too big, or not wanted? (t e to reword it, t del to drop it)"
    Reset 'old one'
    Run new one | Out-Null
    Is 'no age yet'     (Run list)        '1. old one||2. new one|'
    At '2026-11-14 09:00'
    Is 'age days'       (Run list)        '1. old one|  5d|2. new one|  5d'
    At '2026-12-07 09:00'
    Run fresh // note | Out-Null
    Is 'age weeks'      (Run list)        '1. old one|  4w|2. new one|  4w|3. fresh|  // note'
    Reset 'a', 'b', 'c'
    Run dd | Out-Null
    At '2026-12-07 09:00'
    Is 'waiting hint'   (Run done)        "$arrow b|waiting 4 weeks: c  (t now 2)"
    Is 'hint once'      (Run done)        "$arrow c"
    Run undo | Out-Null
    Is 'age survives'   (Run list)        '1. b|  4w|2. c|  4w|3. dd|  4w'

    # --- step 7: log ---
    Reset
    [IO.File]::WriteAllLines("$dir\done.txt", [string[]]('2026-11-02 gym', '2026-11-03 missed: gym', '2026-11-04 gym // legs', '2026-11-05 gym', '2026-11-06 blog: post one', '2026-10-01 gym', '2026-11-09 dropped: blog: idea'))
    Is 'log name'      (Run log gym)     'gym|last 4 weeks: 3 of 4 days (75%), streak 2|x . x x'
    Is 'log prefix'    (Run log blog)    'blog: 1 done (0 this week), last on 2026-11-06, 1 dropped'
    Is 'log unknown'   (Run log hours)   "nothing logged for 'hours'."
    Is 'log no park'   (File todo.txt)   ''
    Is 'log part'      (Run log gy)      'gym|last 4 weeks: 3 of 4 days (75%), streak 2|x . x x'
    Is 'log colon'     (Run g blog:)     'blog: 1 done (0 this week), last on 2026-11-06, 1 dropped'
    Is 'log several'   (Run log g)       '  gym  4 done, 1 missed|  blog  1 done, 0 missed|Several match. Use one of these names: t log <name>'
    Is 'log week'      (Run log)         'this week: 0 done, 1 dropped, 0 missed'
    Reset -Routine 'weekdays 14:00 timesheet', 'weekdays 07:00 morning:', '  stretch', '  shower', 'weekends 10:00 gym', 'tomorrow 10:00 one off'
    [IO.File]::WriteAllLines("$dir\done.txt", [string[]]('2026-11-05 timesheet', '2026-11-06 missed: timesheet', '2026-11-06 morning: stretch', '2026-11-06 missed: morning: shower', '2026-11-05 morning: stretch', '2026-11-05 morning: shower'))
    Is 'log routine'   (Run log timesheet)   'timesheet  weekdays at 14:00|last 4 weeks: 1 of 2 days (50%), streak 0|x .'
    Is 'log steps'     (Run log morning)     'morning  weekdays at 07:00|last 4 weeks: 1 of 2 days (50%), streak 0|x .'
    Is 'log loose'     (Run log morning routine)   'morning  weekdays at 07:00|last 4 weeks: 1 of 2 days (50%), streak 0|x .'
    Is 'log none'      (Run log zzz)         "nothing logged for 'zzz'.|routine names: timesheet, morning, gym"
    Is 'log empty'     (Run log gym)         'gym  weekends at 10:00|nothing logged in the last 4 weeks.'
    Is 'log overview'  (Run log)             'this week: 0 done, 0 dropped, 0 missed|routine, last 4 weeks:|  timesheet  1 of 2 days  50%  streak 0|  morning    1 of 2 days  50%  streak 0|  gym        nothing logged yet'
    # --- parent blocks ---
    Reset '  orphan', 'Report:', "`tDraft // due monday", '- Review', '', '    Send', 'call dentist', 'Empty:', 'last'
    Is 'block read'     (Run)                 "$arrow orphan"
    Is 'read no write'  (File todo.txt)       "  orphan|Report:|`tDraft // due monday|- Review||    Send|call dentist|Empty:|last"
    Is 'block list'     (Run list)            '1. orphan||   Report:|2.   Draft|  // due monday|3.   Review||4.   Send||5. call dentist||6. last|'
    Run xx | Out-Null
    Is 'block written'  (File todo.txt)       'orphan|Report:|  Draft // due monday|  Review|  Send|call dentist|last|xx'
    Reset
    Run x: a | Out-Null; Run y | Out-Null; Run X: b | Out-Null
    Is 'block gathers'  (File todo.txt)       'x:|  a|  b|y'
    Run done | Out-Null
    Is 'header goes'    (Run done)            "x: all steps done.|$arrow y"
    Is 'header gone'    (File todo.txt)       'y'
    Reset 'call bob // re: invoice'
    Run z | Out-Null
    Is 'note no parent' (File todo.txt)       'call bob // re: invoice|z'
    # --- selection ---
    Reset 'p', 'Report:', '  Draft', '  Review', '  Send', 'q', 'Home:', '  bins', '  lawn'
    Is 'find'           (Run find LAW)        '   Home:|7.   lawn|'
    Is 'find none'      (Run f zzz)           "Nothing matches 'zzz'."
    Is 'find usage'     (Run find)            'Usage: t find <text>'
    Run skip 2 | Out-Null
    Is 'skip step'      (File todo.txt)       'p|Report:|  Review|  Send|  Draft|q|Home:|  bins|  lawn'
    Run skip 1, 6 | Out-Null
    Is 'skip batch'     (File todo.txt)       'Report:|  Review|  Send|  Draft|q|Home:|  lawn|  bins|p'
    Run undo | Out-Null
    Is 'batch one undo' (File todo.txt)       'p|Report:|  Review|  Send|  Draft|q|Home:|  bins|  lawn'
    Run skip 1 6 | Out-Null
    Run skip Report: | Out-Null
    Is 'skip parent'    (File todo.txt)       'q|Home:|  lawn|  bins|p|Report:|  Review|  Send|  Draft'
    Run now 3 | Out-Null
    Is 'now step'       (File todo.txt)       'Home:|  bins|  lawn|q|p|Report:|  Review|  Send|  Draft'
    Run now 4 7 | Out-Null
    Is 'now several'    (File todo.txt)       'p|Report:|  Draft|  Review|  Send|Home:|  bins|  lawn|q'
    Run now home: | Out-Null
    Is 'now parent'     (File todo.txt)       'Home:|  bins|  lawn|p|Report:|  Draft|  Review|  Send|q'
    Is 'no parent'      (Run done Nope:)      "No parent 'Nope'. See: t list"
    Is 'bad selection'  (Run del some text)   't del takes numbers or a Parent: (find them with: t find <text>)'
    Is 'unchanged'      (File todo.txt)       'Home:|  bins|  lawn|p|Report:|  Draft|  Review|  Send|q'
    Reset 'Solo:', '  one', 'z'
    Run skip | Out-Null
    Is 'skip last step' (File todo.txt)       'z|Solo:|  one'
    Run now Solo: two | Out-Null
    Is 'now new step'   (File todo.txt)       'Solo:|  two|  one|z'
    Answers 'y'
    Is 'done parent'    (Run done solo:)      "  Solo: two|  Solo: one|done: 2 tasks  (t undo to revert)|Solo: all steps done.|$arrow z"
    Run undo | Out-Null
    Is 'undo parent'    (File todo.txt)       'Solo:|  two|  one|z'
    Reset 'A:', '  x', '  y'
    Is 'skip nothing'   (Run skip A:)         'Nothing to move.'
    # --- edit and undo ---
    Reset 'call bank // ask fee', 'Report:', '  Draft'
    Is 'e note'         (Run e // by friday)       "$arrow call bank|  ask fee; by friday"
    Is 'e note n'       (Run e 2 // long one)      "#2: Report: Draft // long one|$arrow call bank|  ask fee; by friday"
    Is 'e reword'       (Run e 1 phone the bank)   "$arrow phone the bank|  ask fee; by friday"
    Is 'e reword n'     (Run e 2 Outline)          "#2: Report: Outline // long one|$arrow phone the bank|  ask fee; by friday"
    Run e 1 phone them // | Out-Null
    Is 'e clears'       (File todo.txt)            'phone them|Report:|  Outline // long one'
    Is 'e usage'        (Run e the report)         'Usage: t e | t e [n] // <note> | t e <n> <new text>'
    Is 'e bad number'   (Run e 9 x)                'No such number. See: t list'
    Is 'e dupe'         (Run e 1 Report: Outline)  'already on your list (#2).'
    Is 'e undo'         (Run undo)                 "undone: edit|$arrow phone the bank|  ask fee; by friday"
    Reset 'old one'
    Run new one | Out-Null
    At '2026-11-14 09:00'
    Run e 1 older one | Out-Null
    Is 'reword age'     (Run list)                 '1. older one|  5d|2. new one|  5d'
    if ($dir -notmatch ' ') {
        Reset 'a', 'b'
        [IO.File]::WriteAllLines("$dir\ed.cmd", [string[]]'@copy /y "%~dp0next.txt" %1 >nul')
        $env:VISUAL = $null; $env:EDITOR = "$dir\ed.cmd"
        [IO.File]::WriteAllLines("$dir\next.txt", [string[]]('  lost', 'Empty:', 'G:', "`tone", 'b'))
        Is 'editor'         (Run e)              "line 1 was indented under no parent; kept as a task|Empty: had no tasks; removed|$arrow lost"
        Is 'editor file'    (File todo.txt)      'lost|G:|  one|b'
        Is 'editor no log'  (File done.txt)      ''
        Is 'editor undo'    (Run undo)           "undone: edit|$arrow a"
        Is 'editor undone'  (File todo.txt)      'a|b'
        [IO.File]::WriteAllLines("$dir\next.txt", [string[]]('a', 'b'))
        Is 'editor same'    (Run e)              "$arrow a"
        Is 'nothing to undo' (Run undo)          'Nothing to undo.'
        [IO.File]::WriteAllLines("$dir\next.txt", [string[]]'weekdays 14:00 x')
        Is 'routine editor' (Run routine edit)   "$arrow a"
        Is 'routine file'   (File routine.txt)   'weekdays 14:00 x'
        Is 'routine undo'   (Run undo)           "undone: routine edit|$arrow a"
        Is 'routine undone' (File routine.txt)   ''
        $env:EDITOR = $null
    }
    # --- routine: schedule prefix ---
    Reset -Now '2026-11-09 05:00'
    Is 'sched new'    (Run daily 07:00 Stretch)                'routine: Stretch  (every day at 07:00)'
    Is 'sched file'   (File routine.txt)                       'daily 07:00 Stretch'
    Is 'not listed'   (File todo.txt)                          ''
    Is 'no time'      (Run daily review of sales)              'parked.'
    Is 'sched quoted' (Run 'daily 07:00 x')                    'parked.'
    Is 'remind'       (Run remind mon, thu 5pm call supplier)  'routine: call supplier  (mon,thu at 17:00, reminder)'
    Is 'full day'     (Run Monday 2pm standup)                 'routine: standup  (mon at 14:00)'
    Is 'range'        (Run mon-fri 9.30 mail)                  'routine: mail  (weekdays at 09:30)'
    Is 'wrap range'   (Run fri-mon 8am walk)                   'routine: walk  (sun,mon,fri,sat at 08:00)'
    Is 'everyday'     (Run everyday 11pm backup)               'routine: backup  (every day at 23:00)'
    Is 'typo hint'    (Run weekdys 14:00 x)                    "parked.|'weekdys' looks like 'weekdays'. For a routine entry: weekdays 09:00 <task>  (t undo)"
    Is 'not a time'   (Run 10 pushups daily)                   'parked.'
    Is 'stored'       (File routine.txt)                       'daily 07:00 Stretch|remind mon,thu 17:00 call supplier|monday 14:00 standup|mon-fri 09:30 mail|fri-mon 08:00 walk|everyday 23:00 backup'
    Answers 'weekdays 9am'
    Is 'ask when'     (Run remind Report: Send)                'routine: Report: Send  (weekdays at 09:00, reminder)'
    Answers 'sometime'
    Is 'bad when'     (Run remind call bob)                    'A routine entry needs days and a time, e.g. weekdays 09:00 or tomorrow 9am. Nothing was saved.'
    Answers 'vitamins'
    Is 'ask task'     (Run remind daily 08:00)                 'routine: vitamins  (every day at 08:00, reminder)'
    Answers 'stretch', 'plan the day', ''
    Is 'block new'    (Run remind weekdays 07:00 Morning:)     'routine: Morning:  (weekdays at 07:00, reminder)'
    Is 'block dupe'   (Run daily 06:00 morning:)               'already in your routine: morning. To add a step: t r morning: <step>'
    Is 'grow'         (Run r Morning: floss)                   'added to Morning: floss'
    Answers 'tea', 'floss', ''
    Is 'grow bulk'    (Run r morning:)                         'added to Morning: tea'
    Is 'grow none'    (Run r Nope: x)                          "No routine called 'Nope'. See: t r"
    Is 'grow single'  (Run r vitamins: x)                      'vitamins has no steps; edit it with: t r e'
    Is 'block listed' (((Run r).Split('|') | Select-Object -Last 6) -join '|')   '9. Morning:|  weekdays at 07:00, reminder|     stretch|     plan the day|     floss|     tea'
    Is 'block stored' (((File routine.txt).Split('|') | Select-Object -Last 5) -join '|')   'remind weekdays 07:00 Morning:|  stretch|  plan the day|  floss|  tea'
    Is 'r usage'      (Run r what now)                         'Usage: t r | t r e | t r x <numbers> | t r <Parent>: [<step>] | t r <numbers|Parent:> <when> <time>'
    Is 'r del text'   (Run r x stretch)                        'Usage: t r x <numbers>  (numbers from t r)'
    Answers 'y'
    Is 'r del'        (Run r x 1, 9)                           '  Stretch  every day at 07:00|  Morning:  weekdays at 07:00, reminder|  removed 2 from your routine.'
    Is 'r del file'   (File routine.txt)                       'remind mon,thu 17:00 call supplier|monday 14:00 standup|mon-fri 09:30 mail|fri-mon 08:00 walk|everyday 23:00 backup|remind weekdays 09:00 Report: Send|remind daily 08:00 vitamins'
    Is 'r undo'       (Run u)                                  "undone: routine del|$arrow daily review of sales"
    Is 'r undone'     ((File routine.txt).Split('|')[0])       'daily 07:00 Stretch'

    # --- routine: running ---
    Reset -Routine '# mine', 'weekdays  2pm   plain', 'remind weekdays 14:00 loud', 'weekdays 07:00 Morning:', '  stretch', "`tshower" -Now '2026-11-09 06:00'
    Run | Out-Null
    Is 'not yet'      (File todo.txt)       ''
    At '2026-11-09 07:30'; Run | Out-Null
    Is 'block due'    (File todo.txt)       'Morning:|  stretch|  shower'
    Run done | Out-Null
    At '2026-11-09 08:00'; Run | Out-Null
    Is 'no re-add'    (File todo.txt)       'Morning:|  shower'
    At '2026-11-09 14:30'
    Is 'remind names' (Run --remind)        'loud'
    Is 'timed on top' (File todo.txt)       'plain|loud|Morning:|  shower'
    Is 'read only'    (File routine.txt)    "# mine|weekdays  2pm   plain|remind weekdays 14:00 loud|weekdays 07:00 Morning:|  stretch|`tshower"
    At '2026-11-10 06:00'; Run | Out-Null
    Is 'step missed'  (File done.txt)       '2026-11-09 Morning: stretch|2026-11-09 missed: Morning: shower|2026-11-09 missed: plain|2026-11-09 missed: loud'
    Is 'new day'      (File todo.txt)       ''
    Run daily 23:00 late | Out-Null
    Is 'routine tidy' (File routine.txt)    '# mine|weekdays 14:00 plain|remind weekdays 14:00 loud|weekdays 07:00 Morning:|  stretch|  shower|daily 23:00 late'

    # --- routine: once ---
    Reset -Now '2026-11-09 18:00'
    Is 'once today'   (Run remind today 19:00 email XYZ)   'routine: email XYZ  (once, mon 9 nov at 19:00, reminder)'
    Is 'once stored'  (File routine.txt)                   'remind 2026-11-09 19:00 email XYZ'
    Is 'once past'    (Run today 5pm too late)             'That time has passed.'
    Is 'tomorrow'     (Run tomorrow 9am call bank)         'routine: call bank  (once, tue 10 nov at 09:00)'
    Is 'next day'     (Run remind next mon 10:00 review)   'routine: review  (once, mon 16 nov at 10:00, reminder)'
    Is 'a date'       (Run 2026-11-20 10:00 renew)         'routine: renew  (once, fri 20 nov at 10:00)'
    Is 'repeats'      (Run fri 17:00 weekly)               'routine: weekly  (fri at 17:00)'
    At '2026-11-09 19:05'
    Is 'once fires'   (Run --remind)                       'email XYZ'
    Is 'once listed'  (File todo.txt)                      'email XYZ'
    Is 'once removed' ((File routine.txt).Split('|')[0])   '2026-11-10 09:00 call bank'
    At '2026-11-11 08:00'; Run | Out-Null
    Is 'once stays'   (File todo.txt)                      'call bank|email XYZ'
    Is 'never missed' (File done.txt)                      ''
    Reset -Routine 'tomorrow 9am by hand' -Now '2026-11-09 18:00'
    (Get-Item "$dir\routine.txt").LastWriteTime = [datetime]'2026-11-09 12:00'
    Is 'hand written' (Run r)                              '1. by hand|  once, tue 10 nov at 09:00'
    Run daily 07:00 other | Out-Null
    Is 'hand stored'  (File routine.txt)                   '2026-11-10 09:00 by hand|daily 07:00 other'

    # --- routine: moving tasks in ---
    Reset 'p', 'Report:', '  Draft // n', '  Review', '  Send', 'q' -Now '2026-11-09 05:00'
    Is 'move one'     (Run r 1 weekdays 09:00)             "moved to your routine: p  (weekdays at 09:00)|$arrow Report: Draft|  (3 steps left)|  n"
    Is 'move files'   ((File todo.txt) + ' / ' + (File routine.txt))   'Report:|  Draft // n|  Review|  Send|q / weekdays 09:00 p'
    Is 'move undo'    (Run undo)                           "undone: routine|$arrow p"
    Is 'undo both'    ((File todo.txt) + ' / ' + (File routine.txt))   'p|Report:|  Draft // n|  Review|  Send|q / '
    Run r 2 3 remind daily 08:00 | Out-Null
    Is 'move steps'   ((File todo.txt) + ' / ' + (File routine.txt))   'p|Report:|  Send|q / remind daily 08:00 Report:|  Draft // n|  Review'
    Is 'move dupe'    (Run r Report: mon 10:00)            'already in your routine: Report. Nothing was changed.'
    Is 'move usage'   (Run r 1 weekdays)                   'Usage: t r | t r e | t r x <numbers> | t r <Parent>: [<step>] | t r <numbers|Parent:> <when> <time>'
    Reset 'p', 'Report:', '  Draft', '  Review' -Now '2026-11-09 05:00'
    Run r report: remind mon 10:00 | Out-Null
    Is 'move parent'  ((File todo.txt) + ' / ' + (File routine.txt))   'p / remind mon 10:00 Report:|  Draft|  Review'
    Is 'move once'    (Run r 1 tomorrow 9am)               'moved to your routine: p  (once, tue 10 nov at 09:00)|Nothing to do. Add one: t <task>'
    At '2026-11-10 09:30'; Run | Out-Null
    Is 'comes back'   (File todo.txt)                      'p'
} catch {
    # an error stops the run: without this the cases after it would be skipped silently
    $fail++; Write-Host "ERROR after $count cases: $_" -ForegroundColor Red
} finally {
    $env:EDITOR = $null
    Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
}
if ($fail) { Write-Host "$fail of $count failed ($($PSVersionTable.PSEdition))" -ForegroundColor Red; exit 1 }
Write-Host "$count passed ($($PSVersionTable.PSEdition))"
