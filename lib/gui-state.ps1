# ----------------------------------------------------------------------------- # Window state and the child-process setup # # Part of Store-Gui.ps1. Not runnable on its own: the entry script dot-sources # this file so that everything shares one scope. # ----------------------------------------------------------------------------- 
$script:Ps1      = Join-Path $script:Root 'Store-Offline.ps1'
$script:Tmp      = Join-Path $env:LOCALAPPDATA 'Store-Offline-Gui'
$script:CapFile  = Join-Path $script:Tmp 'capture.json'

# The child processes must run a Windows PowerShell. On a machine that only has
# PowerShell 7, powershell.exe is missing, so fall back to pwsh.exe.
$script:Exe = Join-Path $PSHOME 'powershell.exe'
if (-not (Test-Path -LiteralPath $script:Exe)) { $script:Exe = '' }
if (-not $script:Exe) {
    $c = Get-Command 'powershell.exe' -ErrorAction SilentlyContinue
    if ($c) { $script:Exe = $c.Source }
}
if (-not $script:Exe) {
    $c = Get-Command 'pwsh.exe' -ErrorAction SilentlyContinue
    if ($c) { $script:Exe = $c.Source }
}
if (-not $script:Exe) { $script:Exe = 'powershell.exe' }
$script:Plan     = $null
$script:CanExtract = $true
$script:Jobs     = New-Object System.Collections.Generic.List[object]
$script:JobSeq   = 0
$script:Lang     = 'ar'
$script:Running  = $null
# app icons live here once they have been seen once, so they come back instantly
# (and still show when the network is off later in the day)
$script:IconDir  = Join-Path $script:Tmp 'icons'
New-Item -ItemType Directory -Force -Path $script:Tmp | Out-Null
New-Item -ItemType Directory -Force -Path $script:IconDir | Out-Null
