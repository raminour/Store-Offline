# Unpack stub for the single-file Store-Offline.cmd  (built by make-portable.ps1)
#
# Store-Offline.cmd carries two base64 blocks at the bottom of itself:
#   #STUB#     this file, so that the launcher can drop it in %TEMP% and run it
#   #PAYLOAD#  gzip(json) - every file of the tool, as bytes
# This stub cuts #PAYLOAD# out of the .cmd, unpacks the tool under
# %LOCALAPPDATA%\StoreOffline\app and stops. The .cmd then calls the unpacked
# idm.cmd, so the real tool never knows it was ever inside one file.
# Unpacking only touches .ps1/.cmd files and lib\ - downloads are never touched.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # no CLIXML progress noise on stderr

$self = $env:STORE_SELF
if (-not $self -or -not (Test-Path -LiteralPath $self)) {
    [Console]::Error.WriteLine('STORE_SELF points at nothing - this file must be run as a .cmd.')
    exit 1
}

$root = $env:LOCALAPPDATA
if (-not $root) { $root = $env:TEMP }
if (-not $root) { $root = [IO.Path]::GetTempPath() }
$homeDir = Join-Path $root 'StoreOffline'
$appDir  = Join-Path $homeDir 'app'
$stamp   = Join-Path $homeDir 'build.txt'

try {
    # ------------------------------------------------------- read the payload
    $marker = '#PAYLOAD#'
    $text = [IO.File]::ReadAllText($self)
    $at = $text.LastIndexOf($marker)
    if ($at -lt 0) {
        [Console]::Error.WriteLine('The payload section is missing from this file.')
        exit 1
    }
    $b64 = $text.Substring($at + $marker.Length) -replace '[^A-Za-z0-9+/=]', ''
    [byte[]]$packed = [Convert]::FromBase64String($b64)

    $ms = New-Object IO.MemoryStream -ArgumentList (, $packed)
    $gz = New-Object IO.Compression.GZipStream -ArgumentList $ms, ([IO.Compression.CompressionMode]::Decompress)
    $sr = New-Object IO.StreamReader -ArgumentList $gz, ([Text.Encoding]::UTF8)
    $json = $sr.ReadToEnd()
    $sr.Dispose(); $gz.Dispose(); $ms.Dispose()
    $pack = $json | ConvertFrom-Json

    $version = [string]$pack.v
    $files = @($pack.f)

    # ------------------------------------------------------- already unpacked?
    $current = ''
    if (Test-Path -LiteralPath $stamp) { $current = ([IO.File]::ReadAllText($stamp)).Trim() }
    $entry = Join-Path $appDir 'idm.cmd'
    $again = ($current -ne $version) -or (-not (Test-Path -LiteralPath $entry))

    if ($again) {
        if (-not (Test-Path -LiteralPath $homeDir)) {
            New-Item -ItemType Directory -Path $homeDir -Force | Out-Null
        }
        # drop the previous copy of the tool (never the downloads)
        if (Test-Path -LiteralPath $appDir) {
            foreach ($sub in @('lib')) {
                $p = Join-Path $appDir $sub
                if (Test-Path -LiteralPath $p) {
                    Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
            Get-ChildItem -LiteralPath $appDir -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -eq '.ps1' -or $_.Extension -eq '.cmd' } |
                Remove-Item -Force -ErrorAction SilentlyContinue
        }
        foreach ($f in $files) {
            $target = Join-Path $appDir ([string]$f.p)
            $dir = Split-Path -Parent $target
            if ($dir -and -not (Test-Path -LiteralPath $dir)) {
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
            }
            [IO.File]::WriteAllBytes($target, [Convert]::FromBase64String([string]$f.d))
        }
        [IO.File]::WriteAllText($stamp, $version)
    }
} catch {
    [Console]::Error.WriteLine('Could not unpack the tool: ' + $_.Exception.Message)
    exit 1
}

exit 0
