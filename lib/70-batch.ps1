# ----------------------------------------------------------------------------- 
# Batch download: a plain text file, one product per line
#
# Part of Store-Offline.ps1. Not runnable on its own: the entry script
# dot-sources this file so that everything shares one scope.
# -----------------------------------------------------------------------------

# Every usable line of the batch file: empty lines and # comments disappear.
function Read-BatchLines([string]$File) {
    $lines = @()
    foreach ($raw in [IO.File]::ReadAllLines($File)) {
        $l = ([string]$raw).Trim()
        if (-not $l -or $l.StartsWith('#')) { continue }
        $lines += $l
    }
    return @($lines)
}

# one line -> a product id, or '' when the line is not one. Accepts a bare id
# or a Store link, exactly like the normal command line does.
function Get-BatchId([string]$Line) {
    if ($Line -match '^(9[0-9A-Z]{11}|XP[0-9A-Z]{8,})$') { return $Line.ToUpperInvariant() }
    if ($Line -match '^https?://') { return Get-IdFromUrl $Line }
    return ''
}

# the switches the child gets, so every app of the batch is downloaded the way
# the single run would have been
function Get-BatchChildArgs([string]$ProductId) {
    $a = @('-ProductId', $ProductId, '-Download')
    if ($Arch) { $a += @('-Arch', $Arch) }
    if ($Extract) { $a += '-Extract' }
    if ($NoDeps) { $a += '-NoDeps' }
    if ($Encrypted) { $a += '-Encrypted' }
    if ($NoFe3) { $a += '-NoFe3' }
    if ($Kit) { $a += '-Kit' }
    if ($Force) { $a += '-Force' }
    if ($LegacyHttp) { $a += '-LegacyHttp' }
    return @($a)
}

function Invoke-BatchFile([string]$File) {
    $lines = @(Read-BatchLines $File)
    if (-not $lines.Count) {
        Fail "nothing to download: $File has no product in it (one id or Store link per line)"
        return 3
    }

    Say ("  batch file : {0}" -f $File) 'White'
    Say ("  products   : {0}" -f $lines.Count) 'White'
    if ($Arch) { Say ("  architecture: {0}" -f $Arch) 'DarkGray' }
    Say ''

    $childPs = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $childPs)) { $childPs = 'powershell.exe' }

    $n = 0
    $ok = @()
    $bad = @()
    foreach ($l in $lines) {
        $n++
        $id = Get-BatchId $l
        if (-not $id) {
            Warn ("[{0}/{1}] not a product id or a Store link, skipped: '{2}'" -f $n, $lines.Count, $l)
            $bad += $l
            continue
        }
        Step ("[{0}/{1}] {2}" -f $n, $lines.Count, $id)
        # a child per app: that reuses the whole single-download path - the
        # resolve, the plan, resume, the hashes and the offline kit - instead
        # of duplicating any of it here, and each line speaks for itself on
        # screen exactly like a normal run.
        # Start-Process (not &) so the child writes to this console directly and
        # none of its text can leak into what this function hands back.
        $argStr = '-NoProfile -ExecutionPolicy Bypass -File "' + $SelfPath + '" ' +
            ((Get-BatchChildArgs $id) -join ' ')
        $child = Start-Process -FilePath $childPs -ArgumentList $argStr -Wait -NoNewWindow -PassThru
        if ($child.ExitCode -eq 0) {
            $ok += $id
        } else {
            Warn ("{0} failed (exit {1})" -f $id, $child.ExitCode)
            $bad += $id
        }
        Say ''
    }

    Say ''
    if ($ok.Count) {
        Ok ("{0} of {1} downloaded: {2}" -f $ok.Count, $lines.Count, ($ok -join ', '))
    }
    if ($bad.Count) {
        Warn ("{0} failed or skipped: {1}" -f $bad.Count, ($bad -join ', '))
        return 5
    }
    Ok 'the batch is complete.'
    return 0
}
