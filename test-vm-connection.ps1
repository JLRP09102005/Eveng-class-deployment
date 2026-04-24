# vm-console-server.ps1
param(
    [string]$VMName = "test",
    [int]$Port = 8888
)

function Get-VMScreenshotBytes {
    param([string]$Name)
    
    $vm = Get-CimInstance -Namespace "root\virtualization\v2" -ClassName "Msvm_ComputerSystem" -Filter "ElementName='$Name'"
    $videoHead = Get-CimAssociatedInstance -InputObject $vm -ResultClassName "Msvm_VideoHead"
    $videoSvc = Get-CimInstance -Namespace "root\virtualization\v2" -ClassName "Msvm_VirtualSystemManagementService"
    
    $result = Invoke-CimMethod -InputObject $videoSvc -MethodName "GetVirtualSystemThumbnailImage" -Arguments @{
        TargetSystem = $vm
        WidthPixels  = [uint16]1024
        HeightPixels = [uint16]768
    }
    
    # El resultado es raw RGB, hay que convertirlo a PNG
    $raw = $result.ImageData
    return $raw
}

$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://+:$Port/")
$listener.Start()
Write-Host "Sirviendo consola de $VMName en http://0.0.0.0:$Port"

while ($listener.IsListening) {
    $context = $listener.GetContext()
    $request  = $context.Request
    $response = $context.Response

    if ($request.Url.AbsolutePath -eq "/screen.bmp") {
        try {
            $raw = Get-VMScreenshotBytes -Name $VMName
            # raw es BGR 16bpp — servimos los bytes directos para debug
            $response.ContentType = "application/octet-stream"
            $response.ContentLength64 = $raw.Length
            $response.OutputStream.Write($raw, 0, $raw.Length)
        } catch {
            $response.StatusCode = 500
        }
    }
    elseif ($request.Url.AbsolutePath -eq "/") {
        $html = @"
<html><body style="background:#000;margin:0">
<canvas id="c" style="width:100%;height:100vh"></canvas>
<script>
async function refresh() {
    const r = await fetch('/screen.bmp?t=' + Date.now());
    const buf = await r.arrayBuffer();
    const view = new Uint8Array(buf);
    const canvas = document.getElementById('c');
    canvas.width = 1024; canvas.height = 768;
    const ctx = canvas.getContext('2d');
    const img = ctx.createImageData(1024, 768);
    for (let i = 0, j = 0; i < view.length; i += 2, j += 4) {
        const px = view[i] | (view[i+1] << 8);
        img.data[j]   = (px >> 11 & 31) << 3;  // R
        img.data[j+1] = (px >> 5  & 63) << 2;  // G
        img.data[j+2] = (px       & 31) << 3;  // B
        img.data[j+3] = 255;
    }
    ctx.putImageData(img, 0, 0);
}
refresh();
setInterval(refresh, 1000);
</script>
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