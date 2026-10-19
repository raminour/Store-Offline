# Copy the tool from its own folder to the synced copy under E:\hermes\hermes-offline
# and prove afterwards that every file is byte-identical.
# (The Arabic readme is found by its content, so no non-ASCII literal is needed
# here - a .ps1 without a BOM is read as ANSI by PowerShell 5.1.)
$ErrorActionPreference = 'Stop'
$src = Split-Path -Parent $PSScriptRoot
$dst = 'E:\hermes\hermes-offline'

$readme = (Get-ChildItem -LiteralPath $src -Filter '*.txt' -File |
    Where-Object { [IO.File]::ReadAllText($_.FullName, [Text.Encoding]::UTF8) -match '^Store-Offline' })
if (-not $readme) { throw "the readme was not found in $src" }
$files = @('Store-Offline.ps1', 'Store-Gui.ps1', 'idm.cmd', 'idm-console.cmd', 'Store-Offline.cmd') + $readme.Name
$dirs = @('lib', 'tests', 'build')

foreach ($d in $dirs) {
    $target = Join-Path $dst $d
    if (-not (Test-Path -LiteralPath $target)) { New-Item -ItemType Directory -Path $target -Force | Out-Null }
}
foreach ($f in $files) {
    Copy-Item -LiteralPath (Join-Path $src $f) -Destination (Join-Path $dst $f) -Force
    Write-Output ("  copied $f")
}
foreach ($d in $dirs) {
    foreach ($it in Get-ChildItem -LiteralPath (Join-Path $src $d) -Recurse -File) {
        $rel = $it.FullName.Substring((Join-Path $src $d).Length).TrimStart('\')
        $target = Join-Path (Join-Path $dst $d) $rel
        $parent = Split-Path -Parent $target
        if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        Copy-Item -LiteralPath $it.FullName -Destination $target -Force
        Write-Output ("  copied $d\$rel")
    }
}

Write-Output ''
Write-Output '---- verification ----'
$pairs = @()
foreach ($f in $files) { $pairs += , @((Join-Path $src $f), (Join-Path $dst $f), $f) }
foreach ($d in $dirs) {
    foreach ($it in Get-ChildItem -LiteralPath (Join-Path $src $d) -Recurse -File) {
        $rel = $it.FullName.Substring((Join-Path $src $d).Length).TrimStart('\')
        $pairs += , @($it.FullName, (Join-Path (Join-Path $dst $d) $rel), "$d\$rel")
    }
}
$bad = 0
foreach ($p in $pairs) {
    $h1 = (Get-FileHash -LiteralPath $p[0] -Algorithm SHA256).Hash
    $h2 = (Get-FileHash -LiteralPath $p[1] -Algorithm SHA256).Hash
    $ok = $h1 -eq $h2
    if (-not $ok) { $bad++ }
    $tag = 'MATCH'
    if (-not $ok) { $tag = 'DIFF' }
    Write-Output ("  [{0}] {1,-34} {2}  {3} bytes" -f $tag, $p[2], $h1.Substring(0, 12), (Get-Item -LiteralPath $p[0]).Length)
}
Write-Output ''
Write-Output ("files compared: {0}   mismatches: {1}" -f $pairs.Count, $bad)
