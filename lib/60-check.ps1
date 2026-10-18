# ----------------------------------------------------------------------------- # Update check # # Part of Store-Offline.ps1. Not runnable on its own: the entry script # dot-sources this file so that everything shares one scope. # ----------------------------------------------------------------------------- 
# ---------------------------------------------------------------- update check
# Compares a folder downloaded earlier with what the Store offers today. The
# version is taken from the file name (Name_Version_arch_pub.ext): the catalog's
# own Version field is stale for some products - EarTrumpet reports 1.5.3.0 while
# the package the Store hands out is 2.3.0.0 - so the name is the reliable one.
function Get-VersionFromName([string]$name) {
    $name = [string]$name
    # Name_1.2.3.4_arch__pub.ext     - packaged packages
    $mm = [regex]::Match($name, '_(\d+(?:\.\d+){1,3})[_.]')
    if ($mm.Success) { return $mm.Groups[1].Value }
    # Name_9_6_0_4097_arch.ext       - Win32 installers use underscores, not dots
    $mm = [regex]::Match($name, '_(\d+(?:_\d+){1,3})[_.]')
    if ($mm.Success) { return ($mm.Groups[1].Value -replace '_', '.') }
    $mm = [regex]::Match($name, '_(\d+)[_.]')
    if ($mm.Success) { return $mm.Groups[1].Value }
    return ''
}

function Compare-VersionText([string]$a, [string]$b) {
    if (-not $a -or -not $b) { return 0 }
    if ($a -eq $b) { return 0 }
    try { return ([version]$a).CompareTo([version]$b) } catch { }
    return [string]::Compare($a, $b, [StringComparison]::OrdinalIgnoreCase)
}

# the app file a manifest refers to; when the bundle was unpacked on download,
# extractedFrom names the bundle itself and that is the comparable one
function Get-ManifestAppName($m) {
    $n = [string]$m.extractedFrom
    if ($n) { return $n }
    return [string]$m.app
}

function Get-OfferedApp($productId, [string]$Arch) {
    $c = Get-StoreCatalog $productId
    if (-not $c) { return $null }

    if ($c.Kind -eq 'win32') {
        $best = $null
        $u = ''
        if ($c.Installer -and $c.Installer.Architectures) {
            $props = @($c.Installer.Architectures.PSObject.Properties)
            foreach ($a in (Get-ArchChain $Arch)) {
                $p = $props | Where-Object { $_.Name.ToLowerInvariant() -eq $a } | Select-Object -First 1
                if ($p) { $best = $p; break }
            }
            if (-not $best) { $best = $props | Select-Object -First 1 }
        }
        $n = ''
        if ($best) {
            # the Store's own CDN URL ends in a literal "/file" (the real name is
            # only in SourceUri), so the publisher's URL is the one to read
            $u = [string]$best.Value.SourceUri
            if (-not $u) { $u = [string]$best.Value.CDNUri }
            try { $n = [IO.Path]::GetFileName(([Uri]$u).AbsolutePath) } catch { }
            if (-not $n -or $n -notmatch '\.(exe|msi)$') {
                $safe = if ($c.Title) { $c.Title -replace '[\\/:*?"<>|]', '_' } else { $productId }
                $n = ('{0}-{1}.exe' -f $safe, $best.Name.ToLowerInvariant())
            }
        }
        return [pscustomobject]@{ Catalog = $c; App = $n; Url = $u }
    }

    $files = Get-StoreFilesAuto -ProductId $productId -WuCategoryId $(if ($c) { [string]$c.WuCategoryId } else { '' }) -NoFe3:$NoFe3 -Quiet
    $pl = Select-Packages -Files $files -Catalog $c -Arch $Arch
    return [pscustomobject]@{ Catalog = $c; App = $pl.App.Name; Url = $pl.App.Url }
}

function Test-FolderUpdate([string]$Folder) {
    $m = Read-Manifest $Folder
    if (-not $m) { return $null }

    $arch = [string]$m.architecture
    if (-not $arch) { $arch = Get-MachineArch }
    $local = Get-ManifestAppName $m

    $r = [pscustomobject]@{
        folder        = $Folder
        productId     = [string]$m.productId
        title         = [string]$m.title
        kind          = $(if ($m.kind) { [string]$m.kind } elseif ($local -match '\.(exe|msi)$') { 'win32' } else { 'packaged' })
        arch          = $arch
        extractedFrom = [string]$m.extractedFrom
        local         = $local
        localVersion  = (Get-VersionFromName $local)
        remote        = ''
        remoteVersion = ''
        state         = 'unknown'
        note          = ''
    }
    if (-not $r.productId) { $r.note = 'the manifest has no productId'; return $r }

    try {
        $cur = Get-OfferedApp $r.productId $arch
        if (-not $cur -or -not $cur.App) { $r.note = 'the Store offers no app package for this product'; return $r }
        $r.remote = $cur.App
        $r.remoteVersion = Get-VersionFromName $cur.App
        if ($r.kind -eq 'win32') {
            # the installer file name is just a file name; a different one means a
            # different build is being offered
            $r.state = $(if ($r.local -eq $r.remote) { 'current' } else { 'stale' })
        } else {
            $cmp = Compare-VersionText $r.localVersion $r.remoteVersion
            $r.state = $(if ($cmp -lt 0) { 'stale' } else { 'current' })
        }
    } catch {
        $r.note = $_.Exception.Message
    }
    return $r
}

function Invoke-Check {
    $folders = @()
    if ($Path) {
        $folders = @($Path)
    } elseif (Test-Path -LiteralPath $StoreRoot) {
        $folders = @(Get-ChildItem -LiteralPath $StoreRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'store-manifest.json') } |
            ForEach-Object { $_.FullName })
    }
    $folders = @($folders | ForEach-Object {
            if (Test-Path -LiteralPath $_) { (Resolve-Path -LiteralPath $_).Path } else { $_ }
        })

    if (-not $folders.Count) {
        Warn "nothing to check: no store-manifest.json under $StoreRoot (pass -Path <folder>)"
        return
    }

    $results = New-Object System.Collections.Generic.List[object]
    foreach ($f in $folders) {
        if (-not (Test-Path -LiteralPath (Join-Path $f 'store-manifest.json'))) {
            Warn "no store-manifest.json in $f - skipped"
            continue
        }
        Say "  checking $f" 'DarkGray'
        $r = Test-FolderUpdate $f
        if ($r) { $results.Add($r) }
    }

    if ($Json) {
        # NB: PowerShell 5.1's ConvertTo-Json throws "Argument types do not match"
        # when it is handed a generic List, so hand it a plain array.
        $arr = [object[]]$results.ToArray()
        if ($arr.Count -eq 0) { $arr = @() }
        ConvertTo-Json -InputObject $arr -Depth 4
        return
    }

    Say ''
    foreach ($r in $results) {
        $name = if ($r.title) { $r.title } else { $r.productId }
        if ($r.state -eq 'current') {
            Ok ("{0}  -  up to date  ({1})" -f $name, $r.localVersion)
        } elseif ($r.state -eq 'stale') {
            Warn ("{0}  -  UPDATE AVAILABLE" -f $name)
            Say ("        now   : {0}" -f $r.local) 'DarkGray'
            Say ("                version {0}" -f $r.localVersion) 'DarkGray'
            Say ("        Store : {0}" -f $r.remote) 'White'
            Say ("                version {0}" -f $r.remoteVersion) 'White'
            Say ("        folder: {0}" -f $r.folder) 'DarkGray'
        } else {
            Warn ("{0}  -  could not check{1}" -f $name, $(if ($r.note) { ": $($r.note)" } else { '' }))
        }
    }

    $stale = @($results | Where-Object { $_.state -eq 'stale' })
    $fresh = @($results | Where-Object { $_.state -eq 'current' })
    Say ''
    if (-not $stale.Count) {
        Ok ("all $($fresh.Count) downloaded app(s) are up to date.")
    } else {
        $names = @($stale | ForEach-Object { if ($_.title) { $_.title } else { $_.productId } })
        Warn ("$($stale.Count) app(s) have an update: " + ($names -join ', '))
        Say '  Download them with:  -Check -Download' 'Cyan'
    }

    if ($Download) {
        if (-not $stale.Count) { return }
        # download in a child process: that reuses the whole download path (resume,
        # hashing, the offline kit) instead of duplicating it here, and the queue is
        # sequential anyway
        $childPs = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        if (-not (Test-Path -LiteralPath $childPs)) { $childPs = 'powershell.exe' }
        foreach ($r in $stale) {
            Step "Downloading the new build of $($r.title)"
            $childArgs = @('-ProductId', $r.productId, '-Download', '-Force', '-OutDir', $r.folder, '-Arch', $r.arch)
            if ($r.extractedFrom) { $childArgs += '-Extract' }
            if ($Kit) { $childArgs += '-Kit' }
            & $childPs -NoProfile -ExecutionPolicy Bypass -File $SelfPath @childArgs
            if ($LASTEXITCODE -ne 0) { Warn "the download failed (exit $LASTEXITCODE)" }
        }
    }
}
