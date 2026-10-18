# ----------------------------------------------------------------------------- # Which files to fetch: app + dependencies # # Part of Store-Offline.ps1. Not runnable on its own: the entry script # dot-sources this file so that everything shares one scope. # ----------------------------------------------------------------------------- 
# ---------------------------------------------------------------- choose app + deps
function Select-Packages {
    param($Files, $Catalog, [string]$Arch, [switch]$Encrypted)

    # Everything the Store hands out that is worth keeping. .msixupload/.appxupload
    # are Store submission files (packages + crash symbols) and cannot be installed,
    # and .blockmap / .appxsym are only sidecars.
    $usable = @($Files | Where-Object {
            $k = Get-FileKind $_.Name
            $k -eq 'package' -or $k -eq 'bundle' -or $k -eq 'installer'
        })
    if ($usable.Count -eq 0) {
        $names = @($Files | ForEach-Object { $_.Name })
        $extra = if ($names.Count) { " (the Store only offered: $($names -join ', '))" } else { '' }
        throw "no installable packages in the Store response$extra"
    }

    # a listing can carry both a packaged app and a plain installer; the packaged
    # one is the real app, so the installers are dropped
    $packaged = @($usable | Where-Object { (Get-FileKind $_.Name) -ne 'installer' })
    if ($packaged.Count) { $usable = $packaged }

    # Encrypted builds are the current app, but they cannot be installed without a
    # Store licence, so carrying them to another machine is pointless. Leave them
    # out of the pick (unless -Encrypted) and remember the newest one, so the caller
    # can say which build was passed over instead of silently downloading an old one.
    $encSkipped = $null
    if (-not $Encrypted) {
        $enc = @($usable | Where-Object { Test-EncryptedName $_.Name })
        if ($enc.Count) {
            $encSkipped = @($enc | Sort-Object -Property @{ Expression = { Get-NameVersion $_.Name }; Descending = $true }, @{ Expression = { $_.Name }; Ascending = $true })[0]
            $rest = @($usable | Where-Object { -not (Test-EncryptedName $_.Name) })
            if ($rest.Count) { $usable = $rest } else { $encSkipped = $null }  # nothing else on offer
        }
    }

    $prefix = ''
    if ($Catalog -and $Catalog.Family) { $prefix = ($Catalog.Family -split '_')[0] }

    $appCand = @()
    $depCand = @()
    foreach ($f in $usable) {
        if ($prefix -and $f.Name.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { $appCand += $f }
        else { $depCand += $f }
    }
    # Fallback when the metadata was unavailable: the bundle (or the biggest package
    # of this architecture) is the app.
    if ($appCand.Count -eq 0) {
        $b = @($usable | Where-Object { (Get-FileKind $_.Name) -eq 'bundle' })
        if ($b.Count) {
            $appCand = $b
            $depCand = @($usable | Where-Object { $b -notcontains $_ })
        } else {
            # Nothing tells the app from its frameworks, so the names have to: keep
            # this architecture's files (x64 first, then x86) and the biggest is the
            # app. Sizes are fetched when the listing does not carry them.
            $mine = @(Select-ByArch -Items $usable -Arch $Arch)
            if (-not $mine.Count) { $mine = $usable }
            foreach ($f in $mine) {
                if ($f.Size -le 0) {
                    try { $f.Size = Get-RemoteLength -Url $f.Url } catch { }
                }
            }
            $sorted = @($mine | Sort-Object Size -Descending)
            $appCand = @($sorted[0])
            $depCand = @($usable | Where-Object { $appCand -notcontains $_ })
        }
    }

    # --- the app: prefer the universal bundle (installs on any arch), newest version
    # Get-FileKind, not a hand-written regex: a bare '\.(msixbundle|appxbundle)$'
    # misses the encrypted '.emsixbundle', which would hide the real current build.
    $bundles = @($appCand | Where-Object { (Get-FileKind $_.Name) -eq 'bundle' })
    if ($bundles.Count) {
        $app = @($bundles | Sort-Object -Property @{ Expression = { Get-NameVersion $_.Name }; Descending = $true }, @{ Expression = { $_.Name }; Ascending = $true })[0]
    } else {
        # @() matters: in PowerShell 5.1 a single [pscustomobject] has no .Count, so a
        # bare assignment looks empty and the code below would fall back to every
        # candidate - i.e. asking for x64 could hand back x86.
        $archOk = @(Select-ByArch -Items $appCand -Arch $Arch)
        if ($archOk.Count -eq 0) { $archOk = @($appCand) }
        $app = @($archOk | Sort-Object -Property `
                @{ Expression = { Get-NameVersion $_.Name }; Descending = $true }, `
                @{ Expression = { Get-ArchRank $_.Name $Arch }; Ascending = $true }, `
                @{ Expression = { $_.Name }; Ascending = $true })[0]
    }

    # --- dependencies: newest version per family, matching the requested architecture
    $deps = @()
    if (-not $NoDeps) {
        # The Store's list occasionally carries an older build of the app itself (it
        # shows up as a "dependency" for bundles). Windows refuses that with
        # 0x80073CF9 "Invalid dependencies were specified", so drop the app's own
        # package family outright.
        $appFamily = ($app.Name -split '_')[0]
        $matching = @(Select-ByArch -Items $depCand -Arch $Arch |
            Where-Object { ($_.Name -split '_')[0] -ne $appFamily })
        $fam = $matching | Group-Object { ($_.Name -split '_')[0] }
        foreach ($g in $fam) {
            $newest = ($g.Group | ForEach-Object { Get-NameVersion $_.Name } | Sort-Object -Descending | Select-Object -First 1)
            $deps += @($g.Group | Where-Object { (Get-NameVersion $_.Name) -eq $newest })
        }
    }

    # The same file can be listed under more than one revision (Microsoft keeps the
    # older update alive for a while), which used to put the very same package in
    # the download list twice. The name is the package's identity, so it settles it.
    $seenDep = New-Object System.Collections.Generic.HashSet[string]
    $deps = @($deps | Where-Object { $seenDep.Add($_.Name) })

    return [pscustomobject]@{ App = $app; Deps = $deps; All = $usable; Encrypted = $encSkipped }
}

