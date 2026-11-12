# Loaded by PowerShell the first time t is typed in a session (setup links this folder into Documents\...\Modules).
# The task folder is the one setup stored in HKCU\Software\OneTask.
$folder = (Get-ItemProperty -LiteralPath 'HKCU:\Software\OneTask' -ErrorAction SilentlyContinue).Folder
# Through the link, $PSScriptRoot is the link itself; load t.ps1 from the real folder so the reminder task and
# setup see the repo path
$here = Get-Item -LiteralPath $PSScriptRoot -Force
$real = if ($here.LinkType -eq 'Junction') { "$(@($here.Target)[0])" } else { $PSScriptRoot }
. (Join-Path $real 't.ps1') -Folder $folder
Export-ModuleMember -Function t
