<#
.SYNOPSIS
    Store-Offline - download ANY Microsoft Store app for OFFLINE installation,
    together with the framework dependencies it needs, then install it.

.DESCRIPTION
    Two stages, usable together or separately:

      -Download   resolves the app's packages on Microsoft's own Store CDN,
                  downloads the app plus its framework dependencies (only the
                  architecture this machine needs), verifies every file with
                  SHA-1, and writes store-manifest.json next to them.

      -Install    installs a previously downloaded folder with Add-AppxPackage,
                  passing the framework packages through -DependencyPath.

      -All        download, then install, in one go.

    No third-party site is involved: the file list comes straight from the same
    public Windows Update endpoint (FE3) that every Windows PC talks to, which is
    what store.rg-adguard.net mirrors. No Entra ID account, no developer mode.
    Sideloading a Store-signed package works on a normal Windows 11 install.

.PARAMETER ProductId
    Store product id, e.g. 9NKSQGP7F2NH (WhatsApp).

.PARAMETER Url
    A Store link; the id is extracted from it, e.g.
    https://apps.microsoft.com/detail/9NKSQGP7F2NH

.PARAMETER Search
    Free-text search on the Store, to find a product id.

.PARAMETER Batch
    A text file with one product per line (an id or a Store link; empty lines
    and # comments are ignored). Every line is then downloaded one after the
    other, each exactly as a single run would. Same options as the single run
    apply (-Arch, -Extract, -NoDeps, -Encrypted, -Kit, -Force, -NoFe3); exit
    code 5 means some lines failed or were skipped.

.PARAMETER Arch
    x64 | x86 | arm64 | arm | all      (default: this machine)

.PARAMETER OutDir
    Where to download. Default: <script folder>\StoreApps\<AppName>

.PARAMETER Path
    Folder to install from (expects store-manifest.json in it).

.PARAMETER List
    Only show what would be downloaded - download nothing.

.PARAMETER NoDeps
    Download the app package only, skip framework dependencies.

.PARAMETER Extract
    Most apps ship as a .msixbundle / .appxbundle that holds every architecture
    (x64 + x86 + arm64). With -Extract only the package for -Arch is pulled out
    of the bundle; the other architectures are never transferred. -Arch already
    defaults to this machine, so on an x64 PC this fetches just the x64 package.
    Alias: -X64Only.

.PARAMETER Encrypted
    Allow the newest build even when Microsoft ships it encrypted (.emsix/.eappx).
    Such a package cannot be installed without a Store licence, so it is normally
    skipped in favour of the newest build that does install.

.PARAMETER NoFe3
    Take the file list from store.rg-adguard.net instead of asking Microsoft's own
    update service directly. Only needed when the direct route is blocked on this
    network (a filtering proxy, for instance); the direct route is the default and
    is the same data, one hop shorter.

.PARAMETER Force
    Re-download files that already exist, and force running apps to shut down
    during install.

.PARAMETER ProgressFile
    Write live progress as JSON to this path (used by the GUI front-end,
    Store-Gui.ps1). Harmless when unused.

.PARAMETER Json
    Machine-readable mode: with -Search it prints the results as JSON and
    exits; with -List it prints the resolved download plan as JSON and exits.
    Used by Store-Gui.ps1.

.PARAMETER Env
    Print which Windows, which PowerShell, which .NET and which HTTP engine were
    detected, then exit. Useful when the tool behaves differently on another PC.
    Add -Json for a machine-readable version of the same report.

.PARAMETER LegacyHttp
    Force the older HttpWebRequest engine instead of HttpClient. The tool picks
    this automatically on a Windows that has no HttpClient; the switch only
    exists to exercise that path on a modern machine.

.PARAMETER Kit
    Also write install.cmd + install.ps1 into the download folder, so the whole
    folder can be copied to another Windows machine (USB stick, network share,
    no internet) and installed there on its own. Combine with -Download and/or
    -Install, or use alone with -Path to (re)create the kit in an existing folder.

.PARAMETER Check
    Compare folders you downloaded earlier against the Store and report which
    ones are behind. With no -Path it walks every folder under StoreApps\; with
    -Path it checks just that one. Add -Download to fetch the newer builds into
    the same folders, and -Json for machine-readable output.

.EXAMPLE
    .\Store-Offline.ps1 -ProductId 9NKSQGP7F2NH -All

.EXAMPLE
    .\Store-Offline.ps1 -ProductId 9NKSQGP7F2NH -All -Extract

.EXAMPLE
    .\Store-Offline.ps1 -Search whatsapp -List

.EXAMPLE
    .\Store-Offline.ps1 -Batch C:\apps.txt -Extract
    (a text file with one product id or Store link per line; every app of the
     list is downloaded in turn)

.EXAMPLE
    .\Store-Offline.ps1 -Url https://apps.microsoft.com/detail/9N0DX20HK701 -Download

.EXAMPLE
    .\Store-Offline.ps1 -Install -Path .\StoreApps\WhatsApp
#>
[CmdletBinding()]
param(
    [string]$ProductId,
    [string]$Url,
    [string]$Search,
    [string]$Batch,
    [string]$Arch,
    [string]$OutDir,
    [string]$Path,
    [switch]$List,
    [switch]$Download,
    [switch]$Install,
    [switch]$All,
    [switch]$NoDeps,
    [Alias('X64Only')]
    [switch]$Extract,
    [switch]$Encrypted,
    [switch]$NoFe3,
    [switch]$Force,
    [string]$ProgressFile,
    [switch]$Json,
    [switch]$Env,
    [switch]$LegacyHttp,
    [switch]$Kit,
    [switch]$Check
)


# The help text and the parameters are above, and everything else lives in the
# lib folder next to this file, one file per concern, dot-sourced below so that
# they all share this script's scope. That keeps this file readable: the flow
# is here, the machinery is in lib\.
$ErrorActionPreference = 'Stop'

# Anything that reads a variable or a property that is not there is a bug, so
# let PowerShell say so instead of quietly working with $null.
Set-StrictMode -Version Latest

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $ScriptDir) { $ScriptDir = (Get-Location).Path }
# The path of this very file: the update check re-runs the tool on itself.
$SelfPath = $MyInvocation.MyCommand.Path
if (-not $SelfPath) { $SelfPath = Join-Path $ScriptDir 'Store-Offline.ps1' }
$StoreRoot = Join-Path $ScriptDir 'StoreApps'

$libDir = Join-Path $ScriptDir 'lib'
foreach ($part in @('10-core.ps1', '20-fe3.ps1', '30-plan.ps1', '40-net.ps1', '50-install.ps1', '60-check.ps1', '70-batch.ps1')) {
    $libFile = Join-Path $libDir $part
    if (-not (Test-Path -LiteralPath $libFile)) {
        Write-Host ''
        Write-Host ("  Store-Offline is incomplete: lib\$part is missing.") -ForegroundColor Red
        Write-Host ("  The lib folder belongs next to {0}" -f $ScriptDir) -ForegroundColor Red
        Write-Host ''
        exit 1
    }
    . $libFile
}

# ================================================================ main
# The flow: pick a product, work out the files, download them, then - if asked -
# install or package. Modes are handled in the order that makes sense to a
# caller: -Env, -Check, -Kit, -Install, then the lookup/download path.

# ---- -Env: what did the probe above find on this machine? Then stop.
if ($Env) {
    $r = Get-EnvReport
    if ($Json) {
        $r | ConvertTo-Json
        exit 0
    }
    Write-Host ''
    Write-Host '  Store-Offline - environment' -ForegroundColor Cyan
    Write-Host ''
    foreach ($p in $r.PSObject.Properties) {
        Write-Host ('    {0,-15} {1}' -f $p.Name, $p.Value)
    }
    Write-Host ''
    if (-not $script:CanInstall) {
        Write-Host '  Note: this Windows has no Add-AppxPackage, so -Install is unavailable.' -ForegroundColor Yellow
        Write-Host '        Files can still be downloaded for another PC.' -ForegroundColor Yellow
        Write-Host ''
    }
    exit 0
}

# ---- -Batch: download a whole list of apps, one after the other
if ($Batch) {
    if (-not (Test-Path -LiteralPath $Batch)) { Fail "batch file not found: $Batch"; exit 2 }
    Say "Store-Offline - batch download`n" 'Cyan'
    exit (Invoke-BatchFile -File $Batch)
}

Say "`nStore-Offline - Microsoft Store apps, downloaded and installed offline`n" 'Cyan'

$doDownload = ($Download -or $All) -and -not $List
$doInstall  = ($Install -or $All)

# ---- check mode: is what you downloaded already behind the Store?
if ($Check) {
    Invoke-Check
    Say "`nDone.`n" 'Green'
    exit 0
}

# ---- kit-only mode: (re)write install.cmd / install.ps1 for an existing folder
if ($Kit -and -not $Check -and -not $Download -and -not $All -and -not $Install -and -not $ProductId -and -not $Url -and -not $Search) {
    $folder = $Path
    if (-not $folder) { $folder = $OutDir }
    if (-not $folder) { Fail "pass -Path <folder> together with -Kit."; exit 2 }
    if (-not (Test-Path -LiteralPath $folder)) { Fail "folder not found: $folder"; exit 2 }
    Write-OfflineKit -Folder (Resolve-Path -LiteralPath $folder).Path
    Ok "offline kit written: install.cmd + install.ps1"
    Say "`nDone.`n" 'Green'
    exit 0
}

# ---- install-only mode (from a folder)
if ($Install -and -not $Download -and -not $All -and -not $ProductId -and -not $Url -and -not $Search) {
    $folder = $Path
    if (-not $folder) { $folder = $OutDir }
    if (-not $folder) { Fail "pass -Path <folder> (or -OutDir) for an install-only run."; exit 2 }
    if (-not (Test-Path -LiteralPath $folder)) { Fail "folder not found: $folder"; exit 2 }
    $folder = (Resolve-Path -LiteralPath $folder).Path
    Step "Installing from $folder"
    Set-Progress -State 'installing' -Message "Installing from $folder"
    Invoke-Install -Folder $folder -ForceShutdown:$Force
    if ($Kit) {
        Write-OfflineKit -Folder $folder
        Ok 'offline kit written: install.cmd + install.ps1'
    }
    Set-Progress -State 'done' -Message 'Finished'
    Say "`nDone.`n" 'Green'
    exit 0
}

$pid2 = Resolve-ProductId
$pid2 = $pid2.Trim()
Say "  Product id : $pid2"

if (-not $Arch) { $Arch = Get-MachineArch }
Say "  Architecture: $Arch  (this machine: $(Get-MachineArch))"

Set-Progress -State 'resolving' -Message 'Reading Store metadata'
Step "Reading Store metadata ..."
$cat = Get-StoreCatalog $pid2
if ($cat) {
    Say ("  title      : {0}" -f $cat.Title)
    Say ("  publisher  : {0}" -f $cat.Publisher)
    Say ("  version    : {0}" -f $cat.Version)
    Say ("  archs      : {0}" -f ($cat.Archs -join ','))
    if ($cat.Deps.Count) { Say ("  needs deps : {0}" -f ($cat.Deps -join ', ')) } else { Say "  needs deps : none" }
}

# ---- x64 is the target, but plenty of Store apps are x86-only
if ($Arch -eq 'x64' -and $cat -and $cat.Archs.Count -and ($cat.Archs -notcontains 'x64') -and ($cat.Archs -contains 'x86')) {
    Warn "this app has no x64 build - using x86 instead."
    $Arch = 'x86'
}

# ---- unpackaged Win32 app: the Store only links to the publisher's own installer.
#      Windows installs such an app by running it, never with Add-AppxPackage, so it
#      is downloaded and left for the user to run.
if ($cat -and $cat.Kind -eq 'win32') {
    $safe = if ($cat.Title) { $cat.Title -replace '[\\/:*?"<>|]', '_' } else { $pid2 }
    $dest = $OutDir
    if (-not $dest) { $dest = Join-Path $StoreRoot $safe }

    $offered = @()
    if ($cat.Installer -and $cat.Installer.Architectures) {
        foreach ($p in @($cat.Installer.Architectures.PSObject.Properties)) {
            $v = $p.Value
            $offered += [pscustomobject]@{
                Arch   = $p.Name.ToLowerInvariant()
                Url    = $(if ($v.CDNUri) { $v.CDNUri } else { $v.SourceUri })
                Hash   = [string]$v.Hash
                Args   = [string]$v.Args
                Source = [string]$v.SourceUri
            }
        }
    }
    if (-not $offered.Count) { Fail 'the Store lists no installer for this app.'; exit 3 }

    $pick = $null
    foreach ($a in (Get-ArchChain $Arch)) {
        $pick = $offered | Where-Object { $_.Arch -eq $a } | Select-Object -First 1
        if ($pick) { break }
    }
    if (-not $pick) { $pick = $offered[0] }
    if ($pick.Arch -ne $Arch -and $Arch -ne 'all') {
        Warn "this app has no '$Arch' installer - using '$($pick.Arch)' instead."
    }

    $name = ''
    try { $name = [IO.Path]::GetFileName(([Uri]$pick.Source).AbsolutePath) } catch { }
    # the listing hands the installer URL out percent-encoded
    # ("Docker%20Desktop%20Installer.exe"), and the name on disk has to be the
    # readable one
    try { $name = [Uri]::UnescapeDataString($name) } catch { }
    if (-not $name -or $name -notmatch '\.(exe|msi)$') { $name = ('{0}-{1}.exe' -f $safe, $pick.Arch) }

    $size = [long]0
    try { $size = Get-RemoteLength -Url $pick.Url } catch { }

    Say ''
    Say '  kind       : unpackaged Win32 app - the Store links to the publisher''s own installer' 'DarkGray'
    Say ''
    Say '  WILL DOWNLOAD' 'Cyan'
    Say ("    file : {0}" -f $name) 'White'
    Say ("           {0}   sha256={1}" -f (Mb $size), $pick.Hash) 'DarkGray'
    Say ("    from : {0}" -f $pick.Source) 'DarkGray'
    Say ("    into : {0}" -f $dest)

    if ($Json) {
        [pscustomobject]@{
            productId = $pid2
            title     = $cat.Title
            publisher = $cat.Publisher
            version   = $cat.Version
            arch      = $pick.Arch
            kind      = 'win32'
            extract   = $false
            icon      = $cat.Icon
            app       = $name
            appSize   = [long]$size
            resources = @()
            deps      = @()
            total     = [long]$size
            dest      = $dest
        } | ConvertTo-Json -Depth 5
        exit 0
    }

    if ($List) { Say "`n(-List: nothing downloaded.)`n" 'Yellow'; exit 0 }

    # this installer comes from the publisher's own CDN, not from FE3, so there is
    # no revision to renew a link with - but every job carries the same keys, or
    # StrictMode trips over the missing one the moment the download starts.
    $jobs = @([pscustomobject]@{ Name = $name; Url = $pick.Url; Range = $false; From = 0; To = 0; Sha1 = $pick.Hash; Size = $size; Arch = $pick.Arch; Rev = ''; SrcSha1 = ''; Src = '' })
    Step 'Downloading ...'
    $got = Invoke-Download -Jobs $jobs -Folder $dest
    $manifest = [pscustomobject]@{
        productId     = $pid2
        title         = $cat.Title
        publisher     = $cat.Publisher
        version       = $cat.Version
        architecture  = $pick.Arch
        kind          = 'win32'
        app           = $name
        extractedFrom = ''
        resources     = @()
        dependencies  = @()
        downloadPage  = $pick.Source
        silentArgs    = $pick.Args
        downloadedAt  = (Get-Date).ToString('s')
        files         = @($got | ForEach-Object { [pscustomobject]@{ name = $_.Name; sha1 = $_.Sha1; size = $_.Size } })
    }
    $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $dest 'store-manifest.json') -Encoding UTF8
    Ok 'manifest written: store-manifest.json'
    Say ''
    Say '  This is a normal Windows installer, not an MSIX package, so it is not' 'Yellow'
    Say '  installed for you. Run it whenever you like:' 'Yellow'
    Say ("      {0}" -f (Join-Path $dest $name)) 'White'
    if ($pick.Args) { Say ("  (the Store itself runs it with: {0})" -f $pick.Args) 'DarkGray' }
    if ($Kit) {
        Write-OfflineKit -Folder $dest
        Ok 'offline kit written: install.cmd + install.ps1'
    }
    Set-Progress -State 'done' -Message 'Finished'
    Say "`nDone.`n" 'Green'
    exit 0
}

Step "Resolving download links from the Microsoft Store CDN ..."
$files = @(Get-StoreFilesAuto -ProductId $pid2 -WuCategoryId $(if ($cat) { [string]$cat.WuCategoryId } else { '' }) -NoFe3:$NoFe3)

$plan = Select-Packages -Files $files -Catalog $cat -Arch $Arch -Encrypted:$Encrypted
if ($plan.Encrypted) {
    Warn ("the Store's newest build ({0}, {1}) is an ENCRYPTED package - Windows only installs those with a Store licence, so the newest normal build was taken instead." -f $plan.Encrypted.Name, (Mb $plan.Encrypted.Size))
    Say "        (add -Encrypted to download the encrypted build anyway.)" 'DarkGray'
}

$dest = $OutDir
if (-not $dest) {
    $safe = if ($cat -and $cat.Title) { $cat.Title -replace '[\\/:*?"<>|]', '_' } else { $pid2 }
    $dest = Join-Path $StoreRoot $safe
}

# ---- with -Extract, keep only this architecture out of the bundle
$appName = $plan.App.Name
$appSize = $plan.App.Size
$appSha1 = $plan.App.Sha1
$extractedFrom = ''
$extractJobs = New-Object System.Collections.Generic.List[object]
$resourceNames = @()

if ($Extract -and (Get-FileKind $plan.App.Name) -eq 'bundle') {
    Step "Reading the bundle index (a few KB - the bundle itself is not downloaded) ..."
    try {
        $bi = Get-BundleChild -Url $plan.App.Url -Arch $Arch
        if ($bi.Child -and $bi.Arch -ne $Arch) {
            Warn "this bundle has no '$Arch' package - using '$($bi.Arch)' instead."
            $Arch = $bi.Arch
            # the dependencies were picked for the other architecture - pick them again
            $plan = Select-Packages -Files $files -Catalog $cat -Arch $Arch -Encrypted:$Encrypted
        }
        $compressed = @(@($bi.Child) + @($bi.Resources) | Where-Object { $_ -and $_.Method -ne 0 })
        if (-not $bi.Child) {
            # A bundle whose only payload is a GUID-named package is how the Store
            # ships apps that stream their own content (Instagram, Netflix): there is
            # nothing architecture-specific to extract, and the file is a small stub.
            $stub = @($bi.Entries | Where-Object { $_.Name -match '^[0-9a-fA-F-]{36}\.(e?msix|e?appx)$' })
            if ($stub.Count) {
                Warn ("this is a partial/streaming package - a {0} stub; the app fetches its own content the first time it runs, so offline it will not be complete." -f (Mb $bi.Total))
            } else {
                Warn "the bundle contains no '$Arch' package - downloading the whole bundle instead."
            }
        } elseif ($compressed.Count) {
            Warn "some entries are deflate-compressed - downloading the whole bundle instead."
        } else {
            $extractedFrom = $plan.App.Name
            $keep = @($bi.Child) + @($bi.Resources)
            foreach ($k in $keep) {
                $ds = Get-DataStart -Url $plan.App.Url -HeaderAt $k.HeaderAt
                $extractJobs.Add([pscustomobject]@{ Name = $k.Name; Url = $plan.App.Url; Range = $true; From = $ds; To = ($ds + $k.Packed - 1); Sha1 = ''; Size = $k.Packed; Arch = $Arch; Rev = $plan.App.Rev; SrcSha1 = $plan.App.Sha1; Src = $plan.App.Name })
            }
            $appName = $bi.Child.Name
            $appSize = $bi.Child.Packed
            $appSha1 = ''
            $resourceNames = @($bi.Resources | ForEach-Object { $_.Name })
            $skipNames = @($bi.Entries | Where-Object { (Get-FileKind $_.Name) -eq 'package' -and $keep.Name -notcontains $_.Name })
            $skipped = [long](($skipNames | Measure-Object -Property Packed -Sum).Sum)
            Say ("  bundle   : {0}  ({1})" -f $plan.App.Name, (Mb $bi.Total))
            Say ("  keeping  : {0}  ({1})" -f $appName, (Mb $appSize)) 'Green'
            if ($resourceNames.Count) {
                Say ("             + {0} resource package(s), {1}" -f $resourceNames.Count, (Mb (($bi.Resources | Measure-Object -Property Packed -Sum).Sum))) 'Green'
            }
            Say ("  skipping : {0}" -f (Mb $skipped)) 'Green'
        }
    } catch {
        Warn "could not read the bundle index ($($_.Exception.Message)) - downloading the whole bundle instead."
    }
} elseif ($Extract) {
    if ((Get-FileKind $appName) -eq 'installer') {
        Say "  (this is a plain Windows installer from the Store - nothing to extract)" 'DarkGray'
    } else {
        Say "  (the Store already offers a single package for this app - nothing to extract)" 'DarkGray'
    }
}

# ---- the concrete download list
$dlJobs = New-Object System.Collections.Generic.List[object]
if ($extractJobs.Count) {
    foreach ($j in $extractJobs) { $dlJobs.Add($j) }
} else {
    $dlJobs.Add([pscustomobject]@{ Name = $appName; Url = $plan.App.Url; Range = $false; From = 0; To = 0; Sha1 = $appSha1; Size = $appSize; Arch = $Arch; Rev = $plan.App.Rev; SrcSha1 = $appSha1; Src = '' })
}
foreach ($d in $plan.Deps) {
    $dlJobs.Add([pscustomobject]@{ Name = $d.Name; Url = $d.Url; Range = $false; From = 0; To = 0; Sha1 = $d.Sha1; Size = $d.Size; Arch = $Arch; Rev = $d.Rev; SrcSha1 = $d.Sha1; Src = '' })
}

# ---- machine-readable plan (the GUI calls this with -List -Json)
if ($Json) {
    [pscustomobject]@{
        productId = $pid2
        title     = if ($cat) { $cat.Title } else { $pid2 }
        publisher = if ($cat) { $cat.Publisher } else { '' }
        version   = if ($cat) { $cat.Version } else { '' }
        arch      = $Arch
        kind      = 'packaged'
        extract   = [bool]$extractedFrom
        icon      = if ($cat) { $cat.Icon } else { '' }
        app       = $appName
        appSize   = [long]$appSize
        resources = @($resourceNames)
        deps      = @($plan.Deps | ForEach-Object { [pscustomobject]@{ name = $_.Name; size = [long]$_.Size } })
        total     = [long](($dlJobs | Measure-Object -Property Size -Sum).Sum)
        dest      = $dest
    } | ConvertTo-Json -Depth 5
    exit 0
}

Say ""
Say "  WILL DOWNLOAD" 'Cyan'
Say ("    app : {0}" -f $appName) 'White'
if ($extractedFrom) { Say ("          extracted from {0}" -f $extractedFrom) 'DarkGray' }
Say ("          {0}{1}" -f (Mb $appSize), $(if ($appSha1) { "   sha1=$appSha1" } else { '   (verified by signature)' })) 'DarkGray'
foreach ($r in $resourceNames) { Say ("    res : {0}" -f $r) 'White' }
foreach ($d in $plan.Deps) {
    Say ("    dep : {0}" -f $d.Name) 'White'
    Say ("          {0}   sha1={1}" -f (Mb $d.Size), $d.Sha1) 'DarkGray'
}
$tot = (($dlJobs | Measure-Object -Property Size -Sum).Sum)
Say ("    total: {0}" -f (Mb $tot)) 'Green'
Say ("    into : {0}" -f $dest)

if ($List) { Say "`n(-List: nothing downloaded.)`n" 'Yellow'; exit 0 }

if ($doDownload) {
    Step "Downloading ..."
    $got = Invoke-Download -Jobs $dlJobs -Folder $dest
    if ($extractedFrom) {
        Step "Checking the extracted package ..."
        Test-Package -Pkg (Join-Path $dest $appName)
    }
    $manifest = [pscustomobject]@{
        productId     = $pid2
        title         = if ($cat) { $cat.Title } else { $pid2 }
        publisher     = if ($cat) { $cat.Publisher } else { '' }
        version       = if ($cat) { $cat.Version } else { '' }
        architecture  = $Arch
        kind          = 'packaged'
        app           = $appName
        extractedFrom = $extractedFrom
        resources     = @($resourceNames)
        dependencies  = @($plan.Deps | ForEach-Object { $_.Name })
        silentArgs    = ''
        downloadPage  = ''
        downloadedAt  = (Get-Date).ToString('s')
        files         = @($got | ForEach-Object { [pscustomobject]@{ name = $_.Name; sha1 = $_.Sha1; size = $_.Size } })
    }
    $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $dest 'store-manifest.json') -Encoding UTF8
    Ok "manifest written: store-manifest.json"
    if ($Kit) {
        if (Test-EncryptedName $appName) {
            Warn 'this app is an ENCRYPTED package - the kit will need a Store licence on the other PC to install it.'
        }
        Write-OfflineKit -Folder $dest
        Ok "offline kit written: install.cmd + install.ps1"
    }
    Say "`n  Folder: $dest" 'Cyan'
    Say "  Install it with:" 'Cyan'
    Say "    .\Store-Offline.ps1 -Install -Path `"$dest`"" 'White'
    if ($Kit) { Say "  Or copy the folder to another PC and run install.cmd there." 'Cyan' }
}

if ($doInstall) {
    Set-Progress -State 'installing' -Message 'Installing'
    Step "Installing ..."
    Invoke-Install -Folder $dest -ForceShutdown:$Force
}

Set-Progress -State 'done' -Message 'Finished'
Say "`nDone.`n" 'Green'
