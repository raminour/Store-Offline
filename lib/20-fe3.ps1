# ----------------------------------------------------------------------------- # Microsoft's own file list (FE3 / Windows Update) # # Part of Store-Offline.ps1. Not runnable on its own: the entry script # dot-sources this file so that everything shares one scope. # ----------------------------------------------------------------------------- 
# ---------------------------------------------------------------- Microsoft's own file list
# store.rg-adguard.net is only a mirror of the service below: it performs this same
# handshake against Microsoft's public Windows Update endpoint (FE3) and re-serves
# the result. Doing it here shortens the chain by one party and, more usefully, lets
# a download link be minted exactly when it is needed - the links are signed and
# short-lived (the P1 stamp in the URL allows about ten minutes, which a big package
# on a slow line outlives).
#
#   1. displaycatalog gives the app's WuCategoryId - its identity in the Windows
#      Update world.
#   2. GetCookie hands out an anonymous session cookie.
#   3. SyncUpdates with that category returns the app's updates as XML fragments,
#      carrying the real file names, the exact sizes and SHA-1 digests.
#   4. GetExtendedUpdateInfo2 on the /secured endpoint returns the signed CDN URL
#      for each digest.
#
# No account and no licence: this is the same public endpoint every Windows PC talks
# to when the Store installs an app. The baseline update ids and the device
# attributes are what the Windows Update agent itself sends when it asks for the
# apps of a category.
$WuNs = 'http://www.microsoft.com/SoftwareDistribution/Server/ClientWebService'
$Fe3Base = 'https://fe3cr.delivery.mp.microsoft.com/ClientWebService/client.asmx'
$Fe3Secured = "$Fe3Base/secured"
$Fe3To = 'https://fe3.delivery.mp.microsoft.com/ClientWebService/client.asmx'
$Fe3ToSecured = "$Fe3To/secured"
$Fe3Ua = 'Windows-Update-Agent/10.0.10011.16384 Client-Protocol/2.1'
$Fe3Attrs = 'BranchReadinessLevel=CB;CurrentBranch=;OEMModel=Virtual Machine;FlightRing=Retail;AttrDataVer=21;SystemManufacturer=Microsoft Corporation;InstallLanguage=en-US;OSUILocale=en-US;InstallationType=Client;FlightingBranchName=;FirmwareVersion=Hyper-V UEFI Release v2.5;SystemProductName=Virtual Machine;OSSkuId=48;FlightContent=Mainline;App=WU_STORE;OEMName_Uncleaned=Microsoft Corporation;AppVer=0.0.0.0;OSArchitecture=AMD64;SystemSKU=None;UpdateManagementGroup=2;IsFlightingEnabled=0;IsDeviceRetailDemo=0;TelemetryLevel=3;OSVersion=10.0.22621.1;DeviceFamily=Windows.Desktop;'
# The updates a Windows PC is assumed to have already: the service uses them to
# work out which of a category's packages this machine would actually fetch.
$Fe3InstalledIds = @(
    1, 2, 3, 10, 11, 17, 19, 2359974, 2359977, 5143990, 5169043, 5169044, 5169047,
    8788830, 8806526, 9125350, 9154769, 10809856, 23110993, 23110994, 23110995,
    23110996, 23110999, 23111000, 23111001, 23111002, 23111003, 23111004,
    24513870, 28880263, 30077688, 30486944, 59830006, 59830007, 59830008,
    60484010, 62450018, 62450019, 62450020, 98959022, 98959023, 98959024,
    98959025, 98959026, 105939029, 105995585, 106017178, 107825194, 117765322,
    129905029, 130040030, 130040031, 130040032, 130040033, 133399034, 138372035,
    138372036, 139536037, 139536038, 139536039, 139536040, 142045136, 158941041,
    158941042, 158941043, 158941044, 159776047, 160733048, 160733049, 160733050,
    160733051, 160733055, 160733056, 161870057, 161870058, 161870059
)

function Get-Fe3Now { return (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ') }

# [DateTimeOffset]::FromUnixTimeSeconds arrived in .NET 4.6, and this tool still
# runs on machines with .NET 4.0, so the epoch arithmetic is done by hand.
function Get-UnixSeconds {
    $epoch = [datetime]::Parse('1970-01-01T00:00:00Z', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal)
    return [long](([datetime]::UtcNow - $epoch).TotalSeconds)
}

function ConvertTo-HexDigest([string]$Base64) {
    if (-not $Base64) { return '' }
    try {
        $hex = ([BitConverter]::ToString([Convert]::FromBase64String($Base64)) -replace '-', '').ToLowerInvariant()
        if ($hex.Length -eq 40 -or $hex.Length -eq 64) { return $hex }
    } catch { }
    return ''
}

function ConvertTo-UtcOffset([string]$Text) {
    if (-not $Text) { return [DateTimeOffset]::MinValue }
    try {
        return [DateTimeOffset]::Parse($Text, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal)
    } catch { return [DateTimeOffset]::MinValue }
}

# The fragments arrive as escaped XML inside <Xml> elements, so the plain
# string helpers are enough and no XML parser is needed to get at them.
function Get-Fe3Tag([string]$Text, [string]$Tag) {
    if (-not $Text) { return $null }
    $m = [regex]::Match($Text, "<$Tag>([^<]*)</$Tag>")
    if ($m.Success) { return (Unescape-Html $m.Groups[1].Value) }
    return $null
}
function Get-Fe3Block([string]$Text, [string]$Tag) {
    if (-not $Text) { return $null }
    $m = [regex]::Match($Text, "<$Tag>([\s\S]*?)</$Tag>")
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

function Get-Fe3Soap([string]$Uri, [string]$Body) {
    # PowerShell 5.1 refuses a Connection header here ("Keep-Alive and Close may not
    # be set using this property") and .NET keeps the socket alive on its own, so
    # only the agent is sent.
    $resp = Invoke-WebRequest -Uri $Uri -Method Post -Headers @{ 'User-Agent' = $Fe3Ua } `
        -ContentType 'application/soap+xml; charset=utf-8' -Body $Body -UseBasicParsing -TimeoutSec 120
    return $resp.Content
}

function Get-Fe3Cookie {
    $now = Get-Fe3Now
    $body = @"
<Envelope xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns="http://www.w3.org/2003/05/soap-envelope">
  <Header>
    <Action d3p1:mustUnderstand="1" xmlns:d3p1="http://www.w3.org/2003/05/soap-envelope" xmlns="http://www.w3.org/2005/08/addressing">http://www.microsoft.com/SoftwareDistribution/Server/ClientWebService/GetCookie</Action>
    <MessageID xmlns="http://www.w3.org/2005/08/addressing">urn:uuid:$([guid]::NewGuid())</MessageID>
    <To d3p1:mustUnderstand="1" xmlns:d3p1="http://www.w3.org/2003/05/soap-envelope" xmlns="http://www.w3.org/2005/08/addressing">$Fe3To</To>
    <Security d3p1:mustUnderstand="1" xmlns:d3p1="http://www.w3.org/2003/05/soap-envelope" xmlns="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd">
      <Timestamp xmlns="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd">
        <Created>$now</Created>
        <Expires>2044-08-02T20:09:03Z</Expires>
      </Timestamp>
      <WindowsUpdateTicketsToken d4p1:id="ClientMSA" xmlns:d4p1="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd" xmlns="http://schemas.microsoft.com/msus/2014/10/WindowsUpdateAuthorization"></WindowsUpdateTicketsToken>
    </Security>
  </Header>
  <Body>
    <GetCookie xmlns="$WuNs">
      <oldCookie>
        <Expiration>2016-07-27T07:18:09Z</Expiration>
      </oldCookie>
      <lastChange>2015-10-21T17:01:07.1472913Z</lastChange>
      <currentTime>$now</currentTime>
      <protocolVersion>2.50</protocolVersion>
    </GetCookie>
  </Body>
</Envelope>
"@
    $r = Get-Fe3Soap $Fe3Base $body
    $data = [string](Get-Fe3Tag $r 'EncryptedData')
    if (-not $data) { throw 'the Windows Update service returned no session cookie' }
    return [pscustomobject]@{ Data = $data; Expiration = [string](Get-Fe3Tag $r 'Expiration') }
}

# The cookie is good for hours, so it is fetched once and reused; SyncUpdates hands
# back a newer one, which then replaces it.
function Get-Fe3Session {
    $st = $script:Fe3
    if ($st -and $st.Cookie -and $st.CookieExpUtc -gt [DateTimeOffset]::UtcNow.AddMinutes(2)) { return $st.Cookie }
    $c = Get-Fe3Cookie
    if ($st) {
        $st.Cookie = $c.Data
        $st.CookieExp = $c.Expiration
        $st.CookieExpUtc = ConvertTo-UtcOffset $c.Expiration
    }
    return $c.Data
}

function Get-Fe3CookieXml {
    $null = Get-Fe3Session
    $st = $script:Fe3
    $exp = if ($st -and $st.CookieExp) { $st.CookieExp } else { '2044-08-02T20:09:03Z' }
    return '<cookie><Expiration>' + $exp + '</Expiration><EncryptedData>' + $st.Cookie + '</EncryptedData></cookie>'
}

# Reading a SyncUpdates response: the "core" fragment of an update proves it is a
# secured fragment (the kind Windows installs for a Store app), and the "extended"
# one carries its file list. Kept separate from the HTTP call so it can be tested
# against a real captured response with no network.
function ConvertFrom-Fe3Sync([string]$Xml) {
    $core = @{}
    $ext = @{}
    $new = Get-Fe3Block $Xml 'NewUpdates'
    foreach ($m in [regex]::Matches([string]$new, '<UpdateInfo>([\s\S]*?)</UpdateInfo>')) {
        $id = [string](Get-Fe3Tag $m.Groups[1].Value 'ID')
        if ($id) { $core[$id] = [string](Get-Fe3Tag $m.Groups[1].Value 'Xml') }
    }
    $updates = [string](Get-Fe3Block ([string](Get-Fe3Block $Xml 'ExtendedUpdateInfo')) 'Updates')
    foreach ($m in [regex]::Matches($updates, '<Update>([\s\S]*?)</Update>')) {
        $id = [string](Get-Fe3Tag $m.Groups[1].Value 'ID')
        if ($id) { $ext[$id] = [string](Get-Fe3Tag $m.Groups[1].Value 'Xml') }
    }
    $nc = Get-Fe3Block $Xml 'NewCookie'
    return [pscustomobject]@{
        Core       = $core
        Ext        = $ext
        Cookie     = $(if ($nc) { [string](Get-Fe3Tag $nc 'EncryptedData') } else { '' })
        Expiration = $(if ($nc) { [string](Get-Fe3Tag $nc 'Expiration') } else { '' })
    }
}

function Sync-Fe3Updates([string]$Category) {
    $null = Get-Fe3Session
    $cookieXml = Get-Fe3CookieXml
    $ids = ''
    foreach ($i in $Fe3InstalledIds) { $ids += "          <int>$i</int>`n" }
    $now = Get-Fe3Now
    $body = @"
<s:Envelope xmlns:a="http://www.w3.org/2005/08/addressing" xmlns:s="http://www.w3.org/2003/05/soap-envelope">
  <s:Header>
    <a:Action s:mustUnderstand="1">http://www.microsoft.com/SoftwareDistribution/Server/ClientWebService/SyncUpdates</a:Action>
    <a:MessageID>urn:uuid:$([guid]::NewGuid())</a:MessageID>
    <a:To s:mustUnderstand="1">$Fe3To</a:To>
    <o:Security s:mustUnderstand="1" xmlns:o="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd">
      <Timestamp xmlns="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd">
        <Created>$now</Created>
        <Expires>2044-08-02T20:09:03Z</Expires>
      </Timestamp>
      <wuws:WindowsUpdateTicketsToken wsu:id="ClientMSA" xmlns:wsu="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd" xmlns:wuws="http://schemas.microsoft.com/msus/2014/10/WindowsUpdateAuthorization"></wuws:WindowsUpdateTicketsToken>
    </o:Security>
  </s:Header>
  <s:Body>
    <SyncUpdates xmlns="$WuNs">
      $cookieXml
      <parameters>
        <ExpressQuery>false</ExpressQuery>
        <InstalledNonLeafUpdateIDs>
$ids        </InstalledNonLeafUpdateIDs>
        <OtherCachedUpdateIDs></OtherCachedUpdateIDs>
        <SkipSoftwareSync>false</SkipSoftwareSync>
        <NeedTwoGroupOutOfScopeUpdates>true</NeedTwoGroupOutOfScopeUpdates>
        <FilterAppCategoryIds>
          <CategoryIdentifier>
            <Id>$Category</Id>
          </CategoryIdentifier>
        </FilterAppCategoryIds>
        <TreatAppCategoryIdsAsInstalled>true</TreatAppCategoryIdsAsInstalled>
        <AlsoPerformRegularSync>false</AlsoPerformRegularSync>
        <ComputerSpec />
        <ExtendedUpdateInfoParameters>
          <XmlUpdateFragmentTypes>
            <XmlUpdateFragmentType>Extended</XmlUpdateFragmentType>
            <XmlUpdateFragmentType>Published</XmlUpdateFragmentType>
            <XmlUpdateFragmentType>Core</XmlUpdateFragmentType>
          </XmlUpdateFragmentTypes>
          <Locales>
            <string>en-US</string>
            <string>en</string>
          </Locales>
        </ExtendedUpdateInfoParameters>
        <ClientPreferredLanguages>
          <string>en-US</string>
        </ClientPreferredLanguages>
        <ProductsParameters>
          <SyncCurrentVersionOnly>false</SyncCurrentVersionOnly>
          <DeviceAttributes>$Fe3Attrs</DeviceAttributes>
          <CallerAttributes>Interactive=1;IsSeeker=0;</CallerAttributes>
          <Products />
        </ProductsParameters>
      </parameters>
    </SyncUpdates>
  </s:Body>
</s:Envelope>
"@
    $s = ConvertFrom-Fe3Sync (Get-Fe3Soap $Fe3Base $body)
    if ($s.Cookie -and $script:Fe3) {
        $script:Fe3.Cookie = $s.Cookie
        $script:Fe3.CookieExp = $s.Expiration
        $script:Fe3.CookieExpUtc = ConvertTo-UtcOffset $s.Expiration
    }
    if ($s.Ext.Count -eq 0 -and $s.Core.Count -eq 0) {
        throw 'the Windows Update service returned no updates for this app'
    }
    return $s
}

# The installable files out of those fragments. -Revs records, per revision, which
# digests came with it, so a single revision can be asked for a fresh link later
# without repeating the whole sync.

# [xml] reports a missing element or attribute as $null, which Set-StrictMode turns
# into an error. These fragments are Microsoft's data, not ours, so the optional
# bits are read through here and come back as $null instead of stopping the run.
function Get-XmlProp($Node, [string]$Name) {
    if (-not $Node) { return $null }
    $p = $Node.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

function ConvertFrom-Fe3Fragments {
    param($Core, $Ext, $Revs)

    $out = New-Object System.Collections.Generic.List[object]
    foreach ($id in $Ext.Keys) {
        if (-not $Core.ContainsKey($id)) { continue }
        $extXml = [string]$Ext[$id]
        $coreXml = [string]$Core[$id]
        if ($extXml -notmatch '<Files' -or $coreXml -notmatch 'SecuredFragment') { continue }
        $x = $null
        try { $x = [xml]('<Xml>' + $extXml + $coreXml + '</Xml>') } catch { continue }
        $ident = Get-XmlProp $x.Xml 'UpdateIdentity'
        if (-not $ident) { continue }
        $rev = ('{0}.{1}' -f (Get-XmlProp $ident 'UpdateID'), (Get-XmlProp $ident 'RevisionNumber'))
        $digests = New-Object System.Collections.Generic.List[string]
        foreach ($f in @(Get-XmlProp (Get-XmlProp $x.Xml 'Files') 'File')) {
            if (-not $f) { continue }
            # the block map rides along as "dynamic metadata" (and its file name is a
            # guid), .cab files are Windows Update payloads - neither is installable
            if ([string](Get-XmlProp $f 'PatchingType') -eq 'DynamicMetadata') { continue }
            $origName = [string](Get-XmlProp $f 'FileName')
            if ($origName -match '\.cab$' -or $origName -match '^Abm_') { continue }
            $sha1 = ConvertTo-HexDigest ([string](Get-XmlProp $f 'Digest'))
            if (-not $sha1) { continue }
            $size = [long]0
            [void][long]::TryParse([string](Get-XmlProp $f 'Size'), [ref]$size)
            # InstallerSpecificIdentifier is the app's own identity string for the
            # file (Name_Version_Arch__Publisher), which is the name the package
            # must keep on disk - the CDN knows it only by a guid.
            $isi = [string](Get-XmlProp $f 'InstallerSpecificIdentifier')
            $name = if ($isi) { $isi + [IO.Path]::GetExtension($origName) } else { $origName }
            $out.Add([pscustomobject]@{ Name = $name; Sha1 = $sha1; Size = $size; Rev = $rev })
            $digests.Add($sha1)
        }
        if ($Revs) {
            $Revs[$rev] = [pscustomobject]@{
                UpdateID       = [string](Get-XmlProp $ident 'UpdateID')
                RevisionNumber = [string](Get-XmlProp $ident 'RevisionNumber')
                Digests        = @($digests)
            }
        }
    }
    return $out
}

function Get-Fe3Packages([string]$Category) {
    $s = Sync-Fe3Updates $Category
    return ConvertFrom-Fe3Fragments -Core $s.Core -Ext $s.Ext -Revs $script:Fe3.Revs
}

function ConvertFrom-Fe3Locations([string]$Xml) {
    $map = @{}
    foreach ($m in [regex]::Matches($Xml, '<FileLocation>([\s\S]*?)</FileLocation>')) {
        $block = $m.Groups[1].Value
        $d = ConvertTo-HexDigest ([string](Get-Fe3Tag $block 'FileDigest'))
        $u = [string](Get-Fe3Tag $block 'Url')
        if ($d -and $u -and -not $map.ContainsKey($d)) { $map[$d] = $u }
    }
    return $map
}

function Get-Fe3InfoBody([string[]]$Revs) {
    $ids = ''
    foreach ($r in $Revs) {
        $info = $script:Fe3.Revs[$r]
        $ids += "        <UpdateIdentity><UpdateID>$($info.UpdateID)</UpdateID><RevisionNumber>$($info.RevisionNumber)</RevisionNumber></UpdateIdentity>`n"
    }
    $cookieXml = Get-Fe3CookieXml
    $now = Get-Fe3Now
    return @"
<s:Envelope xmlns:a="http://www.w3.org/2005/08/addressing" xmlns:s="http://www.w3.org/2003/05/soap-envelope">
  <s:Header>
    <a:Action s:mustUnderstand="1">http://www.microsoft.com/SoftwareDistribution/Server/ClientWebService/GetExtendedUpdateInfo2</a:Action>
    <a:MessageID>urn:uuid:$([guid]::NewGuid())</a:MessageID>
    <a:To s:mustUnderstand="1">$Fe3ToSecured</a:To>
    <o:Security s:mustUnderstand="1" xmlns:o="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd">
      <Timestamp xmlns="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd">
        <Created>$now</Created>
        <Expires>2044-08-02T20:09:03Z</Expires>
      </Timestamp>
      <wuws:WindowsUpdateTicketsToken wsu:id="ClientMSA" xmlns:wsu="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd" xmlns:wuws="http://schemas.microsoft.com/msus/2014/10/WindowsUpdateAuthorization"></wuws:WindowsUpdateTicketsToken>
    </o:Security>
  </s:Header>
  <s:Body>
    <GetExtendedUpdateInfo2 xmlns="$WuNs">
      $cookieXml
      <updateIDs>
$ids      </updateIDs>
      <infoTypes>
        <XmlUpdateFragmentType>FileUrl</XmlUpdateFragmentType>
        <XmlUpdateFragmentType>FileDecryption</XmlUpdateFragmentType>
      </infoTypes>
      <deviceAttributes>$Fe3Attrs</deviceAttributes>
    </GetExtendedUpdateInfo2>
  </s:Body>
</s:Envelope>
"@
}

# Signed links for the given revisions, keyed by digest. One request covers a whole
# batch of revisions; anything the batch leaves out is then asked for on its own.
function Get-Fe3UrlMap([string[]]$Revs) {
    $map = @{}
    $st = $script:Fe3
    if (-not $st) { return $map }
    $want = @()
    foreach ($r in @($Revs)) { if ($r -and $st.Revs.ContainsKey($r)) { $want += $r } }
    if (-not $want.Count) { return $map }
    try {
        $map = ConvertFrom-Fe3Locations (Get-Fe3Soap $Fe3Secured (Get-Fe3InfoBody $want))
    } catch {
        Warn "the Windows Update service did not hand out the download links ($($_.Exception.Message))"
    }
    foreach ($r in $want) {
        $gap = $false
        foreach ($d in @($st.Revs[$r].Digests)) { if (-not $map.ContainsKey($d)) { $gap = $true; break } }
        if (-not $gap) { continue }
        try {
            $one = ConvertFrom-Fe3Locations (Get-Fe3Soap $Fe3Secured (Get-Fe3InfoBody @($r)))
            foreach ($k in $one.Keys) { if (-not $map.ContainsKey($k)) { $map[$k] = $one[$k] } }
        } catch { }
    }
    return $map
}

function Get-StoreFilesFe3([string]$WuCategoryId) {
    $script:Fe3 = [pscustomobject]@{
        Category     = $WuCategoryId
        Cookie       = $null
        CookieExp    = ''
        CookieExpUtc = [DateTimeOffset]::MinValue
        Revs         = @{}
    }
    $pkgs = @(Get-Fe3Packages $WuCategoryId)
    if (-not $pkgs.Count) {
        $script:Fe3 = $null
        throw 'the Windows Update service listed no files for this app'
    }
    $map = Get-Fe3UrlMap @($script:Fe3.Revs.Keys)
    $files = New-Object System.Collections.Generic.List[object]
    $left = 0
    foreach ($p in $pkgs) {
        $u = ''
        if ($map.ContainsKey($p.Sha1)) { $u = [string]$map[$p.Sha1] }
        if (-not $u) { $left++; continue }
        $files.Add([pscustomobject]@{ Name = $p.Name; Url = $u; Sha1 = $p.Sha1; Size = $p.Size; Rev = $p.Rev })
    }
    if (-not $files.Count) {
        $script:Fe3 = $null
        throw 'the Windows Update service returned no download links'
    }
    if ($left) { Warn "$left file(s) on offer had no download link and were left out" }
    return $files
}

# The file list, from Microsoft where possible and from the third-party mirror only
# as a fallback, so a blocked network still works.
function Get-StoreFilesAuto {
    param([string]$ProductId, [string]$WuCategoryId, [switch]$NoFe3, [switch]$Quiet)

    $script:RgProduct = $null
    if (-not $NoFe3) {
        if (-not $WuCategoryId) {
            try {
                $c = Get-StoreCatalog $ProductId
                if ($c) { $WuCategoryId = [string]$c.WuCategoryId }
            } catch { }
        }
        if ($WuCategoryId) {
            try {
                $f = @(Get-StoreFilesFe3 $WuCategoryId)
                if ($f.Count) {
                    if (-not $Quiet) { Ok ("{0} file(s) offered by the Store (Microsoft's own update service)" -f $f.Count) }
                    return $f
                }
            } catch {
                Warn "Microsoft's own update service could not be used ($($_.Exception.Message))"
                Warn 'falling back to store.rg-adguard.net for the file list'
            }
        } elseif (-not $Quiet) {
            Warn 'this app has no Windows Update category - asking store.rg-adguard.net instead'
        }
    }
    $script:Fe3 = $null
    $f = @(Get-StoreFiles $ProductId)
    # remembered so that a spent link can be renewed from the same listing
    $script:RgProduct = $ProductId
    if (-not $Quiet) { Ok ("{0} file(s) offered by the Store (via store.rg-adguard.net)" -f $f.Count) }
    return $f
}

# A link is only usable for about ten minutes (the P1 stamp), so the download loop
# renews it when it is running out, or when an attempt has already failed.
function Test-UrlStale([string]$Url, [int]$MarginSec = 90) {
    if (-not $Url) { return $false }
    $m = [regex]::Match($Url, '[?&]P1=(\d+)')
    if (-not $m.Success) { return $false }
    try { return ((([long]$m.Groups[1].Value) - (Get-UnixSeconds)) -lt $MarginSec) } catch { return $false }
}

function Get-FreshUrl {
    param([string]$Url, [string]$Sha1, [string]$Rev, [string]$Name, [switch]$Force)

    # the links only live about ten minutes, so one that is spent (or one whose
    # attempt has already failed) is replaced with a fresh one
    if (-not $Force -and -not (Test-UrlStale $Url)) { return $Url }
    try {
        if ($Rev -and $script:Fe3) {
            $map = Get-Fe3UrlMap @($Rev)
            if ($Sha1 -and $map.ContainsKey($Sha1)) {
                $new = [string]$map[$Sha1]
                if ($new -and $new -ne $Url) {
                    Say '        (that link had run out - a fresh one was used)' 'DarkGray'
                    return $new
                }
            }
        } elseif ($script:RgProduct -and $Name) {
            # the fallback listing is a mirror of the same service, so it mints
            # links the same way; the file name is what identifies one there
            $hit = @(@(Get-StoreFiles $script:RgProduct) | Where-Object { $_.Name -eq $Name })
            if ($hit.Count -and $hit[0].Url -and $hit[0].Url -ne $Url) {
                Say '        (that link had run out - a fresh one was used)' 'DarkGray'
                return [string]$hit[0].Url
            }
        }
    } catch { Warn "could not renew the download link: $($_.Exception.Message)" }
    return $Url
}

