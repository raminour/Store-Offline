<#
.SYNOPSIS
    Offline tests for Store-Offline.ps1 and Store-Gui.ps1.

.DESCRIPTION
    Every check here runs without a network connection and finishes in seconds,
    so a change to the tool can be verified before doing the slow, real download
    test. The functions are pulled straight out of the shipped scripts with the
    PowerShell parser, so there is no copy of the code to keep in sync - whatever
    the scripts contain is what gets tested.

    Usage:  powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1
            exit code 0 = all good, 1 = something failed
#>
[CmdletBinding()]
param(
    [string]$ToolDir
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $ToolDir) { $ToolDir = Split-Path -Parent $here }
$ToolDir = (Resolve-Path -LiteralPath $ToolDir).Path
$ToolPs1 = Join-Path $ToolDir 'Store-Offline.ps1'
$GuiPs1 = Join-Path $ToolDir 'Store-Gui.ps1'
$LibDir = Join-Path $ToolDir 'lib'

$script:Pass = 0
$script:Fail = 0
$script:Section = ''

function Section([string]$t) {
    $script:Section = $t
    Write-Host ''
    Write-Host ("--- {0} " -f $t).PadRight(72, '-') -ForegroundColor Cyan
}

function Check([string]$name, $actual, $expected) {
    $a = if ($null -eq $actual) { '<null>' } else { [string]$actual }
    $e = if ($null -eq $expected) { '<null>' } else { [string]$expected }
    if ($a -eq $e) {
        $script:Pass++
        Write-Host ("  [ok]   {0}" -f $name) -ForegroundColor DarkGreen
    } else {
        $script:Fail++
        Write-Host ("  [FAIL] {0}" -f $name) -ForegroundColor Red
        Write-Host ("           got  : {0}" -f $a) -ForegroundColor Red
        Write-Host ("           want : {0}" -f $e) -ForegroundColor Red
    }
}

function CheckTrue([string]$name, $cond) { Check $name ([bool]$cond) $true }

# Collect every function definition in a script as text. A here-string holding a
# script (the offline kit template) is a literal, not AST nodes, so its contents
# cannot leak in.
function Get-ToolFunctionTexts([string]$file) {
    $err = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$err)
    if ($err -and $err.Count) { throw "$file has syntax errors: $($err[0].Message)" }
    $fns = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
    # the @() at the call sites is what keeps a single function from being unrolled
    # into a bare string (and a file with no functions from becoming $null)
    return @($fns | ForEach-Object { $_.Extent.Text })
}

# ---------------------------------------------------------------- load the tool
# The tool keeps its flow in Store-Offline.ps1 and its machinery in lib\*.ps1,
# and the tests pull the functions out of all of them - whatever the scripts
# contain is what gets tested.
# These loop at the top level on purpose: Invoke-Expression inside a function
# would define the functions in that function's scope, and they would vanish.
$toolFiles = @($ToolPs1)
if (Test-Path -LiteralPath $LibDir) {
    $toolFiles += @(Get-ChildItem -LiteralPath $LibDir -Filter '*.ps1' | Sort-Object Name | ForEach-Object { $_.FullName })
}
$toolFns = @()
foreach ($f in $toolFiles) { $toolFns += @(Get-ToolFunctionTexts $f) }
$guiFns = @(Get-ToolFunctionTexts $GuiPs1)
foreach ($t in $toolFns) { Invoke-Expression $t }
foreach ($t in $guiFns) { Invoke-Expression $t }

# The tool runs with Set-StrictMode -Version Latest, and so do these tests: a
# function that reads a variable or a property that is not there is a bug, and
# this is the cheapest place to find out.
Set-StrictMode -Version Latest

# script-scope values the functions expect; none of them reach the network
$script:HasHttpClient = $true
$script:HasFileHash = $true
$script:CanInstall = $true
$script:CanExtract = $true
$script:Pf = [pscustomobject]@{ Rate = 0.0; State = 'idle'; Base = 0; Total = 0; Message = ''; File = ''; Index = 0; Count = 0; Folder = '' }
$Json = $false
$NoDeps = $false
$ProgressFile = $null
# set by the entry script, read by functions in lib\
$ScriptDir = $ToolDir
$SelfPath = $ToolPs1
$StoreRoot = Join-Path $ToolDir 'StoreApps'
# the parameters, with the same defaults the tool gives them
$Arch = 'x64'
$Force = $false
$Extract = $false
$Encrypted = $false
$NoFe3 = $false
$Kit = $false
$All = $false
$List = $false
$Download = $false
$Install = $false
$Check = $false
$Env = $false
$LegacyHttp = $false
$Url = ''
$Search = ''
$OutDir = ''
$Path = ''
$ProductId = ''
$script:Fe3 = $null
$script:RgProduct = $null
# the test's own CRC table, built on first use by Get-Crc32
$script:Crctab = $null

$work = Join-Path ([IO.Path]::GetTempPath()) ('so-tests-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $work | Out-Null

Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

# ---------------------------------------------------------------- fixtures
# A package (its own ZIP) whose AppxManifest.xml declares the given dependencies.
function New-ChildPackageBytes([string]$name, [string]$version, [string]$arch, [string[]]$deps, [string]$resourceId = '') {
    $dep = ''
    foreach ($d in $deps) {
        $dep += ('    <PackageDependency Name="{0}" MinVersion="1.0.0.0" Publisher="CN=Microsoft Corporation" />' -f $d) + "`r`n"
    }
    $rid = if ($resourceId) { ' ResourceId="' + $resourceId + '"' } else { '' }
    $xml = @"
<?xml version="1.0" encoding="utf-8"?>
<Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10">
  <Identity Name="$name" Publisher="CN=test" Version="$version" ProcessorArchitecture="$arch"$rid />
  <Dependencies>
    <TargetDeviceFamily Name="Windows.Desktop" MinVersion="10.0.14393.0" MaxVersionTested="10.0.14393.0" />
$dep  </Dependencies>
</Package>
"@
    $ms = New-Object IO.MemoryStream
    $zip = New-Object IO.Compression.ZipArchive -ArgumentList @($ms, [IO.Compression.ZipArchiveMode]::Create, $true)
    $e = $zip.CreateEntry('AppxManifest.xml')
    $e.LastWriteTime = [DateTimeOffset]::new(2016, 7, 29, 0, 0, 0, [TimeSpan]::Zero)  # keeps builds byte-identical
    $w = New-Object IO.StreamWriter($e.Open(), (New-Object Text.UTF8Encoding($false)))
    $w.Write($xml); $w.Flush(); $w.Dispose()
    $zip.Dispose()
    $bytes = $ms.ToArray()
    $ms.Dispose()
    return , $bytes
}

function Get-Crc32([byte[]]$b) {
    if (-not $script:Crctab) {
        # 0xFFFFFFFF and 0xEDB88320 are negative as Int32 literals in PowerShell, so
        # they have to be written as uint32 values
        $poly = [uint32]3988292384
        $script:Crctab = New-Object 'uint32[]' 256
        for ($i = 0; $i -lt 256; $i++) {
            $c = [uint32]$i
            for ($k = 0; $k -lt 8; $k++) {
                if ($c -band 1) { $c = [uint32]($poly -bxor ($c -shr 1)) } else { $c = [uint32]($c -shr 1) }
            }
            $script:Crctab[$i] = $c
        }
    }
    $crc = [uint32]::MaxValue
    foreach ($x in $b) { $crc = [uint32]($script:Crctab[($crc -bxor $x) -band 0xFF] -bxor ($crc -shr 8)) }
    return [uint32]($crc -bxor [uint32]::MaxValue)
}

# A minimal ZIP writer that stores entries verbatim. That is exactly how the
# Store's own bundles are built, and it is the only reason reading one child out
# of a bundle over HTTP byte ranges is possible - so the fixture has to match.
function New-StoredZip([string]$Path, $Items) {
    $ms = New-Object IO.MemoryStream
    $bw = New-Object IO.BinaryWriter($ms)
    $cd = New-Object IO.MemoryStream
    $cdw = New-Object IO.BinaryWriter($cd)
    foreach ($it in $Items) {
        $data = $it.Bytes
        $nameBytes = [Text.Encoding]::UTF8.GetBytes([string]$it.Name)
        $crc = Get-Crc32 $data
        $off = [uint32]$ms.Position

        $bw.Write([uint32]0x04034b50)          # local file header
        $bw.Write([uint16]20)                  # version needed
        $bw.Write([uint16]0)                   # flags
        $bw.Write([uint16]0)                   # method 0 = stored
        $bw.Write([uint16]0x2100)              # time (fixed)
        $bw.Write([uint16]0x5A21)              # date (fixed)
        $bw.Write([uint32]$crc)
        $bw.Write([uint32]$data.Length)
        $bw.Write([uint32]$data.Length)
        $bw.Write([uint16]$nameBytes.Length)
        $bw.Write([uint16]0)                   # extra len
        $bw.Write($nameBytes)
        $bw.Write($data)

        $cdw.Write([uint32]0x02014b50)         # central directory header
        $cdw.Write([uint16]20)
        $cdw.Write([uint16]20)
        $cdw.Write([uint16]0)
        $cdw.Write([uint16]0)                  # method 0 = stored
        $cdw.Write([uint16]0x2100)
        $cdw.Write([uint16]0x5A21)
        $cdw.Write([uint32]$crc)
        $cdw.Write([uint32]$data.Length)
        $cdw.Write([uint32]$data.Length)
        $cdw.Write([uint16]$nameBytes.Length)
        $cdw.Write([uint16]0)                  # extra len
        $cdw.Write([uint16]0)                  # comment len
        $cdw.Write([uint16]0)                  # disk
        $cdw.Write([uint16]0)                  # internal attrs
        $cdw.Write([uint32]0)                  # external attrs
        $cdw.Write([uint32]$off)
        $cdw.Write($nameBytes)
    }
    $cdBytes = $cd.ToArray()
    $cdOff = [uint32]$ms.Position
    $bw.Write($cdBytes)
    $bw.Write([uint32]0x06054b50)              # end of central directory
    $bw.Write([uint16]0)
    $bw.Write([uint16]0)
    $bw.Write([uint16]$Items.Count)
    $bw.Write([uint16]$Items.Count)
    $bw.Write([uint32]$cdBytes.Length)
    $bw.Write([uint32]$cdOff)
    $bw.Write([uint16]0)                       # comment len
    $bw.Flush()
    [IO.File]::WriteAllBytes($Path, $ms.ToArray())
    $bw.Dispose(); $cdw.Dispose(); $ms.Dispose(); $cd.Dispose()
}

# A bundle: root-level children plus AppxMetadata/AppxBundleManifest.xml.
# Returns the pieces it wrote, so a test can say where each child's bytes are.
function New-BundleFile([string]$path, [switch]$ManifestAtRoot, [switch]$OldStyleFileName) {
    $x86 = New-ChildPackageBytes 'App.Package' '1.0.0.0' 'x86' @('Microsoft.VCLibs.140.00')
    $x64 = New-ChildPackageBytes 'App.Package' '1.0.0.0' 'x64' @('Microsoft.VCLibs.140.00', 'Microsoft.VCLibs.140.00.UWPDesktop')
    $res = New-ChildPackageBytes 'App.Package' '1.0.0.0' 'neutral' @() 'split.scale-200'

    $fx86 = 'App.Package_1.0.0.0_x86.appx'
    $fx64 = 'App.Package_1.0.0.0_x64.appx'
    $fres = 'App.Package_1.0.0.0_scale-200.appx'
    if ($OldStyleFileName) {
        $fx86 = 'App.Package-x86.appx'
        $fx64 = 'App.Package-x64.appx'
        $fres = 'App.Package-scale-200.appx'
    }

    $bm = @"
<?xml version="1.0" encoding="UTF-8" standalone="no"?>
<Bundle SchemaVersion="5.0" xmlns="http://schemas.microsoft.com/appx/2013/bundle">
  <Identity Name="App.Package" Publisher="CN=test" Version="1.0.0.0" />
  <Packages>
    <Package Type="application" Version="1.0.0.0" Architecture="x86" FileName="$fx86" Offset="0" Size="1">
      <Resources><Resource Language="EN-US" /></Resources>
    </Package>
    <Package Type="application" Version="1.0.0.0" Architecture="x64" FileName="$fx64" Offset="0" Size="1">
      <Resources><Resource Language="EN-US" /></Resources>
    </Package>
    <Package Type="resource" Version="1.0.0.0" ResourceId="split.scale-200" FileName="$fres" Offset="0" Size="1">
      <Resources><Resource Scale="200" /></Resources>
    </Package>
  </Packages>
</Bundle>
"@

    $bmName = if ($ManifestAtRoot) { 'AppxBundleManifest.xml' } else { 'AppxMetadata/AppxBundleManifest.xml' }
    New-StoredZip $path @(
        @{ Name = $fx86; Bytes = $x86 },
        @{ Name = $fx64; Bytes = $x64 },
        @{ Name = $fres; Bytes = $res },
        @{ Name = $bmName; Bytes = [Text.Encoding]::UTF8.GetBytes($bm) },
        @{ Name = 'AppxBlockMap.xml'; Bytes = [Text.Encoding]::UTF8.GetBytes('<BlockMap/>') }
    )
    return @{ X86 = $x86; X64 = $x64; X86Name = $fx86; X64Name = $fx64; BmName = $bmName }
}

function Get-Sha256Hex([byte[]]$b) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return (($sha.ComputeHash($b) | ForEach-Object { $_.ToString('x2') }) -join '') } finally { $sha.Dispose() }
}

# ---------------------------------------------------------------- arch helpers
Section 'arch helpers'
Check 'Get-ArchChain x64' ((Get-ArchChain 'x64') -join ',') 'x64,x86'
Check 'Get-ArchChain x86' ((Get-ArchChain 'x86') -join ',') 'x86'
Check 'Get-ArchChain arm64' ((Get-ArchChain 'arm64') -join ',') 'arm64,x64,x86'
Check 'Get-ArchChain arm' ((Get-ArchChain 'arm') -join ',') 'arm,x86'
Check 'Get-ArchChain all' ((Get-ArchChain 'all') -join ',') 'all'
Check 'Test-NameArch x64 hit' (Test-NameArch 'Foo.Bar_1.0.0.0_x64__abc.appx' 'x64') $true
Check 'Test-NameArch x64 miss' (Test-NameArch 'Foo.Bar_1.0.0.0_x86__abc.appx' 'x64') $false
Check 'Test-NameArch all' (Test-NameArch 'anything.msix' 'all') $true
Check 'Get-NameArch x64' (Get-NameArch 'Foo.Bar_1.0.0.0_x64__abc.appx') 'x64'
Check 'Get-NameArch neutral' (Get-NameArch 'Foo.Bar_1.0.0.0_neutral_~_abc.msixbundle') 'neutral'
Check 'Get-NameArch does not see arm in harmony' (Get-NameArch 'Foo.Harmony_1.0.0.0_x64__a.appx') 'x64'
Check 'Get-NameArch none' (Get-NameArch 'plain.exe') ''

Section 'naming: kinds and versions'
Check 'Get-FileKind msix' (Get-FileKind 'a.msix') 'package'
Check 'Get-FileKind appxbundle' (Get-FileKind 'a.appxbundle') 'bundle'
Check 'Get-FileKind msixupload' (Get-FileKind 'a.msixupload') 'upload'
Check 'Get-FileKind exe' (Get-FileKind 'a.exe') 'installer'
Check 'Get-FileKind blockmap' (Get-FileKind 'a.blockmap') 'sidecar'
Check 'Get-FileKind other' (Get-FileKind 'a.txt') 'other'
Check 'Get-VersionFromName packaged' (Get-VersionFromName '5319275A.WhatsAppDesktop_2.2640.100.0_neutral_~_cv1g1gvanyjgm.msixbundle') '2.2640.100.0'
Check 'Get-VersionFromName win32 underscores' (Get-VersionFromName 'CapCut_9_6_0_4097_capcutpc_msstore_creatortool.exe') '9.6.0.4097'
Check 'Get-VersionFromName single number' (Get-VersionFromName 'Tool_42_setup.exe') '42'
Check 'Get-VersionFromName no version' (Get-VersionFromName 'setup.exe') ''
Check 'Get-NameVersion returns a version' ((Get-NameVersion 'Foo_1.2.3.4_x64__a.appx').ToString()) '1.2.3.4'
Check 'Get-NameVersion unparsable' ((Get-NameVersion 'Foo-x64.msix').ToString()) '0.0.0.0'
Check 'Compare-VersionText older' (Compare-VersionText '1.5.3.0' '2.3.0.0') -1
Check 'Compare-VersionText same' (Compare-VersionText '2.3.0.0' '2.3.0.0') 0
Check 'Compare-VersionText newer' (Compare-VersionText '9.6.0.4097' '9.0.0.4097') 1
Check 'Compare-VersionText missing side' (Compare-VersionText '' '1.0') 0

Section 'hashing and text'
$hf = Join-Path $work 'hash.txt'
[IO.File]::WriteAllText($hf, 'abc')
Check 'Get-HashHex SHA256' (Get-HashHex $hf 'SHA256') 'BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD'
Check 'Test-Hash match' (Test-Hash $hf 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad') $true
Check 'Test-Hash mismatch' (Test-Hash $hf '0000') $false
Check 'Unescape-Html' (Unescape-Html 'a&amp;b&lt;c&gt;&quot;d&quot;') 'a&b<c>"d"'
Check 'ConvertTo-Bytes MB' (ConvertTo-Bytes '1.5 MB') 1572864
Check 'ConvertTo-Bytes KB' (ConvertTo-Bytes '512 KB') 524288
Check 'ConvertTo-Bytes none' (ConvertTo-Bytes 'n/a') 0

# ---------------------------------------------------------------- ZIP reader
Section 'ZIP reader (what remote bundle extraction depends on)'
$bundle = Join-Path $work 'App_1.0.0.0_neutral.appxbundle'
$fx = New-BundleFile $bundle
$bytes = [IO.File]::ReadAllBytes($bundle)
$tail = New-Object byte[] ([Math]::Min(262144, $bytes.Length))
[Array]::Copy($bytes, $bytes.Length - $tail.Length, $tail, 0, $tail.Length)
$info = Get-ZipTailInfo $tail
Check 'Get-ZipTailInfo finds EOCD' ($info.CdOffset -gt 0) $true
$cd = New-Object byte[] $info.CdSize
[Array]::Copy($bytes, $info.CdOffset, $cd, 0, $info.CdSize)
$entries = @(Parse-ZipEntries $cd)
Check 'Get-ZipTailInfo entry count' $info.Count $entries.Count
CheckTrue 'Parse-ZipEntries sees the x86 child' (@($entries | Where-Object { $_.Name -eq 'App.Package_1.0.0.0_x86.appx' }).Count -eq 1)
CheckTrue 'Parse-ZipEntries sees the bundle manifest' (@($entries | Where-Object { $_.Name -like '*AppxBundleManifest.xml' }).Count -eq 1)
$x86e = $entries | Where-Object { $_.Name -eq $fx.X86Name } | Select-Object -First 1
# The whole remote-extraction trick depends on this: every offset the central
# directory reports must land exactly on a local file header (PK\x03\x04).
$ok = @($entries | Where-Object {
        $h = $_.HeaderAt
        $bytes[$h] -eq 0x50 -and $bytes[$h + 1] -eq 0x4B -and $bytes[$h + 2] -eq 0x03 -and $bytes[$h + 3] -eq 0x04
    })
Check 'every entry offset lands on a local file header' $ok.Count $entries.Count
Check 'the children are stored uncompressed (method 0)' $x86e.Method 0
Check 'the recorded size is the real child size' $x86e.Packed $fx.X86.Length
# Get-DataStart's formula (local header offset + 30 + name + extra) has to point at
# the child's first byte, or a range-extracted download is garbage.
$h = $x86e.HeaderAt
$dataStart = $h + 30 + (U16 $bytes ($h + 26)) + (U16 $bytes ($h + 28))
$slice = New-Object byte[] $x86e.Packed
[Array]::Copy($bytes, $dataStart, $slice, 0, $x86e.Packed)
Check 'the computed data offset points at the child itself' (Get-Sha256Hex $slice) (Get-Sha256Hex $fx.X86)
# NB: hex literals in argument position need their own parens, or PowerShell hands
# the function the text "0x1234" instead of the number.
Check 'U16 little-endian' (U16 ([byte[]]@(0x34, 0x12)) 0) (0x1234)
Check 'U32 little-endian' (U32 ([byte[]]@(0x78, 0x56, 0x34, 0x12)) 0) (0x12345678)
Check 'U64 little-endian' (U64 ([byte[]]@(0, 0, 0, 0, 1, 0, 0, 0)) 0) 4294967296

# ---------------------------------------------------------------- bundle deps
Section 'bundle dependencies (the 0x80073CF3 install bug)'
$need86 = @(Get-NeededDependencyNames -PkgPath $bundle -Arch x86)
Check 'x86 child deps count' $need86.Count 1
Check 'x86 child deps value' ($need86 -join ',') 'Microsoft.VCLibs.140.00'
$need64 = @(Get-NeededDependencyNames -PkgPath $bundle -Arch x64)
Check 'x64 child deps value' ($need64 -join ',') 'Microsoft.VCLibs.140.00,Microsoft.VCLibs.140.00.UWPDesktop'
CheckTrue 'the unused UWPDesktop dep is NOT offered to x86' ($need86 -notcontains 'Microsoft.VCLibs.140.00.UWPDesktop')

$rootBundle = Join-Path $work 'Root_1.0.0.0_neutral.appxbundle'
$null = New-BundleFile $rootBundle -ManifestAtRoot
Check 'bundle manifest at the root still works' ((@(Get-NeededDependencyNames -PkgPath $rootBundle -Arch x86)) -join ',') 'Microsoft.VCLibs.140.00'

$dashBundle = Join-Path $work 'Dash_1.0.0.0_neutral.appxbundle'
$null = New-BundleFile $dashBundle -OldStyleFileName
Check 'dash-style child names still work' ((@(Get-NeededDependencyNames -PkgPath $dashBundle -Arch x86)) -join ',') 'Microsoft.VCLibs.140.00'

$plain = Join-Path $work 'Plain_1.0.0.0_x86.appx'
[IO.File]::WriteAllBytes($plain, (New-ChildPackageBytes 'Plain' '1.0.0.0' 'x86' @('Microsoft.NET.Native.Runtime.1.7')))
Check 'plain package read from its own manifest' ((@(Get-NeededDependencyNames -PkgPath $plain -Arch x86)) -join ',') 'Microsoft.NET.Native.Runtime.1.7'
$notPkg = Join-Path $work 'not-a-package.bin'
[IO.File]::WriteAllBytes($notPkg, [byte[]](1, 2, 3, 4))
Check 'unreadable file yields no deps' (@(Get-NeededDependencyNames -PkgPath $notPkg -Arch x86).Count) 0
Check 'missing file yields no deps' (@(Get-NeededDependencyNames -PkgPath (Join-Path $work 'nope.appx') -Arch x86).Count) 0

# ---------------------------------------------------------------- plan picking
Section 'plan selection (offline, from a fake Store listing)'
function New-File([string]$name, [long]$size = 1000) {
    [pscustomobject]@{ Name = $name; Url = "https://example.invalid/$name"; Size = $size; Sha1 = 'x' }
}
$cat = [pscustomobject]@{ Family = 'App.Package_abc123'; Title = 'App'; Version = '1.0.0.0'; Archs = @('x64', 'x86'); Kind = 'packaged' }
$files = @(
    (New-File 'App.Package_1.0.0.0_neutral_~_abc123.msixbundle' 5000),
    (New-File 'App.Package_0.9.0.0_x64__abc123.appx' 4000),
    (New-File 'Microsoft.VCLibs.140.00_14.0.33519.0_x64__8wekyb3d8bbwe.appx' 700),
    (New-File 'Microsoft.VCLibs.140.00_13.0.29000.0_x64__8wekyb3d8bbwe.appx' 690),
    (New-File 'Microsoft.NET.Native.Framework.1.7_1.7.27413.0_x86__8wekyb3d8bbwe.appx' 200),
    (New-File 'ignore-me.msixupload' 100),
    (New-File 'ignore-me.blockmap' 10)
)
$pl = Select-Packages -Files $files -Catalog $cat -Arch 'x64'
Check 'the bundle is chosen as the app' $pl.App.Name 'App.Package_1.0.0.0_neutral_~_abc123.msixbundle'
Check 'only the newest framework version is kept' $pl.Deps.Count 1
Check 'the newest framework is the right one' $pl.Deps[0].Name 'Microsoft.VCLibs.140.00_14.0.33519.0_x64__8wekyb3d8bbwe.appx'
CheckTrue "the app's own older build is never a dependency" (-not (@($pl.Deps | ForEach-Object { $_.Name }) -like 'App.Package_*'))
CheckTrue 'the wrong-architecture framework is dropped' (-not (@($pl.Deps | ForEach-Object { $_.Name }) -like '*_x86__*'))
CheckTrue 'uploads and blockmaps are ignored' (@($pl.All | Where-Object { $_.Name -like 'ignore-*' }).Count -eq 0)

$noBundle = @(
    (New-File 'App.Package_2.0.0.0_x64__abc123.appx' 4000),
    (New-File 'App.Package_2.0.0.0_x86__abc123.appx' 3000)
)
Check 'x64 asked, x64 taken' (Select-Packages -Files $noBundle -Catalog $cat -Arch 'x64').App.Name 'App.Package_2.0.0.0_x64__abc123.appx'
Check 'x86 asked, x86 taken' (Select-Packages -Files $noBundle -Catalog $cat -Arch 'x86').App.Name 'App.Package_2.0.0.0_x86__abc123.appx'

# Regression: a single [pscustomobject] has no .Count in PowerShell 5.1, so the
# architecture filter used to look empty and asking for x64 could hand back x86.
$x64x86 = @(
    (New-File 'App.Package_2.0.0.0_x86__abc123.appx' 3000),
    (New-File 'App.Package_2.0.0.0_x64__abc123.appx' 4000)
)
Check 'x64 wins over x86 whatever the listing order' (Select-Packages -Files $x64x86 -Catalog $cat -Arch 'x64').App.Name 'App.Package_2.0.0.0_x64__abc123.appx'
Check 'x86 wins when x86 is asked for' (Select-Packages -Files $x64x86 -Catalog $cat -Arch 'x86').App.Name 'App.Package_2.0.0.0_x86__abc123.appx'
$first = (Select-Packages -Files $x64x86 -Catalog $cat -Arch 'x64').App.Name
$same = $true
for ($i = 0; $i -lt 25; $i++) {
    if ((Select-Packages -Files $x64x86 -Catalog $cat -Arch 'x64').App.Name -ne $first) { $same = $false }
}
CheckTrue 'the same listing always picks the same package' $same
Check 'Get-ArchRank is 0 for the asked-for architecture' (Get-ArchRank 'A_2.0.0.0_x64__x.appx' 'x64') 0
Check 'Get-ArchRank falls back in chain order' (Get-ArchRank 'A_2.0.0.0_x86__x.appx' 'x64') 1
Check 'Get-ArchRank ranks an unknown architecture last' (Get-ArchRank 'A_2.0.0.0_arm__x.appx' 'x64') 2
Check 'Get-ArchRank ranks a nameless file last' (Get-ArchRank 'A.exe' 'x64') 99
Check 'Get-ArchRank on a bundle is neutral' (Get-ArchRank 'A_2.0.0.0_neutral_~_x.msixbundle' 'x64') 2

$x86Only = @((New-File 'App.Package_2.0.0.0_x86__abc123.appx' 3000))
Check 'x86 fallback when there is no x64' (Select-Packages -Files $x86Only -Catalog $cat -Arch 'x64').App.Name 'App.Package_2.0.0.0_x86__abc123.appx'

$noDepsPlan = Select-Packages -Files $files -Catalog $cat -Arch 'x64'
$script:NoDeps = $true
$withNoDeps = Select-Packages -Files $files -Catalog $cat -Arch 'x64'
$script:NoDeps = $false
Check '-NoDeps leaves dependencies out' $withNoDeps.Deps.Count 0

$threw = $false
try { Select-Packages -Files @((New-File 'readme.txt' 1)) -Catalog $cat -Arch 'x64' | Out-Null } catch { $threw = $true }
CheckTrue 'a listing with nothing installable throws' $threw

# ---------------------------------------------------------------- encrypted builds
Section 'encrypted Store builds (the Netflix trap)'
Check 'Get-FileKind emsixbundle' (Get-FileKind 'a.emsixbundle') 'bundle'
Check 'Get-FileKind eappxbundle' (Get-FileKind 'a.eappxbundle') 'bundle'
Check 'Get-FileKind emsix' (Get-FileKind 'a.emsix') 'package'
Check 'Get-FileKind eappx' (Get-FileKind 'a.eappx') 'package'
Check 'Test-EncryptedName on emsixbundle' (Test-EncryptedName 'a.emsixbundle') $true
Check 'Test-EncryptedName on eappxbundle' (Test-EncryptedName 'a.eappxbundle') $true
Check 'Test-EncryptedName on emsix' (Test-EncryptedName 'a.emsix') $true
Check 'Test-EncryptedName on msixbundle' (Test-EncryptedName 'a.msixbundle') $false
Check 'Test-EncryptedName on msix' (Test-EncryptedName 'a.msix') $false
Check 'Test-EncryptedName on an installer' (Test-EncryptedName 'setup.exe') $false
# The real Netflix listing, as the Store hands it over: a tiny old bundle plus the
# current 100 MB one, which is encrypted.
$ncat = [pscustomobject]@{ Family = '4DF9E0F8.Netflix_mcm4njqhnhss8'; Title = 'Netflix'; Version = '7.0.8.0'; Archs = @('neutral'); Kind = 'packaged' }
$nfiles = @(
    (New-File '4DF9E0F8.Netflix_7.0.8.0_neutral_~_mcm4njqhnhss8.msixbundle' 600000),
    (New-File '4DF9E0F8.Netflix_8.53.0.70_neutral_~_mcm4njqhnhss8.emsixbundle' 105000000),
    (New-File '4DF9E0F8.Netflix_8.53.0.70_neutral_~_mcm4njqhnhss8.BlockMap' 100),
    (New-File 'Microsoft.VCLibs.140.00_14.0.33519.0_x64__8wekyb3d8bbwe.appx' 900000)
)
$np = Select-Packages -Files $nfiles -Catalog $ncat -Arch 'x64'
Check 'the newest normal build is picked, not the encrypted one' $np.App.Name '4DF9E0F8.Netflix_7.0.8.0_neutral_~_mcm4njqhnhss8.msixbundle'
Check 'the build that was passed over is reported' ($np.Encrypted.Name) '4DF9E0F8.Netflix_8.53.0.70_neutral_~_mcm4njqhnhss8.emsixbundle'
$ne = Select-Packages -Files $nfiles -Catalog $ncat -Arch 'x64' -Encrypted
Check '-Encrypted takes the encrypted build' $ne.App.Name '4DF9E0F8.Netflix_8.53.0.70_neutral_~_mcm4njqhnhss8.emsixbundle'
Check '-Encrypted has nothing to report as skipped' ($null -eq $ne.Encrypted) $true
$onlyEnc = @((New-File 'App_1.0.0.0_neutral_~_abc.emsixbundle' 5000))
$oe = Select-Packages -Files $onlyEnc -Catalog $cat -Arch 'x64'
Check 'a listing with only an encrypted build still yields one' $oe.App.Name 'App_1.0.0.0_neutral_~_abc.emsixbundle'
Check 'and does not claim it skipped anything' ($null -eq $oe.Encrypted) $true

# ---------------------------------------------------------------- offline kit
Section 'offline kit generation'
$kitDir = Join-Path $work 'kit'
New-Item -ItemType Directory -Force -Path $kitDir | Out-Null
$kitBundle = Join-Path $kitDir 'App.Package_1.0.0.0_neutral_~_abc123.appxbundle'
$null = New-BundleFile $kitBundle
[pscustomobject]@{
    productId     = '9ABC'
    title         = 'Test App'
    publisher     = 'Test'
    version       = '1.0.0.0'
    architecture  = 'x86'
    app           = 'App.Package_1.0.0.0_neutral_~_abc123.appxbundle'
    extractedFrom = ''
    resources     = @()
    dependencies  = @(
        'App.Package_0.9.0.0_x64__abc123.appx',
        'Microsoft.VCLibs.140.00.UWPDesktop_14.0.33728.0_x86__8wekyb3d8bbwe.appx',
        'Microsoft.VCLibs.140.00_14.0.33519.0_x86__8wekyb3d8bbwe.appx'
    )
} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $kitDir 'store-manifest.json') -Encoding UTF8

Write-OfflineKit -Folder $kitDir
CheckTrue 'install.cmd written' (Test-Path -LiteralPath (Join-Path $kitDir 'install.cmd'))
CheckTrue 'install.ps1 written' (Test-Path -LiteralPath (Join-Path $kitDir 'install.ps1'))
CheckTrue 'kit.json written' (Test-Path -LiteralPath (Join-Path $kitDir 'kit.json'))

$kit = Get-Content -LiteralPath (Join-Path $kitDir 'kit.json') -Raw -Encoding UTF8 | ConvertFrom-Json
Check 'kit keeps only the dependencies the app needs' (@($kit.dependencies).Count) 1
Check 'kit dependency is the used one' (@($kit.dependencies)[0]) 'Microsoft.VCLibs.140.00_14.0.33519.0_x86__8wekyb3d8bbwe.appx'

$cmdBytes = [IO.File]::ReadAllBytes((Join-Path $kitDir 'install.cmd'))
$nonAscii = @($cmdBytes | Where-Object { $_ -gt 127 }).Count
Check 'install.cmd is pure ASCII' $nonAscii 0
$bareLf = 0
for ($i = 0; $i -lt $cmdBytes.Length; $i++) { if ($cmdBytes[$i] -eq 10 -and ($i -eq 0 -or $cmdBytes[$i - 1] -ne 13)) { $bareLf++ } }
Check 'install.cmd has no bare LF' $bareLf 0
$ps1Bytes = [IO.File]::ReadAllBytes((Join-Path $kitDir 'install.ps1'))
Check 'install.ps1 starts with a UTF-8 BOM' (('{0:X2}{1:X2}{2:X2}' -f $ps1Bytes[0], $ps1Bytes[1], $ps1Bytes[2])) 'EFBBBF'
$ps1Text = [IO.File]::ReadAllText((Join-Path $kitDir 'install.ps1'), [Text.Encoding]::UTF8)
CheckTrue 'install.ps1 self-heals on an unused dependency' ($ps1Text -match 'provided but not used')
CheckTrue 'install.ps1 tells the user when Add-AppxPackage is missing' ($ps1Text -match 'Add-AppxPackage')

# ---------------------------------------------------------------- the split layout
# The tool is shipped as two small entry scripts plus lib\*.ps1. A file that goes
# missing - or an entry script that stops dot-sourcing one - would only show up as
# a strange failure in the middle of a download, so it is checked here.
Section 'the files the tool is made of'
# every file that makes up the tool, for the checks that look for a name in
# whichever file holds it
$allText = (@($toolFiles) + @($GuiPs1) | ForEach-Object { [IO.File]::ReadAllText($_, [Text.Encoding]::UTF8) }) -join "`r`n"
function Get-LoaderParts([string]$File) {
    $txt = [IO.File]::ReadAllText($File, [Text.Encoding]::UTF8)
    $m = [regex]::Match($txt, "foreach \(\`$part in @\(([^)]*)\)\)")
    if (-not $m.Success) { return @() }
    return @([regex]::Matches($m.Groups[1].Value, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value })
}
$cliParts = Get-LoaderParts $ToolPs1
$guiParts = Get-LoaderParts $GuiPs1
CheckTrue 'Store-Offline.ps1 dot-sources its parts' ($cliParts.Count -ge 5)
CheckTrue 'Store-Gui.ps1 dot-sources its parts' ($guiParts.Count -ge 5)
foreach ($p in @($cliParts + $guiParts)) {
    CheckTrue ("  lib\$p is there") (Test-Path -LiteralPath (Join-Path $LibDir $p))
}
CheckTrue 'Store-Offline.ps1 runs under Set-StrictMode' ([IO.File]::ReadAllText($ToolPs1, [Text.Encoding]::UTF8) -match 'Set-StrictMode -Version Latest')
CheckTrue 'Store-Gui.ps1 runs under Set-StrictMode' ([IO.File]::ReadAllText($GuiPs1, [Text.Encoding]::UTF8) -match 'Set-StrictMode -Version Latest')
# every part a stray file in lib\ that nothing loads is dead weight nobody tests
$stray = @(Get-ChildItem -LiteralPath $LibDir -Filter '*.ps1' |
    Where-Object { $cliParts -notcontains $_.Name -and $guiParts -notcontains $_.Name } |
    ForEach-Object { $_.Name })
Check 'no unloaded file in lib\' ($stray -join ', ') ''

# ---------------------------------------------------------------- the one-file build
# Store-Offline.cmd carries the whole tool packed at the bottom of itself. When the
# code changes and nobody rebuilds it, the next PC keeps running an old build - so
# the packed payload is unpacked here and compared against the files next to it.
Section 'the one-file build (Store-Offline.cmd)'
# one directory can hold other .txt files (E:\hermes\hermes-offline does), and the
# build has to be identical from both - so the tool readme is picked by content,
# the same way make-portable.ps1 and the sync script pick it
function Get-ToolFileList {
    $ids = New-Object System.Collections.Generic.List[string]
    foreach ($n in @('idm.cmd', 'idm-console.cmd', 'Store-Offline.ps1', 'Store-Gui.ps1')) {
        $ids.Add("$n|" + (Get-FileHash -LiteralPath (Join-Path $ToolDir $n) -Algorithm SHA256).Hash)
    }
    foreach ($f in @(Get-ChildItem -LiteralPath $LibDir -File -Filter '*.ps1' | Sort-Object Name)) {
        $ids.Add(("lib\" + $f.Name + "|" + (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash))
    }
    foreach ($f in @(Get-ChildItem -LiteralPath $ToolDir -File -Filter '*.txt')) {
        if ([IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8) -match '^Store-Offline') {
            $ids.Add(($f.Name + "|" + (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash))
        }
    }
    return $ids
}

function Get-PortablePayload([string]$Path) {
    $raw = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
    $i = $raw.IndexOf('#PAYLOAD#')
    if ($i -lt 0) { throw "$Path has no #PAYLOAD# in it" }
    $b64 = $raw.Substring($i + '#PAYLOAD#'.Length) -replace '[^A-Za-z0-9+/=]', ''
    $bytes = [Convert]::FromBase64String($b64)
    $ms = New-Object IO.MemoryStream -ArgumentList (, $bytes)
    $gz = New-Object IO.Compression.GZipStream -ArgumentList $ms, ([IO.Compression.CompressionMode]::Decompress)
    $sr = New-Object IO.StreamReader -ArgumentList $gz, ([Text.Encoding]::UTF8)
    $out = ($sr.ReadToEnd() | ConvertFrom-Json)
    $sr.Dispose(); $gz.Dispose(); $ms.Dispose()
    return $out
}

$oneFile = Join-Path $ToolDir 'Store-Offline.cmd'
CheckTrue 'the one-file build is there' (Test-Path -LiteralPath $oneFile)
$portable = Get-PortablePayload $oneFile
CheckTrue 'its payload unpacks' (@($portable.f).Count -gt 0)

$ids = Get-ToolFileList
$shaAll = [Security.Cryptography.SHA256]::Create()
$ver = ([BitConverter]::ToString($shaAll.ComputeHash([Text.Encoding]::UTF8.GetBytes((@($ids) -join "`n")))) -replace '-', '').Substring(0, 24).ToLower()
Check 'the packed version matches the code next to it' ([string]$portable.v) $ver
Check 'it carries every file of the tool' (@($portable.f).Count) $ids.Count
$badP = 0
foreach ($pf in @($portable.f)) {
    $mine = [Convert]::FromBase64String([string]$pf.d)
    $orig = [IO.File]::ReadAllBytes((Join-Path $ToolDir ([string]$pf.p)))
    if (($orig.Length -ne $mine.Length) -or (Compare-Object $orig $mine -SyncWindow 0)) {
        $badP++; Write-Host ("           differs from the real file: {0}" -f $pf.p) -ForegroundColor Red
    }
}
Check ('all {0} packed files are byte-identical' -f @($portable.f).Count) $badP 0

# one function of the tool or the window, by name, from wherever it lives
function Find-ToolFunctionText([string]$Name) {
    foreach ($f in (@($toolFiles) + @($GuiPs1))) {
        $err = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$null, [ref]$err)
        $d = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name }, $true))
        if ($d.Count) { return $d[0].Extent.Text }
    }
    return ''
}

# ---------------------------------------------------------------- the options
# What the checkboxes in the window do to the command line the child process gets.
Section 'the GUI options reach the command line'
$cmbArch = New-Object psobject -Property @{ SelectedItem = (New-Object psobject -Property @{ Content = 'x64' }) }
$chkExtract = New-Object psobject -Property @{ IsChecked = $true }
$chkDeps = New-Object psobject -Property @{ IsChecked = $true }
$chkKit = New-Object psobject -Property @{ IsChecked = $false }
$chkEncrypted = New-Object psobject -Property @{ IsChecked = $false }
Check 'a plain download' ((Get-CommonArgs) -join ' ') '-Arch x64 -Extract'
$chkEncrypted.IsChecked = $true
CheckTrue 'the encrypted builds are passed on when asked for' ((Get-CommonArgs) -contains '-Encrypted')
$chkEncrypted.IsChecked = $false
CheckTrue 'and are left out by default' (-not ((Get-CommonArgs) -contains '-Encrypted'))
$chkKit.IsChecked = $true
CheckTrue 'the offline kit is passed on' ((Get-CommonArgs) -contains '-Kit')
$chkDeps.IsChecked = $false
CheckTrue 'so is -NoDeps' ((Get-CommonArgs) -contains '-NoDeps')
$chkDeps.IsChecked = $true
$chkExtract.IsChecked = $false
CheckTrue 'and leaving -Extract off works' (-not ((Get-CommonArgs) -contains '-Extract'))
$chkExtract.IsChecked = $true
$chkKit.IsChecked = $false
# the control has to be exported to script scope by the entry script, or Set-Lang
# and Get-CommonArgs would read a variable that is not there
CheckTrue 'the new checkbox is wired up in Store-Gui.ps1' ($allText -match "'chkEncrypted'")

# ---------------------------------------------------------------- one window only
# Opening the tool used to put two black boxes on screen: the launcher's console,
# then - because Windows Terminal hosts every console and ignores -WindowStyle
# Hidden - the PowerShell console of the window itself, which stayed behind the
# window for the whole session. Everything the window runs now asks for no
# console at all.
Section 'the tool opens one window, not two'
$idmText = [IO.File]::ReadAllText((Join-Path $ToolDir 'idm.cmd'))
CheckTrue 'the launcher no longer wakes PowerShell just to ask about WPF' (-not ($idmText -match 'Add-Type -AssemblyName PresentationFramework'))
CheckTrue 'it looks for the WPF files instead (instant, no window)' ($idmText -match 'WPF\\PresentationFramework\.dll')
CheckTrue 'the window is started with no console where Windows can' ($idmText -match '--headless')
CheckTrue 'and the hidden-window way stays as the fallback' ($idmText -match '-WindowStyle Hidden')
CheckTrue 'the no-console launch is only used on Windows 10 1809 and newer' ($idmText -match 'GEQ 17763')

$capture = Find-ToolFunctionText 'Invoke-Capture'
CheckTrue 'search and preview run with no console' ($capture -match 'Start-NoWindow')
$jobRun = Find-ToolFunctionText 'Start-JobRun'
CheckTrue 'downloads run with no console' ($jobRun -match 'Start-NoWindow')
$noWin = Find-ToolFunctionText 'Start-NoWindow'
CheckTrue 'the helper creates the child with no console' ($noWin -match 'CreateNoWindow')
CheckTrue 'the helper gives a quoted line its own pair of quotes' ($noWin -match "StartsWith\('""'\)")
CheckTrue 'no -WindowStyle Hidden is left in the window code' (-not (($capture + $jobRun) -match 'WindowStyle'))

# the helper really works, with a path that has a space in it too
$nw1 = Join-Path $work 'nowindow.out'
$nw2 = Join-Path $work 'no window 2.out'
$cmdExe = Join-Path $env:SystemRoot 'System32\cmd.exe'
Remove-Item -LiteralPath $nw1, $nw2 -Force -ErrorAction SilentlyContinue
Check 'a windowless child runs' (Start-NoWindow ('echo one > "{0}"' -f $nw1) -Wait) 0
Check 'and its output still lands in the file' ((Get-Content -LiteralPath $nw1 -Raw).Trim()) 'one'
Check 'a quoted line with a space in the path works the same' (Start-NoWindow ('"{0}" /c echo two > "{1}"' -f $cmdExe, $nw2) -Wait) 0
Check 'with the output in that file too' ((Get-Content -LiteralPath $nw2 -Raw).Trim()) 'two'

# ---------------------------------------------------------------- the languages
# The window is bilingual. A key spelled differently in one of the two tables shows
# up as the raw key name in that language - the kind of thing nobody notices until
# a screenshot - so the two tables are compared instead.
Section 'the two languages carry the same keys'
$coreAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $LibDir 'gui-core.ps1'), [ref]$null, [ref]$null)
$sAssign = @($coreAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$script:S' }, $true))
Check 'the language tables are found' $sAssign.Count 1
$S = Invoke-Expression $sAssign[0].Right.Extent.Text
$enKeys = @($S['en'].Keys | Sort-Object)
$arKeys = @($S['ar'].Keys | Sort-Object)
CheckTrue 'the tables are not empty' ($enKeys.Count -gt 30)
Check 'arabic has every english key' (@($enKeys | Where-Object { $arKeys -notcontains $_ }) -join ', ') ''
Check 'english has every arabic key' (@($arKeys | Where-Object { $enKeys -notcontains $_ }) -join ', ') ''
CheckTrue 'the encrypted checkbox has a label in both' (($enKeys -contains 'chkEncrypted') -and ($arKeys -contains 'chkEncrypted'))

# ---------------------------------------------------------------- PS 5.1 traps
Section 'PowerShell 5.1 traps that have burned us before'
$list = New-Object System.Collections.Generic.List[object]
$list.Add([pscustomobject]@{ folder = 'x'; state = 'stale' })
$threw = $false
try { @($list) | ConvertTo-Json -Depth 4 | Out-Null } catch { $threw = $true }
CheckTrue 'a generic List breaks @(...) | ConvertTo-Json (hence the array cast)' $threw
$arr = [object[]]$list.ToArray()
$jsonOk = ConvertTo-Json -InputObject $arr -Depth 4
CheckTrue 'object[] serialises fine' ($jsonOk -match 'stale')
CheckTrue 'JSON of one item is still an array' ($jsonOk.TrimStart().StartsWith('['))
$empty = ConvertTo-Json -InputObject ([object[]]@()) -Depth 4
CheckTrue 'JSON of nothing is still an array' ($empty -match '^\s*\[\s*\]\s*$')

# The .Count that cost us a wrong-architecture download: a bare [pscustomobject]
# has no .Count at all. Without Set-StrictMode that reads as $null and -not $x.Count
# then looks true; with it the same read is an error. Either way the answer is the
# same - wrap it in @() - but now the mistake cannot pass silently.
$countThrew = $false
try { $null = ([pscustomobject]@{ a = 1 }).Count } catch { $countThrew = $true }
CheckTrue 'a bare [pscustomobject] has no .Count (an error under Set-StrictMode)' $countThrew
Check 'wrapping it in @() gives a real count' (@([pscustomobject]@{ a = 1 }).Count) 1
# Sort-Object cannot break version ties by itself in PowerShell 5.1, so any pick
# between equals needs an explicit tie-breaker.
$tie = @([pscustomobject]@{ n = 'a'; v = 1 }, [pscustomobject]@{ n = 'b'; v = 1 }, [pscustomobject]@{ n = 'c'; v = 1 })
$tiePick = @($tie | Sort-Object { $_.v } -Descending)[0].n
$tiePick2 = @($tie | Sort-Object -Property @{ Expression = { $_.v }; Descending = $true }, @{ Expression = { $_.n }; Ascending = $true })[0].n
Check 'an explicit tie-breaker makes a tie pick predictable' ("$tiePick/$tiePick2" -match '(a|b|c)/(a)') $true

# ---------------------------------------------------------------- batch + space
# -Batch turns a text file into a download queue: ids, Store links, # comments.
# Before anything moves, Invoke-Download looks at the drive the target folder
# lives on and says so when the free space cannot hold what is coming.
Section 'batch list and disk space'
$batchFile = Join-Path $work 'apps.txt'
[IO.File]::WriteAllLines($batchFile,
    @('# my shopping list', '', '9NKSQGP7F2NH', 'https://apps.microsoft.com/detail/9NBLGGH516XP', 'whatsapp'),
    (New-Object Text.ASCIIEncoding))
$bl = Read-BatchLines $batchFile
Check 'comments and empty lines drop out' $bl.Count 3
Check 'a bare id is read as itself' (Get-BatchId $bl[0]) '9NKSQGP7F2NH'
Check 'a Store link hands its id back' (Get-BatchId $bl[1]) '9NBLGGH516XP'
Check 'a bare word is not an id' (Get-BatchId $bl[2]) ''
Check 'an empty url says nothing' (Get-IdFromUrl '') ''
Check 'a link without an id says nothing' (Get-IdFromUrl 'https://example.com/x') ''
Check 'the plain -Url form still works' (Get-IdFromUrl 'https://apps.microsoft.com/detail/9NKSQGP7F2NH') '9NKSQGP7F2NH'
$Extract = $true
$Arch = 'x64'
$Kit = $true
Check 'the switches travel to the child' (@(Get-BatchChildArgs '9NKSQGP7F2NH') -join ' ') '-ProductId 9NKSQGP7F2NH -Download -Arch x64 -Extract -Kit'
$Kit = $false
$Extract = $false
Check 'the list keeps working with no options' (@(Get-BatchChildArgs 'XP9KN75RRB9NHS') -join ' ') '-ProductId XP9KN75RRB9NHS -Download -Arch x64'
CheckTrue 'the drive under a folder is a real number' ((Get-FreeBytes $ToolDir) -gt 0)
Check 'no folder means unknown' ([string](Get-FreeBytes '')) '-1'
$dlFn = Find-ToolFunctionText 'Invoke-Download'
CheckTrue 'Invoke-Download looks at the drive first' ($dlFn -match 'Get-FreeBytes')
$iconFn = Find-ToolFunctionText 'Set-Icon'
CheckTrue 'the app icon is cached on disk' ($iconFn -match 'IconDir')
CheckTrue 'the icon cache lives next to the GUI tmp' ([IO.File]::ReadAllText((Join-Path $LibDir 'gui-state.ps1'), [Text.Encoding]::UTF8) -match 'IconDir')
CheckTrue 'the window title says which copy runs' ([IO.File]::ReadAllText($GuiPs1, [Text.Encoding]::UTF8) -match '\$window\.Title\s*=\s*"Store-Offline\s+-\s+\$script:Root"')

# ---------------------------------------------------------------- the unpackaged Win32 installer
# Docker Desktop and its like are not MSIX: the Store only links to the
# publisher's own installer. That one comes from a CDN, not from FE3, so there is
# no revision to renew its link with - and the URL the listing hands out is
# percent-encoded. The first of those two cost a stopped download: StrictMode
# refused to read a key the job never carried.
Section 'the unpackaged Win32 installer'
$cliText = [IO.File]::ReadAllText((Join-Path $ToolDir 'Store-Offline.ps1'), [Text.Encoding]::UTF8)
$win32Job = @($cliText -split "`n" | Where-Object { $_ -match 'Name = \$name;' }) -join ' '
CheckTrue 'the Win32 job carries every key a download job reads' ($win32Job -match 'Rev' -and $win32Job -match 'SrcSha1' -and $win32Job -match 'Src')
$encodedName = [IO.Path]::GetFileName(([Uri]'https://desktop.docker.com/win/main/amd64/242831/Docker Desktop Installer.exe').AbsolutePath)
Check 'an encoded installer url decodes to a readable name' ([Uri]::UnescapeDataString($encodedName)) 'Docker Desktop Installer.exe'
CheckTrue 'the installer name is decoded before it is written' ($cliText -match 'UnescapeDataString')
$jobNoRev = [pscustomobject]@{ Name = 'x' }
Check 'a job with no revision reads as an empty one' ([string](Get-Prop $jobNoRev 'Rev' '')) ''
CheckTrue 'Invoke-Download reads the revision through Get-Prop' ($dlFn -match 'Get-Prop \$j')
CheckTrue 'and the bundle slices read theirs the same way' ($dlFn -match "'SrcSha1'")

Check 'Format-Eta under an hour' (Format-Eta 3492) '58m 12s'
Check 'Format-Eta just under an hour' (Format-Eta 3599) '59m 59s'
Check 'Format-Eta hours' (Format-Eta 7080) '1h 58m'
Check 'Format-Eta seconds' (Format-Eta 45) '45s'
Check 'Format-Eta zero' (Format-Eta 0) ''
Check 'Format-Size MB' (Format-Size 216000000) '206.0 MB'
Check 'Format-Size GB' (Format-Size 3221225472) '3.00 GB'
Check 'Test-ProductId packaged' (Test-ProductId '9NKSQGP7F2NH') $true
Check 'Test-ProductId win32' (Test-ProductId 'XP9KN75RRB9NHS') $true
Check 'Test-ProductId rejects a name' (Test-ProductId 'whatsapp') $false
Check 'Test-ProductId rejects a bad length' (Test-ProductId '9NKSQGP7F2N') $false

# ---------------------------------------------------------------- Stop button
# Stop can only be pressed while something runs. The XAML ships it disabled, and
# nothing used to switch it on at all - the button was dead. The helper decides the
# state, and every place that changes what is running has to refresh it.
Section 'the GUI Stop button'
$btnStop = New-Object psobject -Property @{ IsEnabled = $false }
$script:Running = $null
Set-StopButton
Check 'Stop is grey when nothing runs' $btnStop.IsEnabled $false
$script:Running = 'a job'
Set-StopButton
Check 'Stop lights up while a job runs' $btnStop.IsEnabled $true
$script:Running = $null
Set-StopButton
Check 'Stop goes grey again when the queue empties' $btnStop.IsEnabled $false

# the function may live in any of the files that make up the tool
$guiAst = [System.Management.Automation.Language.Parser]::ParseInput($allText, [ref]$null, [ref]$null)
foreach ($fn in @('Start-JobRun', 'Stop-JobRun', 'Close-Job', 'On-Tick')) {
    $def = @($guiAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $fn }, $true))
    Check ("  {0} exists" -f $fn) ($def.Count -eq 1) $true
    CheckTrue ("  {0} refreshes the Stop button" -f $fn) ($def[0].Extent.Text -match 'Set-StopButton')
}

# ---------------------------------------------------------------- direct file list (FE3)
# The Windows Update messages are long and easy to get subtly wrong, so the parsing
# is checked against a real reply captured from the service (tests\fixtures\): if
# the shape of that reply ever changes, these fail instead of a download.
Section "Microsoft's own file list (FE3)"
$fixDir = Join-Path $here 'fixtures'
$syncPath = Join-Path $fixDir 'fe3-sync.xml'
$infoPath = Join-Path $fixDir 'fe3-info.xml'
CheckTrue 'the captured SyncUpdates reply is there' (Test-Path -LiteralPath $syncPath)
CheckTrue 'the captured GetExtendedUpdateInfo2 reply is there' (Test-Path -LiteralPath $infoPath)

Check 'Get-Fe3Tag reads a tag' (Get-Fe3Tag '<a><b>hello</b></a>' 'b') 'hello'
Check 'Get-Fe3Tag unescapes' (Get-Fe3Tag '<a><b>x&amp;y</b></a>' 'b') 'x&y'
Check 'Get-Fe3Block reads a block' (Get-Fe3Block '<a><b><c>1</c></b></a>' 'b') '<c>1</c>'
Check 'Get-Fe3Block on nothing is empty' (Get-Fe3Block '' 'b') $null
# the digests in the fragments are base64; the downloader verifies hex
Check 'a base64 digest converts to hex' (ConvertTo-HexDigest ([Convert]::ToBase64String([byte[]](0..19)))) '000102030405060708090a0b0c0d0e0f10111213'
Check 'a digest of the wrong length is refused' (ConvertTo-HexDigest 'AAAA') ''

$syncXml = [IO.File]::ReadAllText($syncPath, [Text.Encoding]::UTF8)
$sync = ConvertFrom-Fe3Sync $syncXml
Check 'core fragments parsed' $sync.Core.Count 2
Check 'extended fragments parsed' $sync.Ext.Count 2
CheckTrue 'the newer cookie is read back' ($sync.Cookie.Length -gt 0)
CheckTrue 'its expiry is read back' ($sync.Expiration -match '^\d{4}-\d\d-\d\dT')

$revTable = @{}
$pkgs = @(ConvertFrom-Fe3Fragments -Core $sync.Core -Ext $sync.Ext -Revs $revTable)
# two updates x (one package + one block map) - only the packages survive
Check 'packages found' $pkgs.Count 2
Check 'no block map among them' (@($pkgs | Where-Object { $_.Name -match '\.cab$' }).Count) 0
$revsSeen = @($pkgs | ForEach-Object { $_.Rev } | Sort-Object -Unique)
Check 'they come from two revisions' $revsSeen.Count 2
Check 'both revisions are recorded for later' $revTable.Count 2

$vclibs = @($pkgs | Where-Object { $_.Name -like 'Microsoft.VCLibs.140.00.UWPDesktop_14.0.33728.0_x64*' })
Check 'the framework package is found' $vclibs.Count 1
# the CDN only knows the file as a guid - the name on disk has to come from the
# identity string the Store puts in the fragment
Check 'the framework keeps its real name' $vclibs[0].Name 'Microsoft.VCLibs.140.00.UWPDesktop_14.0.33728.0_x64__8wekyb3d8bbwe.appx'
Check 'its size is the exact one' $vclibs[0].Size 6757465
Check 'its digest is a SHA-1' $vclibs[0].Sha1.Length 40
CheckTrue 'and it is a usable hash' ($vclibs[0].Sha1 -match '^[0-9a-f]{40}$')
CheckTrue 'the revision remembers the digest' (@($revTable[$vclibs[0].Rev].Digests) -contains $vclibs[0].Sha1)
CheckTrue 'the revision remembers its identity' ($revTable[$vclibs[0].Rev].UpdateID -match '^[0-9a-f-]{36}$')

$bundle = @($pkgs | Where-Object { $_.Name -like '5319275A.WhatsAppDesktop_2.2640.100.0*' })
Check 'the app bundle is found as well' $bundle.Count 1
Check 'the bundle keeps its real name' $bundle[0].Name '5319275A.WhatsAppDesktop_2.2640.100.0_neutral_~_cv1g1gvanyjgm.msixbundle'
Check 'and its name still identifies the app family' ($bundle[0].Name -split '_')[0] '5319275A.WhatsAppDesktop'
Check 'the plan selector calls that bundle the app' ((Get-FileKind $bundle[0].Name)) 'bundle'

# an update that is not a secured fragment is not an app package, even when the
# extended half carries a file list
$b64 = [Convert]::ToBase64String([byte[]](0..19))
$coreSynth = @{ '7' = '<UpdateIdentity><UpdateID>aaaaaaaa-1111-2222-3333-444444444444</UpdateID><RevisionNumber>1</RevisionNumber></UpdateIdentity>' }
$extSynth = @{ '7' = '<UpdateIdentity><UpdateID>aaaaaaaa-1111-2222-3333-444444444444</UpdateID><RevisionNumber>1</RevisionNumber></UpdateIdentity><Files><File><FileName>b3f1c2d4-0000-1111-2222-333333333333.msix</FileName><Digest>' + $b64 + '</Digest><Size>1234</Size><InstallerSpecificIdentifier>Contoso.App_1.0.0.0_x64__abcde</InstallerSpecificIdentifier></File></Files>' }
Check 'an update with no SecuredFragment yields nothing' (@(ConvertFrom-Fe3Fragments -Core $coreSynth -Ext $extSynth -Revs @{}).Count) 0
$coreOk = @{ '7' = $coreSynth['7'] + '<SecuredFragment/>' }
$one = @(ConvertFrom-Fe3Fragments -Core $coreOk -Ext $extSynth -Revs @{})
Check 'the very same update yields one file once it is secured' $one.Count 1
Check 'and that file is named from its identity' $one[0].Name 'Contoso.App_1.0.0.0_x64__abcde.msix'

# the signed links come from the /secured call; the file is matched by its digest.
# A revision hands back a location for every file it holds (the package and its
# block map), so the digest - not the position - is what picks the right one.
$locs = ConvertFrom-Fe3Locations ([IO.File]::ReadAllText($infoPath, [Text.Encoding]::UTF8))
Check 'a location per file of the revision' $locs.Count 2
CheckTrue 'the package digest is one of them' ($locs.ContainsKey($vclibs[0].Sha1))
CheckTrue 'the link is a signed CDN url' ($locs[$vclibs[0].Sha1] -match '^https?://.+[?&]P1=\d+.+P4=')
Check 'exactly one link carries a signature' (@($locs.Values | Where-Object { $_ -match '[?&]P1=' }).Count) 1
CheckTrue 'the unsigned one is not mistaken for a link' ($locs[$vclibs[0].Sha1] -match 'tlu\.dl\.delivery')
# the whole point of renewing links: each carries its own expiry stamp
Check 'an expired link is recognised' (Test-UrlStale $locs[$vclibs[0].Sha1]) $true
Check 'an unsigned link is never called expired' (Test-UrlStale @($locs.Values | Where-Object { $_ -notmatch '[?&]P1=' })[0]) $false
Check 'a link with no P1 stamp is left alone' (Test-UrlStale 'https://example.com/x.msix') $false
CheckTrue 'the epoch helper agrees with the clock' ([Math]::Abs((Get-UnixSeconds) - [long](New-TimeSpan -Start ([datetime]::Parse('1970-01-01T00:00:00Z', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal)) -End ([datetime]::UtcNow)).TotalSeconds) -lt 5) $true
Check 'the app category is passed through to the fallback' ((Get-Command Get-StoreFilesAuto).Parameters.Keys -contains 'NoFe3') $true

# ---------------------------------------------------------------- done
Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host ('=' * 72) -ForegroundColor Cyan
if ($script:Fail -eq 0) {
    Write-Host ("  ALL PASS   ({0} checks, {1} functions imported)" -f $script:Pass, ($toolFns.Count + $guiFns.Count)) -ForegroundColor Green
} else {
    Write-Host ("  {0} PASSED, {1} FAILED" -f $script:Pass, $script:Fail) -ForegroundColor Red
}
Write-Host ('=' * 72) -ForegroundColor Cyan

exit $(if ($script:Fail -eq 0) { 0 } else { 1 })
