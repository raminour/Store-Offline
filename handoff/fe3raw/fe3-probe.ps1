# Probe: can we get a Windows Update delivery cookie (the official, no-third-party path)?
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$to = 'https://fe3cr.delivery.mp.microsoft.com/ClientWebService/client.asmx'
$action = 'http://www.microsoft.com/SoftwareDistribution/Server/ClientWebService/GetCookie'
$now = (Get-Date).ToUniversalTime()
$created = $now.AddMinutes(-5).ToString('yyyy-MM-ddTHH:mm:ssZ')
$expires = $now.AddMinutes(10).ToString('yyyy-MM-ddTHH:mm:ssZ')
$mid = 'urn:uuid:' + [guid]::NewGuid().ToString()

$body = @"
<?xml version="1.0" encoding="UTF-8"?>
<s:Envelope xmlns:a="http://www.w3.org/2005/08/addressing" xmlns:s="http://www.w3.org/2003/05/soap-envelope">
  <s:Header>
    <a:Action s:mustUnderstand="1">$action</a:Action>
    <a:MessageID>$mid</a:MessageID>
    <a:To s:mustUnderstand="1">$to</a:To>
    <o:Security s:mustUnderstand="1" xmlns:o="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd">
      <Timestamp xmlns="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd">
        <Created>$created</Created>
        <Expires>$expires</Expires>
      </Timestamp>
      <wuws:WindowsUpdateTicketsToken wsu:id="ClientMSA" xmlns:wsu="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd" xmlns:wuws="http://schemas.microsoft.com/windowsupdate/2007/wssecurity">
        <TicketType Name="MSA" Version="1.0" Policy="MBI_SSL"><User /></TicketType>
      </wuws:WindowsUpdateTicketsToken>
    </o:Security>
  </s:Header>
  <s:Body>
    <GetCookie xmlns="http://www.microsoft.com/SoftwareDistribution/Server/ClientWebService">
      <oldCookie><Expiration>$created</Expiration></oldCookie>
      <lastChange>$created</lastChange>
      <currentTime>$now.ToString('yyyy-MM-ddTHH:mm:ssZ')</currentTime>
      <protocolVersion>1.0</protocolVersion>
    </GetCookie>
  </s:Body>
</s:Envelope>
"@

function Show-Err($e) {
    $r = $e.Exception.Response
    if ($r) {
        Write-Output ("HTTP: " + [int]$r.StatusCode + " " + $r.StatusCode)
        try {
            $sr = New-Object IO.StreamReader($r.GetResponseStream())
            $t = $sr.ReadToEnd(); $sr.Dispose()
            Write-Output ("BODY: " + $t.Substring(0, [Math]::Min(1200, $t.Length)))
        } catch { Write-Output ("(no body: " + $_.Exception.Message + ")") }
    } else { Write-Output ("EX: " + $e.Exception.Message) }
}

foreach ($ct in @('application/soap+xml; charset=utf-8', 'text/xml; charset=utf-8')) {
    Write-Output "=== Content-Type: $ct ==="
    $hdr = @{ SOAPAction = '"' + $action + '"' }
    try {
        $resp = Invoke-WebRequest -Uri $to -Method Post -ContentType $ct -Headers $hdr -Body $body -UseBasicParsing -TimeoutSec 60
        Write-Output ("STATUS: " + [int]$resp.StatusCode)
        Write-Output ("BODY: " + $resp.Content.Substring(0, [Math]::Min(1500, $resp.Content.Length)))
    } catch { Show-Err $_ }
    Write-Output ''
}
