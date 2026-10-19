$ErrorActionPreference = 'Continue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$NS = 'http://www.microsoft.com/SoftwareDistribution/Server/ClientWebService'
$UA = 'Windows-Update-Agent/10.0.10011.16384 Client-Protocol/2.40'

function Build($endpoint, $action, $withSec) {
    $c = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    $e = (Get-Date).ToUniversalTime().AddMinutes(5).ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    $sec = ''
    if ($withSec) {
        $sec = @"
    <o:Security s:mustUnderstand="1" xmlns:o="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd">
      <u:Timestamp u:Id="_0" xmlns:u="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd">
        <u:Created>$c</u:Created><u:Expires>$e</u:Expires>
      </u:Timestamp>
    </o:Security>
"@
    }
    return @"
<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:a="http://www.w3.org/2005/08/addressing">
  <s:Header>
    <a:Action s:mustUnderstand="1">$NS/$action</a:Action>
    <a:To s:mustUnderstand="1">$endpoint</a:To>
$sec
  </s:Header>
  <s:Body>
    <GetCookie xmlns="$NS">
      <oldCookie/><lastChange/><currentTime/><protocolVersion>1.0</protocolVersion>
    </GetCookie>
  </s:Body>
</s:Envelope>
"@
}

$cases = @(
  @{ ep = 'https://fe3.delivery.mp.microsoft.com/ClientWebService/client.asmx';        sec = $true;  name = 'public  + timestamp' },
  @{ ep = 'https://fe3.delivery.mp.microsoft.com/ClientWebService/client.asmx';        sec = $false; name = 'public  + none' },
  @{ ep = 'https://fe3.delivery.mp.microsoft.com/ClientWebService/client.asmx/secured'; sec = $true;  name = 'secured + timestamp' },
  @{ ep = 'https://fe3.delivery.mp.microsoft.com/ClientWebService/client.asmx/secured'; sec = $false; name = 'secured + none' },
  @{ ep = 'https://fe3cr.delivery.mp.microsoft.com/ClientWebService/client.asmx';       sec = $true;  name = 'fe3cr   + timestamp' }
)

foreach ($c in $cases) {
    $env = Build $c.ep 'GetCookie' $c.sec
    $ct = "application/soap+xml; charset=utf-8; action=`"$NS/GetCookie`""
    try {
        $r = Invoke-WebRequest -Uri $c.ep -Method Post -Body ([Text.Encoding]::UTF8.GetBytes($env)) `
                -ContentType $ct -Headers @{ 'User-Agent' = $UA; 'Accept' = 'application/soap+xml, */*' } `
                -UseBasicParsing -TimeoutSec 30
        $body = [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray())
        $ok = if ($body -match '<EncryptedData>') { 'COOKIE-OK' } else { 'no-cookie' }
        Write-Output ("[{0}] {1,-22} -> {2}  {3}" -f $ok, $c.name, [int]$r.StatusCode, ($body.Substring(0, [Math]::Min(160, $body.Length)) -replace '\s+', ' '))
    } catch {
        $msg = ''
        if ($_.Exception.Response) {
            try { $msg = (New-Object IO.StreamReader($_.Exception.Response.GetResponseStream())).ReadToEnd() } catch {}
        }
        if (-not $msg) { $msg = $_.ErrorDetails.Message }
        if (-not $msg) { $msg = $_.Exception.Message }
        $fault = [regex]::Match($msg, '<(?:faultcode|Code)>.*?(?:faultstring|Reason)>.*?<.*?>(.*?)<', 'Singleline')
        $f = [regex]::Match($msg, 'faultstring[^>]*>(.*?)<', 'Singleline')
        if (-not $f.Success) { $f = [regex]::Match($msg, '<Text[^>]*>(.*?)</Text>', 'Singleline') }
        $detail = if ($f.Success) { $f.Groups[1].Value } else { $msg.Substring(0, [Math]::Min(200, $msg.Length)) -replace '\s+', ' ' }
        Write-Output ("[FAIL] {0,-22} -> {1}" -f $c.name, $detail)
    }
}