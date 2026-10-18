# make-portable.ps1 - rebuild E:\idm\Store-Offline.cmd, the whole tool in ONE file.
#
#   Store-Offline.cmd  =  batch launcher  +  #STUB#  +  #PAYLOAD#
#
#   #STUB#     base64 of portable-stub.ps1 - the launcher cuts it out of itself,
#              drops it in %TEMP% and runs it.
#   #PAYLOAD#  base64 of gzip(json) holding every file of the tool as bytes.
#
# Run it after changing anything in the tool:
#     powershell -NoProfile -ExecutionPolicy Bypass -File E:\idm\build\make-portable.ps1
# The single file is then rewritten, and every byte in it is checked against the
# files next to it before the script reports success.
# Add -Sync to also refresh the copy under E:\hermes\hermes-offline in the same
# step (sync-hermes.ps1 next to this script does that, copy + hash by hash).
param(
    [switch]$Sync
)
$ErrorActionPreference = 'Stop'

$src   = Split-Path -Parent $PSScriptRoot
$stubP = Join-Path $PSScriptRoot 'portable-stub.ps1'
$out   = Join-Path $src 'Store-Offline.cmd'
$wrap  = 512    # width of a packed line (never parsed by cmd, but keep it sane)

# ------------------------------------------------------------------ the files
$rel = @()
foreach ($n in @('idm.cmd', 'idm-console.cmd', 'Store-Offline.ps1', 'Store-Gui.ps1')) { $rel += $n }
foreach ($f in (Get-ChildItem -LiteralPath (Join-Path $src 'lib') -File -Filter *.ps1 | Sort-Object Name)) {
    $rel += ('lib\' + $f.Name)
}
foreach ($f in (Get-ChildItem -LiteralPath $src -File -Filter *.txt)) {
    # the readme is found by its content, not by its name: other folders (the
    # synced copy) carry unrelated .txt files, and the build has to be identical
    # from both
    if ([IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8) -match '^Store-Offline') { $rel += $f.Name }
}

$items = New-Object System.Collections.Generic.List[object]
$ids   = New-Object System.Collections.Generic.List[string]
foreach ($r in $rel) {
    $p = Join-Path $src $r
    if (-not (Test-Path -LiteralPath $p)) { throw "missing source file: $p" }
    $bytes = [IO.File]::ReadAllBytes($p)
    $sha = (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash
    $ids.Add("$r|$sha")
    $items.Add([pscustomobject]@{ p = $r; d = [Convert]::ToBase64String($bytes) })
    Write-Host ("  pack  {0,-22} {1,8} B" -f $r, $bytes.Length)
}

$shaAll = [Security.Cryptography.SHA256]::Create()
$version = ([BitConverter]::ToString($shaAll.ComputeHash([Text.Encoding]::UTF8.GetBytes(($ids -join "`n")))) -replace '-', '').Substring(0, 24).ToLower()

# ------------------------------------------------------------- json + gzip
$json = [pscustomobject]@{ v = $version; f = [object[]]$items.ToArray() } | ConvertTo-Json -Compress -Depth 5
$jsonBytes = [Text.Encoding]::UTF8.GetBytes($json)

$ms = New-Object IO.MemoryStream
$gz = New-Object IO.Compression.GZipStream -ArgumentList $ms, ([IO.Compression.CompressionLevel]::Optimal), $true
$gz.Write($jsonBytes, 0, $jsonBytes.Length)
$gz.Dispose()
$packed = $ms.ToArray()
$ms.Dispose()

$payload = [Convert]::ToBase64String($packed)
$stubB64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($stubP))

Write-Host ""
Write-Host ("  json    {0,8} B" -f $jsonBytes.Length)
Write-Host ("  gzip    {0,8} B" -f $packed.Length)
Write-Host ("  payload {0,8} B base64" -f $payload.Length)
Write-Host ("  stub    {0,8} B base64" -f $stubB64.Length)

# ------------------------------------------------------- the tiny inlined boot
# One short -EncodedCommand line: it cuts #STUB# out of this very file, writes it
# in %TEMP% and runs it. Keeping it tiny is what avoids cmd's 8191-char limit.
$boot = '$ProgressPreference="SilentlyContinue";$c=[IO.File]::ReadAllText($env:STORE_SELF);$a=$c.IndexOf("#STUB#");$b=$c.IndexOf("#PAYLOAD#");if($a -lt 0 -or $b -le $a){exit 9};$p=Join-Path $env:TEMP "store-offline-unpack.ps1";$l=$c.Substring($a+6,$b-$a-6) -replace "[^A-Za-z0-9+/=]","";[IO.File]::WriteAllBytes($p,[Convert]::FromBase64String($l));& $p;exit $LASTEXITCODE'
$bootB64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($boot))
Write-Host ("  boot    {0,8} B base64 (one command line)" -f $bootB64.Length)

# --------------------------------------------------------------- the .cmd text
$head = @'
@echo off
setlocal
rem ===========================================================================
rem  Store-Offline - portable, single file.
rem
rem  The whole tool is inside this one file. The first run unpacks it to
rem  %LOCALAPPDATA%\StoreOffline\app and starts it from there, so nothing has to
rem  be installed and this file can live on a USB stick.
rem
rem  Double-click                        = the window
rem  Store-Offline.cmd -Search whatsapp  = the console, same options as usual
rem
rem  Unpacking never touches the downloads: they stay in
rem  %LOCALAPPDATA%\StoreOffline\app\StoreApps\<App>
rem ===========================================================================

set "STORE_SELF=%~f0"
if not defined LOCALAPPDATA set "LOCALAPPDATA=%TEMP%"
set "STORE_APP=%LOCALAPPDATA%\StoreOffline\app"

rem ---- find a Windows PowerShell, and fall back to PowerShell 7 when 5.1 is absent
set "PSEXE="
if exist "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" set "PSEXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not defined PSEXE for %%P in (powershell.exe) do if not "%%~$PATH:P"=="" set "PSEXE=%%~$PATH:P"
if not defined PSEXE for %%P in (pwsh.exe) do if not "%%~$PATH:P"=="" set "PSEXE=%%~$PATH:P"

if not defined PSEXE (
  echo.
  echo   No PowerShell was found on this machine.
  echo.
  echo   Windows PowerShell 5.1 ships with Windows 8 and newer. On anything
  echo   older, install Windows Management Framework 5.1 and run this again.
  echo.
  pause
  exit /b 1
)

rem ---- open this file, unpack what is packed at the bottom of it
"%PSEXE%" -NoProfile -ExecutionPolicy Bypass -EncodedCommand __BOOT__
if errorlevel 1 (
  echo.
  echo   Could not unpack the tool into "%STORE_APP%".
  echo.
  pause
  exit /b 1
)

if not exist "%STORE_APP%\idm.cmd" (
  echo.
  echo   The tool was not unpacked into "%STORE_APP%".
  echo.
  pause
  exit /b 1
)

rem ---- hand over to the unpacked tool (no arguments opens the window)
call "%STORE_APP%\idm.cmd" %*
exit /b %errorlevel%

rem ============ packed data - nothing to see below, do not edit ==============
exit /b 0
#STUB#
'@

$head = $head.Replace('__BOOT__', $bootB64)

$sb = New-Object System.Text.StringBuilder
[void]$sb.Append($head)
for ($i = 0; $i -lt $stubB64.Length; $i += $wrap) {
    $len = [Math]::Min($wrap, $stubB64.Length - $i)
    [void]$sb.AppendLine($stubB64.Substring($i, $len))
}
[void]$sb.AppendLine('#PAYLOAD#')
for ($i = 0; $i -lt $payload.Length; $i += $wrap) {
    $len = [Math]::Min($wrap, $payload.Length - $i)
    [void]$sb.AppendLine($payload.Substring($i, $len))
}

# ASCII + CRLF, always
$text = $sb.ToString() -replace "`r`n", "`n" -replace "`n", "`r`n"
[IO.File]::WriteAllText($out, $text, (New-Object Text.ASCIIEncoding))

$lines = @(Get-Content -LiteralPath $out)
$longest = ($lines | Measure-Object -Property Length -Maximum).Maximum
$info = Get-Item -LiteralPath $out
Write-Host ("`n  wrote {0}  ({1:N0} bytes, {2} lines, longest line {3})`n" -f $info.FullName, $info.Length, $lines.Count, $longest)

# ------------------------------------------------------------------- verify
$raw = [IO.File]::ReadAllText($out)
$sa = $raw.IndexOf('#STUB#'); $pa = $raw.IndexOf('#PAYLOAD#')
$stubBack = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($raw.Substring($sa + 6, $pa - $sa - 6) -replace '[^A-Za-z0-9+/=]', '')))
$bootBack = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String(([regex]::Match($raw, '-EncodedCommand ([A-Za-z0-9+/=]+)').Groups[1].Value)))
$b64 = $raw.Substring($raw.LastIndexOf('#PAYLOAD#') + '#PAYLOAD#'.Length) -replace '[^A-Za-z0-9+/=]', ''
$bytes = [Convert]::FromBase64String($b64)
$ms2 = New-Object IO.MemoryStream -ArgumentList (, $bytes)
$gz2 = New-Object IO.Compression.GZipStream -ArgumentList $ms2, ([IO.Compression.CompressionMode]::Decompress)
$sr2 = New-Object IO.StreamReader -ArgumentList $gz2, ([Text.Encoding]::UTF8)
$back = ($sr2.ReadToEnd() | ConvertFrom-Json)
$sr2.Dispose(); $gz2.Dispose(); $ms2.Dispose()

$bad = 0
foreach ($f in @($back.f)) {
    $target = Join-Path $src ([string]$f.p)
    $mine = [Convert]::FromBase64String([string]$f.d)
    $orig = [IO.File]::ReadAllBytes($target)
    if (($orig.Length -ne $mine.Length) -or (Compare-Object $orig $mine -SyncWindow 0)) {
        $bad++; Write-Host ("  MISMATCH {0}" -f $f.p) -ForegroundColor Red
    }
}
$okStub = ($stubBack -eq ((Get-Content -LiteralPath $stubP -Raw) -replace "`r`n", "`n"))
if (-not $okStub) { Write-Host '  MISMATCH stub source' -ForegroundColor Red; $bad++ }
if ($bootBack -ne $boot) { Write-Host '  MISMATCH boot command' -ForegroundColor Red; $bad++ }
if ($longest -gt 8000) { Write-Host ("  line too long for cmd: {0}" -f $longest) -ForegroundColor Red; $bad++ }
Write-Host ("  payload: {0} files, version {1}, stub+boot round-trip {2}, mismatches: {3}" -f @($back.f).Count, $back.v, $(if ($okStub) { 'ok' } else { 'FAIL' }), $bad)
if ($bad) { exit 1 }
Write-Host "  OK" -ForegroundColor Green

if ($Sync) {
    $syncP = Join-Path $PSScriptRoot 'sync-hermes.ps1'
    if (-not (Test-Path -LiteralPath $syncP)) {
        Write-Host ("  -Sync: {0} is missing" -f $syncP) -ForegroundColor Red
        exit 1
    }
    & powershell -NoProfile -ExecutionPolicy Bypass -File $syncP
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
