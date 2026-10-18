# ----------------------------------------------------------------------------- # Environment, text/arch helpers, Store metadata, the file list # # Part of Store-Offline.ps1. Not runnable on its own: the entry script # dot-sources this file so that everything shares one scope. # ----------------------------------------------------------------------------- 
# ---------------------------------------------------------------- environment
# The tool is meant to run on any Windows, so nothing here may assume a recent
# PowerShell or a recent .NET. Each capability is probed once, and the rest of
# the script adapts to what it found. `-Env` prints this and stops.
try {
    $protos = [Net.SecurityProtocolType]::Tls12
    # TLS 1.3 only exists on .NET 4.8+; ask for it when the enum knows the name
    if ([Enum]::GetNames([Net.SecurityProtocolType]) -contains 'Tls13') {
        $protos = $protos -bor [Net.SecurityProtocolType]::Tls13
    }
    [Net.ServicePointManager]::SecurityProtocol = $protos
} catch {
    # .NET 4.5 knows Tls12 but not Tls13; older frameworks only know Tls
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }
}

# HttpClient (System.Net.Http.dll) arrives with .NET 4.5, so it is present on
# Windows 8 and later. Where it is missing every request falls back to
# HttpWebRequest, which has shipped with .NET since 2.0.
$script:HasHttpClient = $false
try { Add-Type -AssemblyName System.Net.Http -ErrorAction Stop; $script:HasHttpClient = $true } catch { }
# -LegacyHttp forces the HttpWebRequest path, which is what an older Windows
# would take on its own. It exists so that path can be exercised on a modern box.
if ($LegacyHttp) { $script:HasHttpClient = $false }

# Get-FileHash arrived in PowerShell 4.0; below that the .NET crypto classes do
# exactly the same job, so fall back rather than refuse to run.
$script:HasFileHash = $null -ne (Get-Command Get-FileHash -ErrorAction SilentlyContinue)

# Which service the file list came from, so that a download link which runs out
# mid-transfer can be renewed from the same one: FE3 state (see Get-StoreFilesFe3)
# or, on the fallback, the product id. Both are set by Get-StoreFilesAuto.
$script:Fe3 = $null
$script:RgProduct = $null

# Add-AppxPackage exists on Windows 8 (AppX) and Windows 10 1809+ (MSIX). It is
# needed by -Install alone; downloading never depends on it.
$script:CanInstall = $null -ne (Get-Command Add-AppxPackage -ErrorAction SilentlyContinue)

# WPF is used by Store-Gui.ps1 only, and is absent from Server Core installs.
$script:HasWpf = $false
try { Add-Type -AssemblyName PresentationFramework -ErrorAction Stop; $script:HasWpf = $true } catch { }

# [pscustomobject], [ordered], Invoke-RestMethod and ConvertFrom-Json all arrived
# in PowerShell 3.0, so that is this script's floor. Anything older is told
# plainly rather than being left with a confusing error further down.
if ($PSVersionTable.PSVersion.Major -lt 3) {
    Write-Host ''
    Write-Host '  Store-Offline needs PowerShell 3.0 or newer.' -ForegroundColor Red
    Write-Host ("  This is PowerShell {0}." -f $PSVersionTable.PSVersion) -ForegroundColor Red
    Write-Host '  Run it from the Windows PowerShell that ships with Windows 8 or later,' -ForegroundColor Red
    Write-Host '  or install Windows Management Framework 5.1 (PowerShell 5.1).' -ForegroundColor Red
    Write-Host ''
    exit 1
}

# Is64BitOperatingSystem only exists from .NET 4.0; fall back to the environment
# variables on anything older so the report itself never becomes the failure.
function Test-Is64BitOs {
    try { return [Environment]::Is64BitOperatingSystem } catch {
        $a = $env:PROCESSOR_ARCHITECTURE
        if ($env:PROCESSOR_ARCHITEW6432) { $a = $env:PROCESSOR_ARCHITEW6432 }
        return ($a -eq 'AMD64' -or $a -eq 'IA64' -or $a -eq 'ARM64')
    }
}

function Get-EnvReport {
    $os = 'unrecognised build'
    $v = [Environment]::OSVersion.Version
    $map = @{
        '10.0' = 'Windows 10 / 11'
        '6.3'  = 'Windows 8.1'
        '6.2'  = 'Windows 8'
        '6.1'  = 'Windows 7'
        '6.0'  = 'Windows Vista'
        '5.2'  = 'Windows Server 2003 / XP x64'
        '5.1'  = 'Windows XP'
    }
    $k = '{0}.{1}' -f $v.Major, $v.Minor
    if ($map.ContainsKey($k)) { $os = $map[$k] }
    $net = 'unknown (no .NET 4 registry key)'
    foreach ($rk in @(
            'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full',
            'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Client')) {
        try {
            $rel = (Get-ItemProperty $rk -ErrorAction Stop).Version
            if ($rel) { $net = $rel; break }
        } catch { }
    }
    [pscustomobject]@{
        Windows        = "$os  (kernel $v)"
        OSArchitecture = if (Test-Is64BitOs) { '64-bit' } else { '32-bit' }
        Process        = if ([Environment]::Is64BitProcess) { '64-bit' } else { '32-bit' }
        PowerShell     = $PSVersionTable.PSVersion.ToString()
        Bridge         = if ($PSVersionTable.PSEdition) { $PSVersionTable.PSEdition } else { 'Desktop' }
        DotNet         = $net
        HttpEngine     = if ($script:HasHttpClient) { 'HttpClient' } else { 'HttpWebRequest (fallback)' }
        GetFileHash    = if ($script:HasFileHash) { 'yes' } else { 'no - using .NET crypto' }
        CanInstall     = if ($script:CanInstall) { 'yes (Add-AppxPackage)' } else { 'no - download only' }
        Wpf            = if ($script:HasWpf) { 'yes' } else { 'no - console only' }
    }
}

# -Json output is captured through a redirected stdout, so force UTF-8 there.
# The same is true when the GUI redirects the log to a file via -ProgressFile, so
# pin the encoding in both cases rather than relying on the console code page.
if ($Json -or $ProgressFile) { try { [Console]::OutputEncoding = New-Object Text.UTF8Encoding($false) } catch { } }

# NB: this file is dot-sourced, so a bare `return` here would only end the
# dot-source and silently leave the rest of the file undefined. The one early
# exit (-Env) therefore lives in the entry script, after everything is loaded.


$UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'
$UAStore = 'Windows-Update-Agent/10.0.10011.16384 Client-Protocol/2.40'

# In -Json mode stdout must carry nothing but the JSON, so the human-readable
# chatter is pushed to stderr, where the GUI front-end throws it away.
function Say($m, $c = 'Gray') {
    if ($Json) { [Console]::Error.WriteLine([string]$m); return }
    Write-Host $m -ForegroundColor $c
}

# Free bytes on the drive a path lives on, or -1 when it cannot be told
# (a UNC share, a path PowerShell names differently) - the caller then just
# says nothing about it.
function Get-FreeBytes([string]$Folder) {
    if (-not $Folder) { return [long]-1 }
    try {
        $full = if ([IO.Path]::IsPathRooted($Folder)) { [IO.Path]::GetFullPath($Folder) }
        else { [IO.Path]::GetFullPath((Join-Path (Get-Location).Path $Folder)) }
        $root = [IO.Path]::GetPathRoot($full)
        if (-not $root) { return [long]-1 }
        # a drive PSDrive knows by its letter; everything else (UNC shares) is unknown
        $d = Get-PSDrive -Name $root.TrimEnd('\', '/').TrimEnd(':') -ErrorAction SilentlyContinue
        if (-not $d -or -not $d.PSObject.Properties['Free']) { return [long]-1 }
        return [long]$d.Free
    } catch {
        return [long]-1
    }
}
function Ok($m)   { Say "  [ OK ]  $m" 'Green' }
function Warn($m) { Say "  [WARN]  $m" 'Yellow' }
function Fail($m) { Say "  [FAIL]  $m" 'Red' }
function Step($m) { Say "`n$m" 'Cyan' }
function Mb($b)   { return ('{0:N1} MB' -f ($b / 1MB)) }

# ---------------------------------------------------------------- live progress (for the GUI)
# Store-Gui.ps1 spawns this script and polls the JSON file below for the bar.
$script:Pf = [pscustomobject]@{
    State = 'idle'; Folder = ''; File = ''; Index = 0; Count = 0
    Base = [long]0; Total = [long]0; Message = ''; Rate = 0.0
}

function Set-Progress {
    param([string]$State, [string]$Message)
    if ($State) { $script:Pf.State = $State }
    if ($null -ne $Message) { $script:Pf.Message = $Message }
    Write-ProgressFile
}

function Write-ProgressFile {
    if (-not $ProgressFile) { return }
    try {
        $done = [long]$script:Pf.Base
        if ($script:Pf.File -and $script:Pf.Folder) {
            $p = Join-Path $script:Pf.Folder $script:Pf.File
            if (Test-Path -LiteralPath $p) { $done += (Get-Item -LiteralPath $p).Length }
        }
        $total = [long]$script:Pf.Total
        $pct = 0
        if ($total -gt 0) { $pct = [int][Math]::Min(100, [Math]::Floor(100 * $done / $total)) }
        # speed and time left, so the GUI can say how long the wait really is
        $rate = [double]$script:Pf.Rate
        $eta = 0
        if ($rate -gt 0.001 -and $total -gt $done) { $eta = [int](($total - $done) / ($rate * 1MB)) }
        $o = [ordered]@{
            state   = $script:Pf.State
            file    = $script:Pf.File
            index   = $script:Pf.Index
            count   = $script:Pf.Count
            done    = $done
            total   = $total
            percent = $pct
            rate    = [Math]::Round($rate, 2)
            eta     = $eta
            message = $script:Pf.Message
            updated = (Get-Date).ToString('HH:mm:ss')
        }
        [IO.File]::WriteAllText($ProgressFile, ($o | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
    } catch { }
}

# ---------------------------------------------------------------- arch helpers
function Get-MachineArch {
    $a = $env:PROCESSOR_ARCHITEW6432
    if (-not $a) { $a = $env:PROCESSOR_ARCHITECTURE }
    switch -Regex ($a.ToUpper()) {
        '^AMD64$' { return 'x64' }
        '^ARM64$' { return 'arm64' }
        '^X86$'   { return 'x86' }
        '^ARM$'   { return 'arm' }
        default   { return 'x64' }
    }
}

function Test-NameArch([string]$name, [string]$arch) {
    if ($arch -eq 'all') { return $true }
    return ($name -match ('_' + [regex]::Escape($arch) + '_'))
}

# What we ask for, and what we will accept instead when it is not offered.
# x64 is the machine default, so an app that only ships x86 should still work.
# On an ARM64 PC both x64 and x86 run under emulation, so they are honest
# fallbacks there rather than dead ends.
function Get-ArchChain([string]$arch) {
    switch ($arch) {
        'arm64' { return @('arm64', 'x64', 'x86') }
        'x64'   { return @('x64', 'x86') }
        'arm'   { return @('arm', 'x86') }
        default { return @($arch) }
    }
}

# The architecture a file name carries, '' when it carries none.
# Handles both the Store's "Name_1.0.0.0_x64_.msix" and the "Name-x64.msix"
# style that some bundles use, without matching the "arm" inside "harmony".
function Get-NameArch([string]$name) {
    foreach ($t in @('x64', 'x86', 'arm64', 'arm', 'neutral', 'anycpu')) {
        if ($name -match ('(?<![A-Za-z0-9])' + [regex]::Escape($t) + '(?![A-Za-z0-9])')) { return $t }
    }
    return ''
}

# Where a file sits in the wanted-architecture chain: 0 is the one we asked for,
# then the fallbacks, and anything else (or no architecture at all) last.
# Sort-Object is not stable in PowerShell 5.1, so choices between equal versions
# need a tie-breaker or they come out in an arbitrary order from run to run.
function Get-ArchRank([string]$name, [string]$arch) {
    $na = Get-NameArch $name
    if (-not $na) { return 99 }
    $chain = @(Get-ArchChain $arch)
    for ($i = 0; $i -lt $chain.Count; $i++) { if ($chain[$i] -eq $na) { return $i } }
    return $chain.Count
}

# Get-FileHash arrived in PowerShell 4.0. On anything older the .NET crypto
# classes return the very same hex digest, so there is no reason to require 4.0.
function Get-HashHex([string]$Path, [string]$Alg) {
    if ($script:HasFileHash) { return (Get-FileHash -LiteralPath $Path -Algorithm $Alg).Hash }
    $fs = [IO.File]::OpenRead($Path)
    try {
        if ($Alg -eq 'SHA256') { $sha = [Security.Cryptography.SHA256]::Create() }
        else { $sha = [Security.Cryptography.SHA1]::Create() }
        try {
            $hash = $sha.ComputeHash($fs)
            return (($hash | ForEach-Object { $_.ToString('x2') }) -join '')
        } finally { $sha.Dispose() }
    } finally { $fs.Dispose() }
}

# [System.Web.HttpUtility] lives in System.Web.dll, which is not part of .NET Core
# (PowerShell 7), so the handful of entities the Store pages actually use are
# decoded here instead of taking a dependency.
function Unescape-Html([string]$s) {
    if (-not $s) { return $s }
    $s = $s -replace '&lt;', '<'
    $s = $s -replace '&gt;', '>'
    $s = $s -replace '&quot;', '"'
    $s = $s -replace '&#39;', "'"
    $s = $s -replace '&apos;', "'"
    $s = $s -replace '&nbsp;', ' '
    $s = [regex]::Replace($s, '&#[xX]([0-9a-fA-F]+);', { param($m) [string][char][Convert]::ToInt32($m.Groups[1].Value, 16) })
    $s = [regex]::Replace($s, '&#(\d+);', { param($m) [string][char][int]$m.Groups[1].Value })
    # last, so that an escaped entity ("&amp;lt;") does not turn into a real tag
    $s = $s -replace '&amp;', '&'
    return $s
}

# The Store lists a SHA-1 (40 hex) for packaged apps and a SHA-256 (64 hex) for
# the plain .exe/.msi installers it hands out for unpackaged Win32 apps, so the
# algorithm is picked from the length of the hash we were given.
function Test-Hash([string]$Path, [string]$Expected) {
    if (-not $Expected -or -not (Test-Path -LiteralPath $Path)) { return $false }
    $alg = switch ($Expected.Length) {
        64 { 'SHA256' }
        40 { 'SHA1' }
        default { return $false }
    }
    try { return ((Get-HashHex -Path $Path -Alg $alg) -ieq $Expected) }
    catch { return $false }
}

# Set-StrictMode turns reading something that is not there into an error, and the
# data this tool reads is not all ours: store-manifest.json was written by whatever
# build did the download, and Microsoft's XML carries optional bits. Read those
# through here and a missing one comes back as $null (or as the given default).
function Get-Prop($Object, [string]$Name, $Default = $null) {
    if ($null -eq $Object) { return $Default }
    $p = $Object.PSObject.Properties[$Name]
    if ($p -and $null -ne $p.Value) { return $p.Value }
    return $Default
}

# store-manifest.json is the memory of a folder: which app, which dependencies,
# what was downloaded. Older builds did not write every key below, so the shape is
# completed here, once, for every reader (the install, the kit, the update check).
function Read-Manifest([string]$Folder) {
    $path = Join-Path $Folder 'store-manifest.json'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $m = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($k in @('productId', 'title', 'publisher', 'version', 'architecture', 'kind',
            'app', 'extractedFrom', 'downloadedAt', 'silentArgs', 'downloadPage')) {
        if (-not $m.PSObject.Properties[$k]) { $m | Add-Member -NotePropertyName $k -NotePropertyValue '' }
    }
    foreach ($k in @('resources', 'dependencies', 'files')) {
        if (-not $m.PSObject.Properties[$k]) { $m | Add-Member -NotePropertyName $k -NotePropertyValue @() }
    }
    return $m
}

# What the Store hands out, and what Windows can install from it.
#   .msix .appx                    single package, one architecture  -> installable
#   .msixbundle .appxbundle        several architectures in one ZIP  -> installable
#   .emsix .eappx .emsixbundle ..  the same, encrypted (Store licence needed)
#   .msixupload .appxupload        Store submission only (symbols)   -> not installable
#   .exe .msi                      unpackaged Win32 app              -> download only
function Get-FileKind([string]$name) {
    switch -Regex ($name) {
        '\.(msix|appx)$'                    { return 'package' }
        '\.(msixbundle|appxbundle)$'        { return 'bundle' }
        '\.(emsix|eappx)$'                  { return 'package' }
        '\.(emsixbundle|eappxbundle)$'      { return 'bundle' }
        '\.(msixupload|appxupload)$'        { return 'upload' }
        '\.(exe|msi)$'                      { return 'installer' }
        '\.(blockmap|appxsym)$'             { return 'sidecar' }
        default                             { return 'other' }
    }
}

# Microsoft also serves the same package encrypted - ".emsixbundle" and friends -
# for apps whose content is protected (Netflix, and other streaming apps). It is
# the real, current build, but Windows only installs it with a Store licence, so
# on its own it is not something you can carry to another machine. The Store
# listing quietly contains both, which is how an old unencrypted build used to get
# picked while the current one was thrown away as an unknown file type.
function Test-EncryptedName([string]$name) {
    return ($name -match '\.e(msix|appx)(bundle)?$')
}

# Pick the packages of the first architecture in the chain that has any.
function Select-ByArch {
    param($Items, [string]$Arch)
    foreach ($a in (Get-ArchChain $Arch)) {
        $hit = @($Items | Where-Object { Test-NameArch $_.Name $a })
        if ($hit.Count) { return $hit }
    }
    return @()
}

function Get-NameVersion([string]$name) {
    $p = $name -split '_'
    if ($p.Count -ge 2 -and $p[1] -match '^[\d.]+$') {
        try { return [version]$p[1] } catch { }
    }
    return [version]'0.0.0.0'
}

function ConvertTo-Bytes([string]$t) {
    if ($t -match '([\d.]+)\s*(GB|MB|KB|B)\b') {
        $n = [double]$matches[1]
        switch ($matches[2]) {
            'GB' { return [long]($n * 1GB) }
            'MB' { return [long]($n * 1MB) }
            'KB' { return [long]($n * 1KB) }
            default { return [long]$n }
        }
    }
    return [long]0
}

# ---------------------------------------------------------------- resolve the product id
# One small piece both callers share: the URL form (-Url) and a line in a
# batch file have to agree on what a Store link looks like.
function Get-IdFromUrl([string]$Url) {
    if (-not $Url) { return '' }
    # https://apps.microsoft.com/detail/9NKSQGP7F2NH  (also the older /store/apps/<id>, /p/<id>)
    $m = [regex]::Match($Url, '/(?:detail|apps|p)/([0-9A-Za-z]{9,14})')
    if (-not $m.Success) {
        # any 9-14 character token that contains a digit - ids always do, plain words never
        $m = [regex]::Match($Url, '(?<![0-9A-Za-z])([0-9A-Za-z]{9,14})(?![0-9A-Za-z])')
        while ($m.Success -and ($m.Groups[1].Value -notmatch '\d')) { $m = $m.NextMatch() }
    }
    if ($m.Success) { return $m.Groups[1].Value.ToUpperInvariant() }
    return ''
}

function Resolve-ProductId {
    if ($ProductId) { return $ProductId.Trim().ToUpperInvariant() }
    if ($Url) {
        $id = Get-IdFromUrl $Url
        if (-not $id) { throw "could not find a product id in that link: $Url" }
        return $id
    }
    if ($Search) {
        Step "Searching the Store for '$Search' ..."
        $q = [uri]::EscapeDataString($Search)
        $found = @()
        # The Storefront search the web store itself uses.
        $endpoints = @(
            "https://storeedgefd.dsx.mp.microsoft.com/v9.0/pages/searchResults?appVersion=22203.1401.2.0&market=US&locale=en-us&deviceFamily=Windows.Desktop&query=$q",
            "https://storeedgefd.dsx.mp.microsoft.com/v9.0/pages/searchResults?market=US&locale=en-us&deviceFamily=Windows.Desktop&query=$q"
        )
        foreach ($e in $endpoints) {
            try {
                $r = Invoke-RestMethod -Uri $e -Headers @{ 'User-Agent' = $UAStore } -TimeoutSec 40
                # the reply is an array of response items, each with a Payload, but
                # PowerShell hands back a bare object when there is only one
                foreach ($item in @($r)) {
                    foreach ($s in @(Get-Prop (Get-Prop $item 'Payload') 'SearchResults')) {
                        $id = [string](Get-Prop $s 'ProductId')
                        $title = [string](Get-Prop $s 'Title')
                        if ($id -and $title) {
                            $found += [pscustomobject]@{ Id = $id; Title = $title; Publisher = [string](Get-Prop $s 'PublisherName') }
                        }
                    }
                }
                if ($found.Count) { break }
            } catch { }
        }
        if (-not $found.Count) {
            Fail "Search returned nothing. Open the app page in a browser and use -ProductId with the id from the link."
            exit 3
        }
        if ($Json) {
            @($found | Select-Object -First 25 | ForEach-Object {
                    [pscustomobject]@{ id = $_.Id; title = $_.Title; publisher = $_.Publisher }
                }) | ConvertTo-Json -Depth 3
            exit 0
        }
        Say ""
        $i = 0
        foreach ($f in ($found | Select-Object -First 15)) {
            $i++
            Say ("  [{0,2}] {1,-40} {2}" -f $i, $f.Title, $f.Id) 'White'
            if ($f.Publisher) { Say ("       $($f.Publisher)") 'DarkGray' }
        }
        Say ""
        $pick = Read-Host "  Pick a number (Enter to cancel)"
        if (-not $pick) { exit 0 }
        $n = 0
        if (-not [int]::TryParse($pick, [ref]$n) -or $n -lt 1 -or $n -gt $found.Count) {
            Fail "not a valid choice"; exit 3
        }
        return $found[$n - 1].Id
    }
    throw "nothing to do: pass -ProductId, -Url or -Search (or -Install with -Path)"
}

# ---------------------------------------------------------------- Store metadata
# Two catalogs are needed because Microsoft splits the Store in two:
#   displaycatalog  - every packaged (MSIX/AppX) app, with its framework dependencies
#   storeedgefd     - the Storefront catalog, which also knows the unpackaged Win32
#                     apps that the Store only links to as a plain .exe / .msi
function Get-StoreCatalog([string]$productId) {
    $u = "https://displaycatalog.mp.microsoft.com/v7.0/products/${productId}?languages=en-us,neutral&market=US"
    try {
        $c = Invoke-RestMethod -Uri $u -Headers @{ 'User-Agent' = $UAStore } -TimeoutSec 40
        $prod = $c.Product
        $pkg = $prod.DisplaySkuAvailabilities[0].Sku.Properties.Packages[0]
        $deps = @()
        if ($pkg.FrameworkDependencies) { $deps = @($pkg.FrameworkDependencies | ForEach-Object { $_.PackageIdentity }) }
        # The same app also has an identity in the Windows Update world, and that is
        # what the file list is looked up by (see Get-StoreFilesFe3 below).
        $wuCat = ''
        try { $wuCat = [string]$prod.DisplaySkuAvailabilities[0].Sku.Properties.FulfillmentData.WuCategoryId } catch { }
        # the biggest "Logo" image Microsoft publishes for this app
        $icon = ''
        $logos = @($prod.LocalizedProperties[0].Images | Where-Object { $_.ImagePurpose -eq 'Logo' })
        if ($logos.Count) {
            $icon = [string]($logos | Sort-Object { [int]$_.Height } -Descending | Select-Object -First 1).Uri
            # the catalog returns this one protocol-relative
            if ($icon.StartsWith('//')) { $icon = 'https:' + $icon }
        }
        return [pscustomobject]@{
            Kind      = 'packaged'
            Title     = $prod.LocalizedProperties[0].ProductTitle
            Publisher = $prod.LocalizedProperties[0].PublisherName
            Version   = ($pkg.PackageFullName -split '_')[1]
            Family    = $pkg.PackageFamilyName
            Archs     = @($pkg.Architectures)
            Size      = [long]$pkg.MaxDownloadSizeInBytes
            Deps      = $deps
            Icon      = $icon
            Installer = $null
            WuCategoryId = $wuCat
        }
    } catch { }

    try {
        $u2 = "https://storeedgefd.dsx.mp.microsoft.com/v9.0/products/${productId}?market=US&locale=en-us&deviceFamily=Windows.Desktop"
        $s = Invoke-RestMethod -Uri $u2 -Headers @{ 'User-Agent' = $UAStore } -TimeoutSec 40
        $pl = $s.Payload
        $inst = $pl.Installer
        $archs = @()
        $ver = ''
        if ($inst -and $inst.Architectures) {
            $props = @($inst.Architectures.PSObject.Properties)
            $archs = @($props | ForEach-Object { $_.Name.ToLowerInvariant() })
            if ($props.Count -and $props[0].Value.Version) { $ver = [string]$props[0].Value.Version }
        }
        $kind = 'packaged'
        if ($inst -and $inst.Type -eq 'WPM') { $kind = 'win32' }
        $icon = ''
        $logos = @($pl.Images | Where-Object { $_.ImageType -eq 'logo' })
        if ($logos.Count) { $icon = [string]($logos | Sort-Object { [int]$_.Height } -Descending | Select-Object -First 1).Url }
        return [pscustomobject]@{
            Kind      = $kind
            Title     = $pl.Title
            Publisher = $pl.PublisherName
            Version   = $ver
            Family    = ''
            Archs     = $archs
            Size      = [long]0
            Deps      = @()
            Icon      = $icon
            Installer = $inst
            WuCategoryId = ''
        }
    } catch {
        Warn "Store metadata unavailable ($($_.Exception.Message)) - continuing with the file list only."
        return $null
    }
}

# ---------------------------------------------------------------- the file list (Store CDN)
function Get-StoreFiles([string]$productId) {
    $hdr = @{
        'User-Agent' = $UA
        'Referer'    = 'https://store.rg-adguard.net/'
        'Origin'     = 'https://store.rg-adguard.net'
    }
    $sess = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    $null = Invoke-WebRequest -Uri 'https://store.rg-adguard.net/' -UseBasicParsing -WebSession $sess -Headers $hdr -TimeoutSec 40
    $resp = Invoke-WebRequest -Uri 'https://store.rg-adguard.net/api/GetFiles' -Method Post `
        -Body "type=ProductId&url=$productId&ring=Retail&lang=en-US" `
        -ContentType 'application/x-www-form-urlencoded; charset=UTF-8' `
        -UseBasicParsing -WebSession $sess -Headers $hdr -TimeoutSec 180

    $out = New-Object System.Collections.Generic.List[object]
    foreach ($m in [regex]::Matches($resp.Content, '(?s)<tr\b[^>]*>(.*?)</tr>')) {
        $row = $m.Groups[1].Value
        $a = [regex]::Match($row, '<a\s+href="([^"]+)"[^>]*>([^<]+)</a>')
        if (-not $a.Success) { continue }
        $url  = Unescape-Html $a.Groups[1].Value
        $name = Unescape-Html $a.Groups[2].Value
        # The table shape is not stable: packaged apps come as File / SHA-1 / Size,
        # the Win32 installers as just File / SHA-256, so read the cells by content.
        $cells = [regex]::Matches($row, '(?s)<td[^>]*>(.*?)</td>')
        $sha = ''
        $sizeTxt = ''
        for ($ci = 1; $ci -lt $cells.Count; $ci++) {
            $v = ($cells[$ci].Groups[1].Value -replace '<[^>]+>', '').Trim()
            if (-not $sha -and $v -match '^[0-9a-fA-F]{40}$') { $sha = $v.ToLowerInvariant(); continue }
            if (-not $sha -and $v -match '^[0-9a-fA-F]{64}$') { $sha = $v.ToLowerInvariant(); continue }
            if (-not $sizeTxt -and $v -match '^[\d.]+\s*(GB|MB|KB|B)\b') { $sizeTxt = $v }
        }
        $out.Add([pscustomobject]@{
            Name = $name
            Url  = $url
            Sha1 = $sha
            Size = ConvertTo-Bytes $sizeTxt
            # this listing has no revision (it is not Microsoft's update service), so
            # the link is renewed by file name instead - see Get-FreshUrl
            Rev  = ''
        })
    }
    if ($out.Count -eq 0) {
        throw "the Store returned no files for product '$productId' - check the id (it must be a Microsoft Store app)"
    }
    return $out
}

