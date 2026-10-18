# ----------------------------------------------------------------------------- # Install, and the offline kit # # Part of Store-Offline.ps1. Not runnable on its own: the entry script # dot-sources this file so that everything shares one scope. # ----------------------------------------------------------------------------- 
# ---------------------------------------------------------------- install
function Add-ZipSupport {
    # ZipArchive lives in System.IO.Compression, ZipFile in ...FileSystem. Both are
    # present on .NET 4.5+; if the machine is older the caller degrades gracefully.
    Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
}

function Read-ZipText($zip, [string]$name) {
    $e = $zip.Entries | Where-Object { $_.FullName -eq $name } | Select-Object -First 1
    if (-not $e) { return $null }
    $sr = New-Object IO.StreamReader($e.Open())
    try { return $sr.ReadToEnd() } finally { $sr.Dispose() }
}

function Get-DependencyNamesFromManifest([string]$xml) {
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($m in [regex]::Matches($xml, '<PackageDependency\b[^>]*\bName="([^"]+)"')) {
        $names.Add(($m.Groups[1].Value -split '_')[0])
    }
    return $names
}

# Which packages will Add-AppxPackage accept as -DependencyPath for this app?
#
# A plain .appx/.msix carries AppxManifest.xml at its root. A bundle does not: it
# carries AppxBundleManifest.xml plus one package per architecture, and Windows
# installs exactly one of those children. Only that child's own dependency list
# is legal - anything else is refused with 0x80073CF3 "was provided but not used".
# This was the reason bundles used to fail to install.
function Get-NeededDependencyNames {
    param([string]$PkgPath, [string]$Arch)

    try {
        Add-ZipSupport
        $zip = [IO.Compression.ZipFile]::OpenRead($PkgPath)
        try {
            $xml = Read-ZipText $zip 'AppxManifest.xml'

            if (-not $xml) {
                # a bundle keeps its manifest under AppxMetadata/
                $bm = Read-ZipText $zip 'AppxMetadata/AppxBundleManifest.xml'
                if (-not $bm) { $bm = Read-ZipText $zip 'AppxBundleManifest.xml' }
                if (-not $bm) {
                    $be = $zip.Entries | Where-Object { $_.FullName -like '*AppxBundleManifest.xml' } | Select-Object -First 1
                    if ($be) { $bm = Read-ZipText $zip $be.FullName }
                }
                if (-not $bm) { return @() }

                $kids = New-Object System.Collections.Generic.List[object]
                foreach ($m in [regex]::Matches($bm, '<Package\b[^>]*>')) {
                    $tag = $m.Value
                    # only the application payloads matter; resource packages are
                    # handled separately by the caller
                    if ($tag -notmatch '\bType="application"') { continue }
                    $fn = [regex]::Match($tag, '\bFileName="([^"]+)"').Groups[1].Value
                    if (-not $fn) { continue }
                    $a = [regex]::Match($tag, '\bArchitecture="([^"]+)"').Groups[1].Value
                    $kids.Add([pscustomobject]@{ Name = $fn; Arch = $a })
                }
                if (-not $kids.Count) { return @() }

                $want = $Arch
                if (-not $want) { $want = Get-MachineArch }

                $pick = $null
                foreach ($a in (Get-ArchChain $want)) {
                    $pick = $kids | Where-Object { $_.Arch -eq $a } | Select-Object -First 1
                    if ($pick) { break }
                }
                if (-not $pick) { $pick = $kids | Where-Object { -not $_.Arch -or $_.Arch -eq 'neutral' } | Select-Object -First 1 }
                if (-not $pick) { $pick = $kids | Select-Object -First 1 }

                # the child is itself a ZIP; unpack it in memory and read its manifest
                $e = $zip.Entries | Where-Object { $_.FullName -eq $pick.Name } | Select-Object -First 1
                if (-not $e) { return @() }
                $ms = New-Object IO.MemoryStream
                try {
                    $cs = $e.Open()
                    try { $cs.CopyTo($ms) } finally { $cs.Dispose() }
                    $ms.Position = 0
                    $inner = New-Object IO.Compression.ZipArchive -ArgumentList @($ms, [IO.Compression.ZipArchiveMode]::Read)
                    try { $xml = Read-ZipText $inner 'AppxManifest.xml' } finally { $inner.Dispose() }
                } finally { $ms.Dispose() }
            }

            if (-not $xml) { return @() }
            return Get-DependencyNamesFromManifest $xml
        } finally { $zip.Dispose() }
    } catch {
        return @()
    }
}

function Invoke-Install {
    param([string]$Folder, [switch]$ForceShutdown)

    if (-not $script:CanInstall) {
        Warn 'this Windows has no Add-AppxPackage, so it cannot install MSIX/AppX packages.'
        Warn 'The files are still on disk and can be installed on a Windows 8 / 10 / 11 machine.'
        return
    }

    $m = Read-Manifest $Folder
    if ($m) {
        $appName = $m.app
        $depNames = @($m.dependencies)
        $resNames = @($m.resources)
        $title = $m.title
    } else {
        # no manifest: best effort - bundle (or biggest package) is the app
        $pkgs = @(Get-ChildItem -LiteralPath $Folder -File | Where-Object { $_.Name -match '\.(emsixbundle|eappxbundle|msixbundle|appxbundle|emsix|eappx|msix|appx|exe|msi)$' })
        if (-not $pkgs.Count) { throw "no packages found in $Folder" }
        $b = @($pkgs | Where-Object { (Get-FileKind $_.Name) -eq 'bundle' })
        if ($b.Count) { $appName = $b[0].Name; $depNames = @($pkgs | Where-Object { $_.Name -ne $appName } | ForEach-Object { $_.Name }) }
        else {
            $sorted = @($pkgs | Sort-Object Length -Descending)
            $appName = $sorted[0].Name
            $depNames = @($sorted | Select-Object -Skip 1 | ForEach-Object { $_.Name })
        }
        $resNames = @()
        $title = $appName
    }

    $appPath = Join-Path $Folder $appName
    if (-not (Test-Path -LiteralPath $appPath)) { throw "app package missing: $appPath" }
    # an older build of the app itself can appear in the Store's dependency list;
    # Windows rejects it as an invalid dependency, so never pass it along
    $appFamily = ($appName -split '_')[0]
    $depNames = @($depNames | Where-Object { ([string]$_ -split '_')[0] -ne $appFamily })
    if ((Get-FileKind $appName) -eq 'installer') {
        Say ''
        Say "  $appName is a normal Windows installer (.exe/.msi), not an MSIX package," 'Yellow'
        Say '  so Windows cannot install it with Add-AppxPackage. Run it yourself:' 'Yellow'
        Say ("      {0}" -f $appPath) 'White'
        if ($m -and $m.silentArgs) { Say ("  (the Store itself runs it with: {0})" -f $m.silentArgs) 'DarkGray' }
        return
    }

    # MSIX is a Windows 10 1809 format; Windows 8/8.1 only understand .appx, and
    # they report the mismatch rather unhelpfully. Say it plainly instead.
    $osVer = [Environment]::OSVersion.Version
    if ($osVer.Major -lt 10 -and $appName -match '\.(emsix|emsixbundle|msix|msixbundle)$') {
        Warn ("this is Windows {0}.{1}, which cannot install MSIX packages." -f $osVer.Major, $osVer.Minor)
        Warn 'MSIX needs Windows 10 version 1809 or newer.'
        Warn 'The downloaded files are still fine - copy the folder to a newer'
        Warn 'machine and run the same -Install command there.'
        return
    }
    # An encrypted package is intact but Windows needs a Store licence to decrypt it,
    # so Add-AppxPackage usually fails on a machine that never owned the app.
    if (Test-EncryptedName $appName) {
        Warn "$appName is an ENCRYPTED Store package."
        Warn 'Windows installs those only with a valid Store licence, so this is likely'
        Warn 'to fail with a deployment error. The file itself is fine.'
    }
    $depPaths = @()
    foreach ($d in $depNames) {
        $p = Join-Path $Folder $d
        if (Test-Path -LiteralPath $p) { $depPaths += $p } else { Warn "dependency missing, skipped: $d" }
    }

    # Windows rejects any -DependencyPath entry the package does not actually use, and
    # the Store's dependency list is not per-architecture. Trust the package's own manifest.
    $insArch = ''
    if ($m -and $m.architecture) { $insArch = [string]$m.architecture }
    if (-not $insArch) { $insArch = Get-MachineArch }
    $needNames = @(Get-NeededDependencyNames -PkgPath $appPath -Arch $insArch)
    if ($needNames.Count -and $depPaths.Count) {
        $before = $depPaths.Count
        $depPaths = @($depPaths | Where-Object {
                $leaf = Split-Path -Leaf $_
                $keep = $false
                foreach ($nd in $needNames) { if ($leaf -like ($nd + '_*')) { $keep = $true; break } }
                $keep
            })
        if ($depPaths.Count -lt $before) {
            Say ("  (skipping {0} dependency package(s) the app does not use)" -f ($before - $depPaths.Count)) 'DarkGray'
        }
    }

    Say "  app          : $appName"
    Say "  resources    : $(if ($resNames.Count) { $resNames.Count.ToString() } else { '0' })"
    Say "  dependencies : $(if ($depPaths.Count) { $depPaths.Count.ToString() } else { '0' })"
    Say ""

    $ap = @{ Path = $appPath; ErrorAction = 'Stop' }
    if ($depPaths.Count) { $ap['DependencyPath'] = $depPaths }
    if ($ForceShutdown) { $ap['ForceApplicationShutdown'] = $true }

    # Windows refuses the whole install when even one -DependencyPath entry is
    # unused, and names the offender in the message. Drop that one and retry, so an
    # over-broad dependency list (or a folder copied here from elsewhere) still
    # installs instead of stopping dead.
    $ok = $false
    for ($attempt = 1; $attempt -le 10; $attempt++) {
        try {
            Add-AppxPackage @ap
            Ok "installed: $title"
            $ok = $true
            break
        } catch {
            $msg = [string]$_.Exception.Message
            $bad = $null
            if ($depPaths.Count -gt 0 -and $msg -match 'provided but not used') {
                foreach ($d in $depPaths) {
                    $leaf = [IO.Path]::GetFileNameWithoutExtension($d)
                    if ($leaf -and $msg -like "*$leaf*") { $bad = $d; break }
                }
            }
            if (-not $bad) {
                Fail "install failed: $msg"
                Say ""
                Say "  Common fixes:" 'Yellow'
                Say "    * '0x80073CF3' dependency -> re-run with -Download to fetch the framework packages too." 'Yellow'
                Say "    * '0x800B0109' untrusted  -> the package must be Store-signed; re-download it." 'Yellow'
                Say "    * '0x80073D02' in use     -> the app is running; close it and re-run, or add -Force." 'Yellow'
                Say "    * sideloading disabled    -> Settings > System > For developers > Developer Mode ON." 'Yellow'
                exit 5
            }
            Warn ("Windows does not use {0} - dropping it and retrying" -f (Split-Path -Leaf $bad))
            $depPaths = @($depPaths | Where-Object { $_ -ne $bad })
            if ($depPaths.Count) { $ap['DependencyPath'] = $depPaths } else { $ap.Remove('DependencyPath') }
        }
    }
    if (-not $ok) { Fail 'install failed: gave up after too many unused dependencies'; exit 5 }

    # resource packages (scale / language) go in after the main package; a failure
    # here is not fatal - the app still runs, just possibly with fewer assets
    foreach ($r in $resNames) {
        $rp = Join-Path $Folder $r
        if (-not (Test-Path -LiteralPath $rp)) { continue }
        try {
            Add-AppxPackage -Path $rp -ErrorAction Stop
            Ok "resource package installed: $r"
        } catch {
            Warn "resource package skipped: $r ($($_.Exception.Message))"
        }
    }

    $installed = Get-AppxPackage | Where-Object { $_.PackageFullName -match [regex]::Escape(($appName -split '_')[0]) }
    if ($installed) {
        Say ""
        $installed | Select-Object Name, Version, Architecture | Format-Table -AutoSize | Out-String | Write-Host
    }
}

# ---------------------------------------------------------------- offline kit
# Drops a self-contained install.cmd + install.ps1 into a downloaded folder, so
# the whole folder can be carried to another Windows machine (USB stick, network
# share, no internet) and installed there without this script.
function Write-OfflineKit {
    param([string]$Folder)

    $m = Read-Manifest $Folder
    if (-not $m) {
        Warn "no store-manifest.json in $Folder - cannot write the offline kit"
        return
    }

    $appName = [string]$m.app
    $deps = @($m.dependencies)
    $res = @($m.resources)

    # an older build of the app itself is sometimes listed as a dependency; Windows
    # rejects it, so drop anything from the app's own package family
    $appFamily = ($appName -split '_')[0]
    $deps = @($deps | Where-Object { ([string]$_ -split '_')[0] -ne $appFamily })

    # Windows rejects any -DependencyPath entry the app does not really use, and the
    # Store's dependency list is not per-architecture. Resolve it here, once, so the
    # kit stays a plain folder that any machine can install from - including machines
    # whose PowerShell is too old to unpack the package manifest itself.
    $appPath = Join-Path $Folder $appName
    if ((Test-Path -LiteralPath $appPath) -and $appName -notmatch '\.(exe|msi)$') {
        $kitArch = [string]$m.architecture
        if (-not $kitArch) { $kitArch = Get-MachineArch }
        $need = @(Get-NeededDependencyNames -PkgPath $appPath -Arch $kitArch)
        if ($need.Count -and $deps.Count) {
            $kept = @($deps | Where-Object {
                    $leaf = [string]$_
                    $keep = $false
                    foreach ($nd in $need) { if ($leaf -like ($nd + '_*')) { $keep = $true; break } }
                    $keep
                })
            if ($kept.Count -lt $deps.Count) {
                Say ("  (kit: {0} dependency package(s) the app does not use were left out)" -f ($deps.Count - $kept.Count)) 'DarkGray'
            }
            $deps = $kept
        }
    }

    # kit.json holds the resolved list, so install.ps1 needs no Store metadata and
    # no ZIP parsing of its own.
    [pscustomobject]@{
        productId    = [string]$m.productId
        title        = [string]$m.title
        publisher    = [string]$m.publisher
        version      = [string]$m.version
        architecture = [string]$m.architecture
        kind         = $(if ($m.kind) { [string]$m.kind } elseif ($appName -match '\.(exe|msi)$') { 'win32' } else { 'packaged' })
        app          = $appName
        dependencies = @($deps)
        resources    = @($res)
        silentArgs   = [string]$m.silentArgs
        downloadPage = [string]$m.downloadPage
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $Folder 'kit.json') -Encoding UTF8

    $installPs1 = @'
<#
    Installs the Microsoft Store app sitting in this folder.

    Self-contained on purpose: copy the whole folder to any Windows machine and
    run install.cmd there. No internet connection and no other files are needed.
#>
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

function Say($m, $c = 'Gray') { Write-Host $m -ForegroundColor $c }

# Add-AppxPackage is the only way Windows installs an MSIX/AppX. It arrived with
# Windows 8; below that there is nothing to fall back on, so say so plainly.
if (-not (Get-Command Add-AppxPackage -ErrorAction SilentlyContinue)) {
    Say ''
    Say '  This Windows cannot install MSIX/AppX packages: it has no Add-AppxPackage.' 'Yellow'
    Say '  Windows 8 or newer is required. The files in this folder are untouched.' 'Yellow'
    Say ''
    exit 1
}

$mf = Join-Path $here 'store-manifest.json'
$kf = Join-Path $here 'kit.json'
if (Test-Path -LiteralPath $kf) {
    # written by the downloader: the Store's dependency list already resolved down
    # to the packages this app really needs
    $m = Get-Content -LiteralPath $kf -Raw -Encoding UTF8 | ConvertFrom-Json
} elseif (Test-Path -LiteralPath $mf) {
    $m = Get-Content -LiteralPath $mf -Raw -Encoding UTF8 | ConvertFrom-Json
} else {
    Say '  neither kit.json nor store-manifest.json is here - cannot tell what to install.' 'Red'
    exit 1
}

$app = Join-Path $here ([string]$m.app)
if (-not (Test-Path -LiteralPath $app)) {
    Say "  the app package is missing: $app" 'Red'
    exit 1
}

# an unpackaged Win32 app is a plain installer that Windows will not sideload
if ($app -match '\.(exe|msi)$') {
    Say ''
    Say "  $($m.app) is a normal Windows installer (.exe/.msi), not an MSIX package," 'Yellow'
    Say '  so Windows will not install it for you. Run it yourself:' 'Yellow'
    Say ("      {0}" -f $app) 'White'
    if ($m.silentArgs) { Say ("  (the Store itself runs it with: {0})" -f $m.silentArgs) 'DarkGray' }
    Say ''
    exit 0
}

# MSIX is a Windows 10 1809 format; Windows 8/8.1 only understand .appx
$os = [Environment]::OSVersion.Version
if ($os.Major -lt 10 -and $app -match '\.(emsix|emsixbundle|msix|msixbundle)$') {
    Say ''
    Say ("  This is Windows {0}.{1}, which cannot install MSIX packages." -f $os.Major, $os.Minor) 'Yellow'
    Say '  MSIX needs Windows 10 version 1809 or newer. The files are fine as they are.' 'Yellow'
    Say ''
    exit 1
}

$depPaths = @()
foreach ($d in @($m.dependencies)) {
    $p = Join-Path $here ([string]$d)
    if (Test-Path -LiteralPath $p) { $depPaths += $p } else { Say ("  dependency missing, skipped: {0}" -f $d) 'Yellow' }
}

Say ''
Say ("  Installing {0}" -f $(if ($m.title) { $m.title } else { $m.app }))
Say ("    app          : {0}" -f $m.app)
Say ("    dependencies : {0}" -f $depPaths.Count)
Say ''

$ap = @{ Path = $app; ErrorAction = 'Stop' }
if ($depPaths.Count) { $ap['DependencyPath'] = $depPaths }

# Windows rejects the whole install when even one -DependencyPath entry is unused
# and names it in the message. Drop that one and retry, so a folder whose kit.json
# was edited by hand (or written by an older version) still installs.
$done = $false
for ($attempt = 1; $attempt -le 10; $attempt++) {
    try {
        Add-AppxPackage @ap
        Say '  installed.' 'Green'
        $done = $true
        break
    } catch {
        $msg = [string]$_.Exception.Message
        $bad = $null
        if ($depPaths.Count -gt 0 -and $msg -match 'provided but not used') {
            foreach ($d in $depPaths) {
                $leaf = [IO.Path]::GetFileNameWithoutExtension($d)
                if ($leaf -and $msg -like "*$leaf*") { $bad = $d; break }
            }
        }
        if (-not $bad) {
            Say ("  install failed: {0}" -f $msg) 'Red'
            Say ''
            Say '  Common fixes:' 'Yellow'
            Say '    * 0x80073CF3 dependency -> a framework package is missing from this folder.' 'Yellow'
            Say '    * 0x80073CF9 dependency -> the framework packages do not match; re-download the app.' 'Yellow'
            Say '    * 0x80073D06           -> this app is already installed on this machine.' 'Yellow'
            Say '    * 0x80073D02 in use     -> the app is running; close it and try again.' 'Yellow'
            Say '    * 0x800B0109 untrusted  -> the package is damaged; download it again.' 'Yellow'
            Say '    * sideloading disabled  -> Settings > System > For developers > Developer Mode.' 'Yellow'
            Say '    * 0x8007FFFF arch       -> this folder is for another CPU; download it with -Arch x86.' 'Yellow'
            exit 5
        }
        Say ("  Windows does not use {0} - dropping it and retrying" -f [IO.Path]::GetFileName($bad)) 'DarkGray'
        $depPaths = @($depPaths | Where-Object { $_ -ne $bad })
        if ($depPaths.Count) { $ap['DependencyPath'] = $depPaths } else { $ap.Remove('DependencyPath') }
    }
}
if (-not $done) {
    Say '  install failed: gave up after too many unused dependencies' 'Red'
    exit 5
}

# resource packages (language / scale) are optional: a failure here is not fatal
foreach ($r in @($m.resources)) {
    $rp = Join-Path $here ([string]$r)
    if (-not (Test-Path -LiteralPath $rp)) { continue }
    try {
        Add-AppxPackage -Path $rp -ErrorAction Stop
        Say ("  resource installed: {0}" -f $r) 'Green'
    } catch {
        Say ("  resource skipped: {0}" -f $r) 'Yellow'
    }
}

Say ''
Say '  Done.' 'Green'
'@

    $installCmd = @'
@echo off
setlocal
cd /d "%~dp0"

rem ---- find a Windows PowerShell, and fall back to PowerShell 7 when 5.1 is absent
set "PSEXE="
if exist "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" set "PSEXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not defined PSEXE for %%P in (powershell.exe) do if not "%%~$PATH:P"=="" set "PSEXE=%%~$PATH:P"
if not defined PSEXE for %%P in (pwsh.exe) do if not "%%~$PATH:P"=="" set "PSEXE=%%~$PATH:P"

if not defined PSEXE (
  echo.
  echo   No PowerShell was found on this machine.
  echo.
  pause
  exit /b 1
)

"%PSEXE%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"
echo.
pause
'@

    # install.cmd must stay plain ASCII with CRLF endings; cmd.exe is unforgiving
    $cmdText = (($installCmd -split "`r?`n") -join "`r`n") + "`r`n"
    [IO.File]::WriteAllBytes((Join-Path $Folder 'install.cmd'), [Text.Encoding]::ASCII.GetBytes($cmdText))
    [IO.File]::WriteAllText((Join-Path $Folder 'install.ps1'), ($installPs1 -replace "`r?`n", "`r`n"), (New-Object Text.UTF8Encoding($true)))
}

