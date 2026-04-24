# vm-console-server.ps1
param(
    [string]$VMName = "EVE-NG-User01",
    [int]$Port = 8888
)

$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://+:$Port/")
$listener.Start()

Write-Host "Sirviendo consola de $VMName en http://0.0.0.0:$Port"

while ($listener.IsListening) {
    $context = $listener.GetContext()
    $request = $context.Request
    $response = $context.Response

    if ($request.Url.AbsolutePath -eq "/screen.png") {
        $vm = Get-VM -Name $VMName
        $png = Get-VMScreenshot -VM $vm
        $response.ContentType = "image/png"
        $response.ContentLength64 = $png.Length
        $response.OutputStream.Write($png, 0, $png.Length)
    }
    elseif ($request.Url.AbsolutePath -eq "/") {
        $html = @"
<html><body style="background:#000;margin:0">
<img id="s" src="/screen.png" style="width:100%;height:100vh;object-fit:contain">
<script>setInterval(()=>document.getElementById('s').src='/screen.png?t='+Date.now(),1000)</script>
</body></html>
"@
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($html)
        $response.ContentType = "text/html"
        $response.ContentLength64 = $bytes.Length
        $response.OutputStream.Write($bytes, 0, $bytes.Length)
    }

    $response.OutputStream.Close()
}

New-NetFirewallRule -DisplayName "VM Console" -Direction Inbound -Port 8888 -Protocol TCP -Action Allow