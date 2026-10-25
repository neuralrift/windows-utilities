# ThemeSwitch: dark at sunset, light at sunrise.
#   setup [-Lat -Lng]  save location (Windows location, else args) and register the task
#   auto               apply day/night if the phase changed, then schedule the next transition
#   toggle             flip light/dark manually
#   status             print computed sun times and state; changes nothing
#   uninstall          remove the scheduled task, saved settings and log; reset theme to light
param(
    [ValidateSet('setup', 'auto', 'toggle', 'status', 'uninstall')][string]$Mode = 'auto',
    [double]$Lat,
    [double]$Lng
)
$ErrorActionPreference = 'Stop'
$Version = '1.0.0'
$cfg   = 'HKCU:\Software\ThemeSwitch'
$theme = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
$log   = Join-Path $PSScriptRoot 'themeswitch.log'

# Appends a line and drops entries older than 7 days (lines start with an ISO timestamp).
function Write-Log([string]$text) {
    $cutoff = (Get-Date).AddDays(-7)
    $kept = @(Get-Content $log -ErrorAction SilentlyContinue | Where-Object {
        $d = [datetime]::MinValue
        $_.Length -ge 19 -and [datetime]::TryParse($_.Substring(0, 19), [ref]$d) -and $d -ge $cutoff
    })
    Set-Content $log ($kept + "$(Get-Date -Format s) $text")
}

function Get-SunTime([datetime]$date, [bool]$rise) {
    $r = [math]::PI / 180
    $lh = $script:lng / 15
    $t = $date.DayOfYear + (($(if ($rise) { 6 } else { 18 }) - $lh) / 24)
    $m = 0.9856 * $t - 3.289
    $l = ($m + 1.916 * [math]::Sin($m * $r) + 0.02 * [math]::Sin(2 * $m * $r) + 282.634) % 360
    $ra = (([math]::Atan(0.91764 * [math]::Tan($l * $r)) / $r % 360) + 360) % 360
    $ra = ($ra + [math]::Floor($l / 90) * 90 - [math]::Floor($ra / 90) * 90) / 15
    $sd = 0.39782 * [math]::Sin($l * $r)
    $cd = [math]::Cos([math]::Asin($sd))
    $ch = ([math]::Cos(90.833 * $r) - $sd * [math]::Sin($script:lat * $r)) / ($cd * [math]::Cos($script:lat * $r))
    $h = [math]::Acos($ch) / $r
    if ($rise) { $h = 360 - $h }
    $ut = ((($h / 15 + $ra - 0.06571 * $t - 6.622 - $lh) % 24) + 24) % 24
    [TimeZoneInfo]::ConvertTimeFromUtc(([datetime]::SpecifyKind($date.Date, 'Utc')).AddHours($ut), [TimeZoneInfo]::Local)
}

# Returns @{ Day = is it daytime now; Next = next sunrise/sunset }
function Get-State {
    $now = Get-Date
    $events = foreach ($d in -1..1) {
        $date = $now.Date.AddDays($d)
        @{ T = Get-SunTime $date $true;  Day = $true }
        @{ T = Get-SunTime $date $false; Day = $false }
    }
    $events = $events | Sort-Object { $_.T }
    @{
        Day  = ($events | Where-Object { $_.T -le $now } | Select-Object -Last 1).Day
        Next = ($events | Where-Object { $_.T -gt $now } | Select-Object -First 1).T
    }
}

function Set-Dark([bool]$dark) {
    $v = [int](-not $dark)
    Set-ItemProperty $theme AppsUseLightTheme $v -Type DWord
    Set-ItemProperty $theme SystemUsesLightTheme $v -Type DWord
    Add-Type -Namespace Win -Name Msg -MemberDefinition '[DllImport("user32.dll", CharSet = CharSet.Auto)] public static extern IntPtr SendMessageTimeout(IntPtr h, uint m, UIntPtr w, string l, uint f, uint t, out UIntPtr r);'
    $res = [UIntPtr]::Zero
    [Win.Msg]::SendMessageTimeout([IntPtr]0xFFFF, 0x1A, [UIntPtr]::Zero, 'ImmersiveColorSet', 2, 5000, [ref]$res) | Out-Null
}

# One task: a one-shot at the next transition plus logon/resume as catch-up points
# (session-unlock triggers need elevation, so they are not used).
function Register-Task([datetime]$next) {
    $ns = 'root/Microsoft/Windows/TaskScheduler'
    $resume = New-CimInstance -CimClass (Get-CimClass MSFT_TaskEventTrigger $ns) -ClientOnly -Property @{
        Enabled      = $true
        Subscription = '<QueryList><Query Id="0" Path="System"><Select Path="System">*[System[Provider[@Name=''Microsoft-Windows-Power-Troubleshooter''] and EventID=1]]</Select></Query></QueryList>'
    }
    $user = "$env:USERDOMAIN\$env:USERNAME"
    Register-ScheduledTask ThemeSwitch -Force `
        -Action (New-ScheduledTaskAction -Execute conhost.exe -Argument "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" auto") `
        -Trigger @((New-ScheduledTaskTrigger -Once -At $next), (New-ScheduledTaskTrigger -AtLogOn -User $user), $resume) `
        -Settings (New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries) `
        -Principal (New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited) | Out-Null
}

function Get-Location2 {
    Add-Type -AssemblyName System.Device
    $w = New-Object System.Device.Location.GeoCoordinateWatcher
    $w.Start()
    for ($i = 0; $i -lt 20 -and $w.Status -ne 'Ready'; $i++) { Start-Sleep -Milliseconds 500 }
    $p = $w.Position.Location
    $w.Stop()
    if (-not $p.IsUnknown) { $p }
}

try {
    if ($Mode -eq 'toggle') {
        $light = (Get-ItemProperty $theme).AppsUseLightTheme
        Set-Dark ($light -eq 1)
        $msg = "toggle -> $(if ($light -eq 1) { 'dark' } else { 'light' })"
    } elseif ($Mode -eq 'uninstall') {
        Unregister-ScheduledTask ThemeSwitch -Confirm:$false -ErrorAction SilentlyContinue
        Remove-Item $cfg -Recurse -ErrorAction SilentlyContinue
        Remove-Item $log -ErrorAction SilentlyContinue
        Set-Dark $false   # restore the default light theme
        'ThemeSwitch uninstalled; theme reset to light. You can delete this folder.'
    } else {
        if ($Mode -eq 'setup') {
            if (-not $PSBoundParameters.ContainsKey('Lat') -or -not $PSBoundParameters.ContainsKey('Lng')) {
                $loc = Get-Location2
                if (-not $loc) { throw 'Windows location unavailable; pass -Lat and -Lng.' }
                $Lat = $loc.Latitude; $Lng = $loc.Longitude
            }
            New-Item $cfg -Force | Out-Null
            Set-ItemProperty $cfg Lat $Lat.ToString([cultureinfo]::InvariantCulture)
            Set-ItemProperty $cfg Lng $Lng.ToString([cultureinfo]::InvariantCulture)
            Remove-ItemProperty $cfg Phase -ErrorAction SilentlyContinue
            "Location: $Lat, $Lng"
        } elseif (-not $PSBoundParameters.ContainsKey('Lat') -or -not $PSBoundParameters.ContainsKey('Lng')) {
            $c = Get-ItemProperty $cfg -ErrorAction SilentlyContinue
            if (-not $c) { throw 'No saved location; run setup first.' }
            $Lat = [double]::Parse($c.Lat, [cultureinfo]::InvariantCulture)
            $Lng = [double]::Parse($c.Lng, [cultureinfo]::InvariantCulture)
        }
        $lat = $Lat; $lng = $Lng
        $s = Get-State
        if ($Mode -eq 'status') {
            "ThemeSwitch v$Version  lat=$lat lng=$lng  now=$(if ($s.Day) { 'day' } else { 'night' })  next=$($s.Next)"
            "today: sunrise $(Get-SunTime (Get-Date) $true)  sunset $(Get-SunTime (Get-Date) $false)"
            return
        }
        $phase = (Get-ItemProperty $cfg -ErrorAction SilentlyContinue).Phase
        $want = if ($s.Day) { 'day' } else { 'night' }
        try {
            if ($phase -ne $want) {
                Set-Dark (-not $s.Day)
                Set-ItemProperty $cfg Phase $want
            }
        } finally {
            Register-Task $s.Next   # always re-arm, so a failed apply is retried at the next trigger
        }
        $msg = "$Mode v$Version phase=$want applied=$($phase -ne $want) next=$($s.Next)"
    }
    if ($msg) { Write-Log $msg }
} catch {
    Write-Log "$Mode ERROR $_"
    throw
}
