# ----------------------------------------------------------------------------- # Transport, the bundle index, resumable download # # Part of Store-Offline.ps1. Not runnable on its own: the entry script # dot-sources this file so that everything shares one scope. # ----------------------------------------------------------------------------- 
# ---------------------------------------------------------------- transport
# Every network read goes through Open-HttpStream / Close-HttpStream, so the
# engine works with whichever HTTP stack the machine actually has. HttpClient
# (.NET 4.5+, i.e. Windows 8 and later) is preferred; where it is absent the same
# job is done with HttpWebRequest, which has been in .NET since 2.0.
function Open-HttpStream {
    param([string]$Url, [long]$From = -1, [long]$To = -1, [int]$TimeoutSec = 180)

    if ($script:HasHttpClient) {
        $client = [System.Net.Http.HttpClient]::new()
        $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSec)
        $req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $Url)
        # some storefront hosts hand out a different response to an unknown agent
        [void]$req.Headers.TryAddWithoutValidation('User-Agent', $UA)
        if ($From -ge 0) {
            $rng = if ($To -ge 0) { "bytes=$From-$To" } else { "bytes=$From-" }
            $req.Headers.Range = [System.Net.Http.Headers.RangeHeaderValue]::Parse($rng)
        }
        $resp = $client.SendAsync($req, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        $total = [long]0
        $cr = $resp.Content.Headers.ContentRange
        if ($cr -and $cr.Length) { $total = [long]$cr.Length }
        elseif ($resp.Content.Headers.ContentLength) { $total = [long]$resp.Content.Headers.ContentLength }
        return [pscustomobject]@{
            Status      = [int]$resp.StatusCode
            TotalLength = $total
            Stream      = $resp.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
            Held        = $client
        }
    }

    $r = [System.Net.HttpWebRequest]::Create($Url)
    $r.Method = 'GET'
    $r.UserAgent = $UA
    $r.AllowAutoRedirect = $true
    $r.Timeout = $TimeoutSec * 1000
    $r.ReadWriteTimeout = $TimeoutSec * 1000
    try { $r.Proxy = [System.Net.WebRequest]::DefaultWebProxy } catch { }
    if ($From -ge 0) {
        if ($To -ge 0) { $r.AddRange($From, $To) } else { $r.AddRange($From) }
    }
    $resp = $null
    try { $resp = $r.GetResponse() } catch [System.Net.WebException] {
        # an error still carries a response object, and its headers are useful
        if ($_.Exception.Response) { $resp = $_.Exception.Response } else { throw }
    }
    $total = [long]0
    $cr = [string]$resp.Headers['Content-Range']
    if ($cr -match '/(\d+)\s*$') { $total = [long]$matches[1] }
    elseif ($resp.ContentLength -ge 0) { $total = [long]$resp.ContentLength }
    return [pscustomobject]@{
        Status      = [int]$resp.StatusCode
        TotalLength = $total
        Stream      = $resp.GetResponseStream()
        Held        = $resp
    }
}

function Close-HttpStream($h) {
    if (-not $h) { return }
    try { if ($h.Stream) { $h.Stream.Dispose() } } catch { }
    try { if ($h.Held) { $h.Held.Dispose() } } catch { }
}

# Stream.CopyTo only exists from .NET 4.0, so read in a loop instead
function Read-AllBytes($stream) {
    $ms = New-Object IO.MemoryStream
    try {
        $buf = New-Object byte[] 65536
        while ($true) {
            $n = $stream.Read($buf, 0, $buf.Length)
            if ($n -le 0) { break }
            $ms.Write($buf, 0, $n)
        }
        return , $ms.ToArray()
    } finally { $ms.Dispose() }
}

# ---------------------------------------------------------------- bundle index (read the ZIP remotely)
# An .msixbundle / .appxbundle is an ordinary, uncompressed ZIP. Its central
# directory lists every child package with the exact byte range, so the wanted
# architecture can be pulled out with Range requests and the other ones are
# never transferred at all.
function U16($b, $o) { return [int]$b[$o] -bor ([int]$b[$o + 1] -shl 8) }
function U32($b, $o) { return [long]$b[$o] -bor ([long]$b[$o + 1] -shl 8) -bor ([long]$b[$o + 2] -shl 16) -bor ([long]$b[$o + 3] -shl 24) }
function U64($b, $o) { return (U32 $b $o) + ((U32 $b ($o + 4)) * 4294967296) }

function Get-HttpRange {
    param([string]$Url, [long]$From, [long]$To)
    $h = Open-HttpStream -Url $Url -From $From -To $To -TimeoutSec 180
    try {
        if ($h.Status -ne 206) { throw "server ignored Range (HTTP $($h.Status))" }
        return , (Read-AllBytes $h.Stream)
    } finally { Close-HttpStream $h }
}

function Get-RemoteLength {
    param([string]$Url)
    $h = Open-HttpStream -Url $Url -From 0 -To 0 -TimeoutSec 120
    try {
        if ($h.TotalLength -gt 0) { return $h.TotalLength }
        throw 'the server did not report the total length'
    } finally { Close-HttpStream $h }
}

function Get-ZipTailInfo($tail) {
    $eocd = -1
    for ($i = $tail.Length - 22; $i -ge 0; $i--) {
        if ($tail[$i] -eq 0x50 -and $tail[$i + 1] -eq 0x4B -and $tail[$i + 2] -eq 0x05 -and $tail[$i + 3] -eq 0x06) { $eocd = $i; break }
    }
    if ($eocd -lt 0) { throw 'no ZIP end-of-central-directory record (not a ZIP container?)' }
    $info = [pscustomobject]@{
        CdSize      = $(U32 $tail ($eocd + 12))
        CdOffset    = $(U32 $tail ($eocd + 16))
        Count       = $(U16 $tail ($eocd + 10))
        Zip64Offset = [long]0
    }
    for ($i = $eocd - 20; $i -ge 0; $i--) {
        if ($tail[$i] -eq 0x50 -and $tail[$i + 1] -eq 0x4B -and $tail[$i + 2] -eq 0x06 -and $tail[$i + 3] -eq 0x07) {
            $info.Zip64Offset = U64 $tail ($i + 8); break
        }
    }
    return $info
}

function Merge-Zip64Eocd($info, $z64) {
    if ($z64 -and $z64.Length -ge 56 -and $z64[0] -eq 0x50 -and $z64[1] -eq 0x4B -and $z64[2] -eq 0x06 -and $z64[3] -eq 0x06) {
        $info.Count    = U64 $z64 32
        $info.CdSize   = U64 $z64 40
        $info.CdOffset = U64 $z64 48
    }
    return $info
}

function Parse-ZipEntries($cd) {
    $entries = New-Object System.Collections.Generic.List[object]
    $p = 0
    while ($p -lt $cd.Length - 46) {
        if (-not ($cd[$p] -eq 0x50 -and $cd[$p + 1] -eq 0x4B -and $cd[$p + 2] -eq 0x01 -and $cd[$p + 3] -eq 0x02)) { break }
        $method = U16 $cd ($p + 10)
        $cSize  = U32 $cd ($p + 20)
        $uSize  = U32 $cd ($p + 24)
        $nLen   = U16 $cd ($p + 28)
        $eLen   = U16 $cd ($p + 30)
        $cLen   = U16 $cd ($p + 32)
        $lho    = U32 $cd ($p + 42)
        $name   = [Text.Encoding]::UTF8.GetString($cd, $p + 46, $nLen)

        # ZIP64 extra field (id 0x0001) carries the real values when a 32-bit field is 0xFFFFFFFF
        $ex = $p + 46 + $nLen
        $exEnd = $ex + $eLen
        while ($ex -lt $exEnd) {
            $hid = U16 $cd $ex
            $hsz = U16 $cd ($ex + 2)
            $f = $ex + 4
            if ($hid -eq 0x0001) {
                if ($uSize -eq 0xFFFFFFFF) { $uSize = U64 $cd $f; $f += 8 }
                if ($cSize -eq 0xFFFFFFFF) { $cSize = U64 $cd $f; $f += 8 }
                if ($lho   -eq 0xFFFFFFFF) { $lho   = U64 $cd $f; $f += 8 }
            }
            $ex += 4 + $hsz
        }
        $entries.Add([pscustomobject]@{
            Name     = $name
            Method   = $method      # 0 = stored (raw bytes), 8 = deflate
            Packed   = $cSize
            Raw      = $uSize
            HeaderAt = $lho
        })
        $p = $p + 46 + $nLen + $eLen + $cLen
    }
    return $entries
}

function Get-DataStart {
    param([string]$Url, [long]$HeaderAt)
    $h = Get-HttpRange -Url $Url -From $HeaderAt -To ($HeaderAt + 300)
    if (-not ($h[0] -eq 0x50 -and $h[1] -eq 0x4B -and $h[2] -eq 0x03 -and $h[3] -eq 0x04)) {
        throw "no local file header at offset $HeaderAt"
    }
    return ($HeaderAt + 30 + (U16 $h 26) + (U16 $h 28))
}

function Get-BundleChild {
    param([string]$Url, [string]$Arch)

    $total = Get-RemoteLength -Url $Url
    $tailLen = [Math]::Min([long]262144, $total)
    $tailInfo = Get-ZipTailInfo (Get-HttpRange -Url $Url -From ($total - $tailLen) -To ($total - 1))
    if ($tailInfo.Zip64Offset -gt 0) {
        $tailInfo = Merge-Zip64Eocd $tailInfo (Get-HttpRange -Url $Url -From $tailInfo.Zip64Offset -To ($tailInfo.Zip64Offset + 99))
    }
    $entries = Parse-ZipEntries (Get-HttpRange -Url $Url -From $tailInfo.CdOffset -To ($tailInfo.CdOffset + $tailInfo.CdSize - 1))

    # Get-FileKind rather than a plain regex, so an encrypted bundle's .emsix child
    # is found as well.
    $pkgEntries = @($entries | Where-Object { (Get-FileKind $_.Name) -eq 'package' })

    # the wanted architecture: "_x64.msix", "_x64_.msix" or "-x64.msix".
    # x64 first, then x86, so an app that only ships x86 still extracts.
    $child = $null
    $usedArch = $Arch
    foreach ($a in (Get-ArchChain $Arch)) {
        $child = $pkgEntries | Where-Object { $_.Name -match ('_' + [regex]::Escape($a) + '[_.]') } | Select-Object -First 1
        if (-not $child) {
            $child = $pkgEntries | Where-Object { $_.Name -match ('-' + [regex]::Escape($a) + '\.(e?msix|e?appx)$') } | Select-Object -First 1
        }
        if ($child) { $usedArch = $a; break }
    }

    # architecture-neutral resource packages (scale-*, language packs): tiny, and
    # an app can render wrong without them, so they are kept as well.
    # Anything that names an architecture is NOT a neutral resource - that is how
    # the other slices of the bundle used to sneak into the download list.
    $resources = @()
    if ($child) {
        $resources = @($pkgEntries | Where-Object {
                if ($_.Name -eq $child.Name) { return $false }
                if (Get-NameArch $_.Name) { return $false }
                return $true
            })
    }

    return [pscustomobject]@{ Total = $total; Entries = $entries; Child = $child; Resources = $resources; Arch = $usedArch }
}

function Save-UrlRange {
    # -Sha1 and -Src identify which link (the bundle's) has to be renewed when it
    # runs out; the slice itself has no hash of its own to verify against.
    param([string]$Url, [long]$From, [long]$To, [string]$Dest, [string]$Label, [string]$Sha1, [string]$Rev, [string]$Src)

    $expected = $To - $From + 1
    $attempt = 0
    while ($true) {
        $attempt++
        if ($Rev -or $script:RgProduct) { $Url = Get-FreshUrl -Url $Url -Sha1 $Sha1 -Rev $Rev -Name $Src -Force:($attempt -gt 1) }
        $have = 0
        if (Test-Path -LiteralPath $Dest) { $have = (Get-Item -LiteralPath $Dest).Length }
        if ($have -ge $expected) { return }

        try {
            $h = Open-HttpStream -Url $Url -From ($From + $have) -To $To -TimeoutSec 1800
            try {
                if ($h.Status -ne 206) { throw "server ignored Range (HTTP $($h.Status))" }
                $stream = $h.Stream
                $mode = if ($have -gt 0) { [IO.FileMode]::Append } else { [IO.FileMode]::Create }
                $fs = [IO.File]::Open($Dest, $mode, [IO.FileAccess]::Write, [IO.FileShare]::Read)
                $buf = New-Object byte[] 262144
                $sw = [Diagnostics.Stopwatch]::StartNew()
                $tick = 0.0
                try {
                    while ($true) {
                        $n = $stream.Read($buf, 0, $buf.Length)
                        if ($n -le 0) { break }
                        $fs.Write($buf, 0, $n)
                        if ($sw.Elapsed.TotalSeconds - $tick -ge 1) {
                            $tick = $sw.Elapsed.TotalSeconds
                            $nowLen = (Get-Item -LiteralPath $Dest).Length
                            $pct = [int][Math]::Min(100, (100 * $nowLen / $expected))
                            $script:Pf.Rate = $nowLen / 1MB / $sw.Elapsed.TotalSeconds
                            Write-Progress -Activity "Downloading $Label" -Status ("{0:N1} / {1:N1} MB" -f ($nowLen / 1MB), ($expected / 1MB)) -PercentComplete $pct
                            Write-ProgressFile
                        }
                    }
                } finally { $fs.Dispose() }
            } finally { Close-HttpStream $h }
            Write-Progress -Activity "Downloading $Label" -Completed
        } catch {
            Write-Progress -Activity "Downloading $Label" -Completed
            if ($attempt -ge 30) { throw "range download failed after $attempt attempts: $($_.Exception.Message)" }
            Start-Sleep -Seconds 4
            continue
        }

        $len = 0
        if (Test-Path -LiteralPath $Dest) { $len = (Get-Item -LiteralPath $Dest).Length }
        if ($len -ge $expected) { return }
        if ($attempt -ge 30) { throw "range download incomplete after $attempt attempts: $Label" }
        Start-Sleep -Seconds 4
    }
}

function Test-Package {
    param([string]$Pkg)
    $h = (Get-HashHex -Path $Pkg -Alg SHA256).ToLowerInvariant()
    Ok ("SHA-256: {0}" -f $h)
    try {
        $sig = Get-AuthenticodeSignature -LiteralPath $Pkg
        $signer = if ($sig.SignerCertificate) { $sig.SignerCertificate.Subject } else { '<none>' }
        if ($sig.Status -eq 'Valid') { Ok ("signature valid - {0}" -f $signer) }
        else { Warn ("signature: {0} - {1}" -f $sig.Status, $sig.StatusMessage) }
    } catch { Warn "could not read the signature: $($_.Exception.Message)" }
}

# ---------------------------------------------------------------- download (HttpClient, resumable)
# BITS is unreliable on some machines (jobs sit in TransientError), so this
# uses HttpClient directly. Each file retries, resumes with a Range request,
# and is only accepted when the Store's own SHA-1 matches. The size shown in
# the listing is rounded, so the hash - not the size - decides "done".
function Save-UrlToFile {
    param([string]$Url, [string]$Dest, [string]$Sha1, [string]$Label, [string]$Rev)

    $attempt = 0
    while ($true) {
        $attempt++

        # the links are short-lived, so an expired one is swapped for a fresh one
        # and the transfer carries on from where it stopped
        if ($Rev -or $script:RgProduct) { $Url = Get-FreshUrl -Url $Url -Sha1 $Sha1 -Rev $Rev -Name $Label -Force:($attempt -gt 1) }

        if (Test-Path -LiteralPath $Dest) {
            if ($Sha1) {
                if (Test-Hash $Dest $Sha1) { return }
            } else {
                return
            }
        }

        $serverTotal = [long]0
        try {
            $have = 0
            if (Test-Path -LiteralPath $Dest) { $have = (Get-Item -LiteralPath $Dest).Length }

            $h = Open-HttpStream -Url $Url -From $(if ($have -gt 0) { $have } else { -1 }) -TimeoutSec 1800
            try {
                if ($h.Status -lt 200 -or $h.Status -ge 300) { throw "HTTP $($h.Status)" }
                $serverTotal = $h.TotalLength

                $append = ($have -gt 0 -and $h.Status -eq 206)
                $stream = $h.Stream
                $mode = if ($append) { [IO.FileMode]::Append } else { [IO.FileMode]::Create }
                $fs = [IO.File]::Open($Dest, $mode, [IO.FileAccess]::Write, [IO.FileShare]::Read)
                $buf = New-Object byte[] 262144
                $sw = [Diagnostics.Stopwatch]::StartNew()
                $tick = 0.0
                try {
                    while ($true) {
                        $n = $stream.Read($buf, 0, $buf.Length)
                        if ($n -le 0) { break }
                        $fs.Write($buf, 0, $n)
                        if ($sw.Elapsed.TotalSeconds - $tick -ge 1) {
                            $tick = $sw.Elapsed.TotalSeconds
                            $nowLen = (Get-Item -LiteralPath $Dest).Length
                            $pct = 0
                            if ($serverTotal -gt 0) { $pct = [int][Math]::Min(100, (100 * $nowLen / $serverTotal)) }
                            $rate = 0.0
                            if ($sw.Elapsed.TotalSeconds -gt 0) { $rate = ($nowLen - $have) / 1MB / $sw.Elapsed.TotalSeconds }
                            $script:Pf.Rate = $rate
                            Write-Progress -Activity "Downloading $Label" -Status ("{0:N1} MB   {1:N1} MB/s" -f ($nowLen / 1MB), $rate) -PercentComplete $pct
                            Write-ProgressFile
                        }
                }
            } finally {
                $fs.Dispose()
            }
            } finally { Close-HttpStream $h }
            Write-Progress -Activity "Downloading $Label" -Completed
        } catch {
            Write-Progress -Activity "Downloading $Label" -Completed
            if ($attempt -ge 30) { throw "download failed after $attempt attempts: $($_.Exception.Message)" }
            Start-Sleep -Seconds 4
            continue
        }

        if (Test-Path -LiteralPath $Dest) {
            $len = (Get-Item -LiteralPath $Dest).Length
            if ($Sha1) {
                if (Test-Hash $Dest $Sha1) { return }
                # complete as far as the server is concerned but the bytes are wrong -> start over
                if ($serverTotal -gt 0 -and $len -ge $serverTotal) {
                    Remove-Item -LiteralPath $Dest -Force -ErrorAction SilentlyContinue
                }
            } elseif ($serverTotal -le 0 -or $len -ge $serverTotal) {
                return
            }
        }

        if ($attempt -ge 30) { throw "download did not complete after $attempt attempts: $Label" }
        Start-Sleep -Seconds 4
    }
}

function Invoke-Download {
    param($Jobs, [string]$Folder)

    New-Item -ItemType Directory -Force -Path $Folder | Out-Null
    $total = ($Jobs | Measure-Object -Property Size -Sum).Sum
    $free = Get-FreeBytes $Folder
    $freeTxt = ''
    if ($free -ge 0) { $freeTxt = (" ({0} free)" -f (Mb $free)) }
    Say ("  $($Jobs.Count) file(s), ~$(Mb $total) total$freeTxt`n") 'White'
    if ($free -ge 0 -and $total -gt $free) {
        Warn ("not enough disk space on {0}: this download needs ~{1} but there is ~{2} free - it will stop when the disk fills up (free up space and run it again, it resumes)" -f $Folder, (Mb $total), (Mb $free))
    }

    $script:Pf.Folder = $Folder
    $script:Pf.Count = $Jobs.Count
    $script:Pf.Total = [long]$total
    Set-Progress -State 'downloading' -Message ''

    $done = New-Object System.Collections.Generic.List[object]
    $n = 0
    foreach ($j in $Jobs) {
        $n++
        # NB: PowerShell variable names are case-insensitive, so this must NOT be
        # called $dest - it would collide with a $Dest parameter.
        $target = Join-Path $Folder $j.Name

        # progress = bytes already on disk from finished jobs + whatever this one has so far
        $base = [long]0
        foreach ($d in $done) {
            $p = Join-Path $Folder $d.Name
            if (Test-Path -LiteralPath $p) { $base += (Get-Item -LiteralPath $p).Length }
        }
        $script:Pf.Base = $base
        $script:Pf.Index = $n
        $script:Pf.File = $j.Name
        Write-ProgressFile

        Say ("  [{0}/{1}] {2}   (~{3})" -f $n, $Jobs.Count, $j.Name, (Mb $j.Size)) 'White'

        $jRev = [string](Get-Prop $j 'Rev' '')

        if ($j.Range) {
            Save-UrlRange -Url $j.Url -From $j.From -To $j.To -Dest $target -Label $j.Name -Sha1 ([string](Get-Prop $j 'SrcSha1' '')) -Rev $jRev -Src ([string](Get-Prop $j 'Src' ''))
            Ok ("extracted the {0} package out of the bundle  ({1})" -f $j.Arch, (Mb (Get-Item -LiteralPath $target).Length))
            $done.Add($j)
            continue
        }

        if ((Test-Path -LiteralPath $target) -and -not $Force -and $j.Sha1 -and
            (Test-Hash $target $j.Sha1)) {
            Ok ("already downloaded and verified ({0})" -f (Mb (Get-Item -LiteralPath $target).Length))
            $done.Add($j)
            continue
        }

        Save-UrlToFile -Url $j.Url -Dest $target -Sha1 $j.Sha1 -Label $j.Name -Rev $jRev

        if ($j.Sha1) {
            if (-not (Test-Hash $target $j.Sha1)) {
                Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
                $what = if ($j.Sha1.Length -eq 64) { 'SHA-256' } else { 'SHA-1' }
                throw "$what mismatch for $($j.Name) - file removed, re-run to retry"
            }
            Ok ("verified  ({0})" -f (Mb (Get-Item -LiteralPath $target).Length))
        } else {
            Ok ("downloaded  ({0})" -f (Mb (Get-Item -LiteralPath $target).Length))
        }
        $done.Add($j)
    }
    return $done
}

