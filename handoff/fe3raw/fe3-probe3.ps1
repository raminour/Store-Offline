# Probe: the official, no-third-party path - displaycatalog -> FE3 (Windows Update SOAP).
# Shapes taken from the published Get-StoreDirectLinks.ps1 (which credits StoreListings).
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ErrorActionPreference = 'Stop'

$WuNs = 'http://www.microsoft.com/SoftwareDistribution/Server/ClientWebService'
$fe3Base = 'https://fe3cr.delivery.mp.microsoft.com/ClientWebService/client.asmx'
$fe3Secured = "$fe3Base/secured"
$fe3To = 'https://fe3.delivery.mp.microsoft.com/ClientWebService/client.asmx'
$uaFe3 = 'Windows-Update-Agent/10.0.10011.16384 Client-Protocol/2.1'
$rawDir = 'C:\Users\lenovo\AppData\Local\Temp\opencode\fe3raw'
if (-not (Test-Path -LiteralPath $rawDir)) { New-Item -ItemType Directory -Path $rawDir -Force | Out-Null }

$baseline = @(
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
$deviceAttributes = 'BranchReadinessLevel=CB;CurrentBranch=;OEMModel=Virtual Machine;FlightRing=Retail;AttrDataVer=21;SystemManufacturer=Microsoft Corporation;InstallLanguage=en-US;OSUILocale=en-US;InstallationType=Client;FlightingBranchName=;FirmwareVersion=Hyper-V UEFI Release v2.5;SystemProductName=Virtual Machine;OSSkuId=48;FlightContent=Mainline;App=WU_STORE;OEMName_Uncleaned=Microsoft Corporation;AppVer=0.0.0.0;OSArchitecture=AMD64;SystemSKU=None;UpdateManagementGroup=2;IsFlightingEnabled=0;IsDeviceRetailDemo=0;TelemetryLevel=3;OSVersion=10.0.22621.1;DeviceFamily=Windows.Desktop;'

function Get-XmlValue([string]$text, [string]$tag) {
    $m = [regex]::Match($text, "<$tag>([^<]*)</$tag>")
    if ($m.Success) { return [System.Net.WebUtility]::HtmlDecode($m.Groups[1].Value) }
    return $null
}
function Get-XmlBlock([string]$text, [string]$tag) {
    $m = [regex]::Match($text, "<$tag>([\s\S]*?)</$tag>")
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}
function Send-Soap([string]$uri, [string]$body, [string]$name) {
    $hdr = @{ 'User-Agent' = $uaFe3 }
    try {
        $r = Invoke-WebRequest -Uri $uri -Method Post -Headers $hdr -ContentType 'application/soap+xml; charset=utf-8' -Body $body -UseBasicParsing -TimeoutSec 180
        [IO.File]::WriteAllText((Join-Path $rawDir "$name.xml"), $r.Content, (New-Object Text.UTF8Encoding($false)))
        Write-Host ("    {0}: HTTP {1}, {2} chars" -f $name, [int]$r.StatusCode, $r.Content.Length)
        return $r.Content
    } catch {
        $b = ''
        if ($_.Exception.Response) {
            try { $sr = New-Object IO.StreamReader($_.Exception.Response.GetResponseStream()); $b = $sr.ReadToEnd(); $sr.Dispose() } catch { }
        }
        Write-Host ("    {0}: FAILED - {1}" -f $name, $_.Exception.Message)
        if ($b) { Write-Host ('    BODY: ' + $b.Substring(0, [Math]::Min(700, $b.Length))) }
        return $null
    }
}
function Base64ToHex([string]$b64) {
    if (-not $b64) { return '' }
    try { return ([BitConverter]::ToString([Convert]::FromBase64String($b64)) -replace '-', '').ToLowerInvariant() } catch { return $b64 }
}

$productId = '9NKSQGP7F2NH'   # WhatsApp
Write-Output "[1/4] displaycatalog -> WuCategoryId"
$dcat = Invoke-RestMethod -Uri "https://displaycatalog.mp.microsoft.com/v7.0/products/$productId`?market=US&languages=en-US,en&fieldsTemplate=Details" -Method Get -TimeoutSec 60
$sku = $dcat.Product.DisplaySkuAvailabilities[0].Sku
$wuCategoryId = $sku.Properties.FulfillmentData.WuCategoryId
Write-Output ("    WuCategoryId = {0}" -f $wuCategoryId)
if (-not $wuCategoryId) { throw 'no WuCategoryId' }

$now = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
Write-Output "[2/4] GetCookie"
$getCookie = @"
<Envelope xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns="http://www.w3.org/2003/05/soap-envelope">
  <Header>
    <Action d3p1:mustUnderstand="1" xmlns:d3p1="http://www.w3.org/2003/05/soap-envelope" xmlns="http://www.w3.org/2005/08/addressing">http://www.microsoft.com/SoftwareDistribution/Server/ClientWebService/GetCookie</Action>
    <MessageID xmlns="http://www.w3.org/2005/08/addressing">urn:uuid:$([guid]::NewGuid())</MessageID>
    <To d3p1:mustUnderstand="1" xmlns:d3p1="http://www.w3.org/2003/05/soap-envelope" xmlns="http://www.w3.org/2005/08/addressing">$fe3To</To>
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
$cookieResp = Send-Soap $fe3Base $getCookie 'GetCookie'
if (-not $cookieResp) { throw 'GetCookie failed' }
$cookieData = Get-XmlValue $cookieResp 'EncryptedData'
$cookieExp = Get-XmlValue $cookieResp 'Expiration'
Write-Output ("    cookie: {0} chars, expires {1}" -f $cookieData.Length, $cookieExp)
if (-not $cookieData) { throw 'no cookie in response' }

Write-Output "[3/4] SyncUpdates"
$installedNonLeaf = ($baseline | ForEach-Object { "<int>$_</int>" }) -join "`n"
$sync = @"
<s:Envelope xmlns:a="http://www.w3.org/2005/08/addressing" xmlns:s="http://www.w3.org/2003/05/soap-envelope">
  <s:Header>
    <a:Action s:mustUnderstand="1">http://www.microsoft.com/SoftwareDistribution/Server/ClientWebService/SyncUpdates</a:Action>
    <a:MessageID>urn:uuid:$([guid]::NewGuid())</a:MessageID>
    <a:To s:mustUnderstand="1">$fe3To</a:To>
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
      <cookie>
        <Expiration>$cookieExp</Expiration>
        <EncryptedData>$cookieData</EncryptedData>
      </cookie>
      <parameters>
        <ExpressQuery>false</ExpressQuery>
        <InstalledNonLeafUpdateIDs>
          $installedNonLeaf
        </InstalledNonLeafUpdateIDs>
        <OtherCachedUpdateIDs></OtherCachedUpdateIDs>
        <SkipSoftwareSync>false</SkipSoftwareSync>
        <NeedTwoGroupOutOfScopeUpdates>true</NeedTwoGroupOutOfScopeUpdates>
        <FilterAppCategoryIds>
          <CategoryIdentifier>
            <Id>$wuCategoryId</Id>
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
          <DeviceAttributes>$deviceAttributes</DeviceAttributes>
          <CallerAttributes>Interactive=1;IsSeeker=0;</CallerAttributes>
          <Products />
        </ProductsParameters>
      </parameters>
    </SyncUpdates>
  </s:Body>
</s:Envelope>
"@
$syncResp = Send-Soap $fe3Base $sync 'SyncUpdates'
if (-not $syncResp) { throw 'SyncUpdates failed' }

$newCookie = Get-XmlBlock $syncResp 'NewCookie'
if ($newCookie) {
    $d = Get-XmlValue $newCookie 'EncryptedData'
    $e = Get-XmlValue $newCookie 'Expiration'
    if ($d) { $cookieData = $d; $cookieExp = $e }
}
$newUpdates = Get-XmlBlock $syncResp 'NewUpdates'
$extended = Get-XmlBlock $syncResp 'ExtendedUpdateInfo'
if (-not $newUpdates -or -not $extended) {
    Write-Output '    !! no NewUpdates/ExtendedUpdateInfo in the sync response'
    Write-Output ('    head: ' + $syncResp.Substring(0, [Math]::Min(800, $syncResp.Length)))
    throw 'sync returned nothing'
}
$coreById = @{}
foreach ($m in [regex]::Matches($newUpdates, '<UpdateInfo>([\s\S]*?)</UpdateInfo>')) {
    $id = Get-XmlValue $m.Groups[1].Value 'ID'
    $xml = Get-XmlValue $m.Groups[1].Value 'Xml'
    if ($id) { $coreById[$id] = $xml }
}
$extById = @{}
$extUpdates = Get-XmlBlock $extended 'Updates'
foreach ($m in [regex]::Matches($extUpdates, '<Update>([\s\S]*?)</Update>')) {
    $id = Get-XmlValue $m.Groups[1].Value 'ID'
    $xml = Get-XmlValue $m.Groups[1].Value 'Xml'
    if ($id) { $extById[$id] = $xml }
}
Write-Output ("    core fragments={0}  extended fragments={1}" -f $coreById.Count, $extById.Count)

$packages = New-Object System.Collections.Generic.List[object]
foreach ($id in $extById.Keys) {
    if (-not $coreById.ContainsKey($id)) { continue }
    $extXml = $extById[$id]
    $coreXml = $coreById[$id]
    if ($extXml -notmatch '<Files' -or $coreXml -notmatch 'SecuredFragment') { continue }
    try { [xml]$combined = "<Xml>$extXml$coreXml</Xml>" } catch { continue }
    $identity = $combined.Xml.UpdateIdentity
    if (-not $identity) { continue }
    $pkgIdentity = $combined.Xml.ExtendedProperties.PackageIdentityName
    $files = @($combined.Xml.Files.File)
    $revisionIdentifier = $pkgIdentity
    foreach ($f in $files) { if ($f -and $f.InstallerSpecificIdentifier) { $revisionIdentifier = $f.InstallerSpecificIdentifier; break } }
    $arch = 'unknown'
    $am = [regex]::Match([string]$revisionIdentifier, '_(x86|x64|arm64|arm|neutral)__')
    if ($am.Success) { $arch = $am.Groups[1].Value }
    foreach ($file in $files) {
        if (-not $file) { continue }
        $origName = [string]$file.FileName
        $identifier = [string]$file.InstallerSpecificIdentifier
        [long]$size = 0
        if ($file.Size) { [void][long]::TryParse([string]$file.Size, [ref]$size) }
        if ($file.PatchingType -eq 'DynamicMetadata' -or $origName -match '^Abm_') { continue }
        if ($origName -match '\.cab$') { continue }
        $ext = [System.IO.Path]::GetExtension($origName)
        $realName = if ($identifier) { "$identifier$ext" } else { $origName }
        $packages.Add([pscustomobject]@{
                FileName        = $realName
                UpdateID        = [string]$identity.UpdateID
                RevisionNumber  = [string]$identity.RevisionNumber
                Digest          = [string]$file.Digest
                DigestAlgorithm = [string]$file.DigestAlgorithm
                Size            = $size
                Arch            = $arch
                PatchingType    = [string]$file.PatchingType
            })
    }
}
Write-Output ("    packages found: {0}" -f $packages.Count)

Write-Output "[4/4] GetExtendedUpdateInfo2 (signed URLs)"
$byRevision = $packages | Group-Object -Property UpdateID, RevisionNumber
$got = New-Object System.Collections.Generic.List[object]
foreach ($group in $byRevision) {
    $first = $group.Group[0]
    $info = @"
<s:Envelope xmlns:a="http://www.w3.org/2005/08/addressing" xmlns:s="http://www.w3.org/2003/05/soap-envelope">
  <s:Header>
    <a:Action s:mustUnderstand="1">http://www.microsoft.com/SoftwareDistribution/Server/ClientWebService/GetExtendedUpdateInfo2</a:Action>
    <a:MessageID>urn:uuid:$([guid]::NewGuid())</a:MessageID>
    <a:To s:mustUnderstand="1">https://fe3.delivery.mp.microsoft.com/ClientWebService/client.asmx/secured</a:To>
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
      <cookie>
        <Expiration>$cookieExp</Expiration>
        <EncryptedData>$cookieData</EncryptedData>
      </cookie>
      <updateIDs>
        <UpdateIdentity>
          <UpdateID>$($first.UpdateID)</UpdateID>
          <RevisionNumber>$($first.RevisionNumber)</RevisionNumber>
        </UpdateIdentity>
      </updateIDs>
      <infoTypes>
        <XmlUpdateFragmentType>FileUrl</XmlUpdateFragmentType>
        <XmlUpdateFragmentType>FileDecryption</XmlUpdateFragmentType>
      </infoTypes>
      <deviceAttributes>$deviceAttributes</deviceAttributes>
    </GetExtendedUpdateInfo2>
  </s:Body>
</s:Envelope>
"@
    $infoResp = Send-Soap $fe3Secured $info ("GEUI2_" + $first.UpdateID)
    if (-not $infoResp) { continue }
    $locs = [regex]::Matches($infoResp, '<FileLocation>([\s\S]*?)</FileLocation>')
    foreach ($pkg in $group.Group) {
        $url = $null
        foreach ($lm in $locs) {
            if ((Get-XmlValue $lm.Groups[1].Value 'FileDigest') -eq $pkg.Digest) { $url = Get-XmlValue $lm.Groups[1].Value 'Url'; break }
        }
        if ($url) {
            $pkg | Add-Member -NotePropertyName Url -NotePropertyValue $url -Force
            $got.Add($pkg)
        }
    }
}
Write-Output ''
Write-Output ("=== RESULT: {0} file(s) with a signed URL ===" -f $got.Count)
foreach ($g in $got) {
    $hex = Base64ToHex $g.Digest
    Write-Output ("  {0}" -f $g.FileName)
    Write-Output ("      alg={0}  sha={1}({2} hex)  {3:N1} MB  arch={4}" -f $g.DigestAlgorithm, $(if ($hex.Length -eq 40) { 'sha1' } elseif ($hex.Length -eq 64) { 'sha256' } else { '?' }), $hex.Length, ($g.Size / 1MB), $g.Arch)
    Write-Output ("      url: {0}" -f $g.Url.Substring(0, [Math]::Min(110, $g.Url.Length)))
}
