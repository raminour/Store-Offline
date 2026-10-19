[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$to = 'https://fe3cr.delivery.mp.microsoft.com/ClientWebService/client.asmx'
$action = 'http://www.microsoft.com/SoftwareDistribution/Server/ClientWebService/GetCookie'
$now = (Get-Date).ToUniversalTime()
$created = $now.AddMinutes(-5).ToString('yyyy-MM-ddTHH:mm:ssZ')
$expires = $now.AddMinutes(10).ToString('yyyy-MM-ddTHH:mm:ssZ')

function Send([string]$name, [string]$body) {
    Write-Output ("=== {0} ===" -f $name)
    $r = [Net.HttpWebRequest]::Create($to)
    $r.Method = 'POST'
    $r.ContentType = 'application/soap+xml; charset=utf-8'
    $r.Headers.Add('SOAPAction', '"' + $action + '"')
    $r.Timeout = 60000
    $r.UserAgent = 'Windows-Update-Agent/10.0.10011.16384 Client-Protocol/2.40'
    $bytes = [Text.Encoding]::UTF8.GetBytes($body)
    $r.ContentLength = $bytes.Length
    $s = $r.GetRequestStream(); $s.Write($bytes, 0, $bytes.Length); $s.Dispose()
    try {
        $resp = $r.GetResponse()
        $sr = New-Object IO.StreamReader($resp.GetResponseStream())
        $t = $sr.ReadToEnd(); $sr.Dispose()
        Write-Output ("  STATUS {0}" -f [int]$resp.StatusCode)
        Write-Output ("  BODY {0}" -f $t.Substring(0, [Math]::Min(1400, $t.Length)))
        return $t
    } catch [Net.WebException] {
        $er = $_.Exception.Response
        if ($er) {
            Write-Output ("  STATUS {0}" -f [int]$er.StatusCode)
            $sr = New-Object IO.StreamReader($er.GetResponseStream())
            $t = $sr.ReadToEnd(); $sr.Dispose()
            Write-Output ("  BODY {0}" -f $t.Substring(0, [Math]::Min(1400, $t.Length)))
            return $t
        }
        Write-Output ("  EX {0}" -f $_.Exception.Message)
        return ''
    }
}

$mid = 'urn:uuid:' + [guid]::NewGuid().ToString()

# variant A: no Security header at all
$bodyA = @"
<?xml version="1.0" encoding="UTF-8"?>
<s:Envelope xmlns:a="http://www.w3.org/2005/08/addressing" xmlns:s="http://www.w3.org/2003/05/soap-envelope">
  <s:Header>
    <a:Action s:mustUnderstand="1">$action</a:Action>
    <a:MessageID>$mid</a:MessageID>
    <a:To s:mustUnderstand="1">$to</a:To>
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

# variant B: security token with an explicit empty User and Client attributes
$bodyB = @"
<?xml version="1.0" encoding="UTF-8"?>
<s:Envelope xmlns:a="http://www.w3.org/2005/08/addressing" xmlns:s="http://www.w3.org/2003/05/soap-envelope">
  <s:Header>
    <a:Action s:mustUnderstand="1">$action</a:Action>
    <a:MessageID>$mid</a:MessageID>
    <a:To s:mustUnderstand="1">$to</a:To>
    <o:Security s:mustUnderstand="1" xmlns:o="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd">
      <Timestamp xmlns="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd">
        <Created>$created</Created><Expires>$expires</Expires>
      </Timestamp>
      <wuws:WindowsUpdateTicketsToken wsu:id="ClientMSA" xmlns:wsu="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd" xmlns:wuws="http://schemas.microsoft.com/windowsupdate/2007/wssecurity">
        <TicketType Name="MSA" Version="1.0" Policy="MBI_SSL" />
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

# variant C: ticket token with a User element carrying an empty id
$bodyC = $bodyB -replace '<TicketType Name="MSA" Version="1.0" Policy="MBI_SSL" />', '<TicketType Name="MSA" Version="1.0" Policy="MBI_SSL"><User wsu:id="" /></TicketType>'

Send 'A: no Security header' $bodyA
Send 'B: MSA ticket, self-closed' $bodyB
Send 'C: MSA ticket with empty User id' $bodyC
