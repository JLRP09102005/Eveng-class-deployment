#Requires -RunAsAdministrator

$configPath = "C:\HyperV\EVE-NG\lab-config.json"
if (-not (Test-Path $configPath)) {
    Write-Host "[ERROR] No se encuentra lab-config.json" -ForegroundColor Red
    exit 1
}
$CONFIG = Get-Content $configPath | ConvertFrom-Json

$logFolder = Join-Path $CONFIG.VMBasePath "logs"
if (-not (Test-Path $logFolder)) { New-Item -ItemType Directory -Path $logFolder -Force | Out-Null }

function Write-Log {
    param($msg, $level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] [$level] $msg"
    $color = switch ($level) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host $line -ForegroundColor $color
    $logFile = Join-Path $logFolder "listener.log"
    $line | Out-File $logFile -Append -Encoding UTF8
}

function Send-Response {
    param($response, $statusCode, $body)
    $response.StatusCode = $statusCode
    $response.ContentType = "application/json; charset=utf-8"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
    $response.ContentLength64 = $bytes.Length
    $response.OutputStream.Write($bytes, 0, $bytes.Length)
    $response.OutputStream.Close()
}

$inventoryPath = Join-Path $CONFIG.VMBasePath "inventory.json"

function Get-VMInventory {
    if (Test-Path $inventoryPath) {
        $content = Get-Content $inventoryPath -Raw -ErrorAction SilentlyContinue
        if ($content) { return $content | ConvertFrom-Json }
    }
    return @()
}

function Add-VMToInventory {
    param($VMName, $VMip)
    $inv = @(Get-VMInventory)
    $inv += [PSCustomObject]@{ Name = $VMName; IP = $VMip; Created = (Get-Date -Format "yyyy-MM-dd HH:mm:ss"); Status = "running" }
    $inv | ConvertTo-Json | Out-File $inventoryPath -Encoding UTF8
}

$IP_BASE = "192.168.0"
$IP_START = 2
$IP_END = 254

# FUNCIÓN CORREGIDA: extrae el último octeto de forma robusta
function Get-NextIP {
    $inv = Get-VMInventory
    $used = @()
    if ($inv -and $inv.Count -gt 0) {
        $used = $inv | ForEach-Object {
            $ipStr = "$($_.IP)".Trim()
            if ($ipStr -match '(\d+)$') {
                [int]$matches[1]
            }
        }
    }
    for ($i = $IP_START; $i -le $IP_END; $i++) {
        if ($i -notin $used) {
            return "$IP_BASE.$i"
        }
    }
    return $null
}

function New-EVENGvm {
    param($VMName, $VMip)
    if (Get-VM -Name $VMName -ErrorAction SilentlyContinue) {
        return @{ success = $false; error = "Ya existe una VM con el nombre '$VMName'" }
    }
    $inventory = Get-VMInventory
    if ($inventory | Where-Object { $_.IP -eq $VMip }) {
        return @{ success = $false; error = "La IP $VMip ya esta asignada a otra VM" }
    }
    try {
        $vmPath = Join-Path $CONFIG.VMBasePath "vms\$VMName"
        $vhdPath = Join-Path $vmPath "$VMName-disk.vhdx"
        New-Item -ItemType Directory -Path $vmPath -Force | Out-Null
        New-VHD -Path $vhdPath -SizeBytes $CONFIG.VMDefaultDisk -Dynamic | Out-Null
        $vmParams = @{
            Name = $VMName
            MemoryStartupBytes = $CONFIG.VMDefaultRAM
            Generation = 2
            VHDPath = $vhdPath
            SwitchName = $CONFIG.SwitchName
            Path = $vmPath
        }
        $vm = New-VM @vmParams
        Set-VMProcessor -VMName $VMName -Count $CONFIG.VMDefaultCPU
        Set-VMMemory -VMName $VMName -DynamicMemoryEnabled $false
        Set-VMProcessor -VMName $VMName -ExposeVirtualizationExtensions $true
        Add-VMDvdDrive -VMName $VMName -Path $CONFIG.ISOPath
        $dvd = Get-VMDvdDrive -VMName $VMName
        $disk = Get-VMHardDiskDrive -VMName $VMName
        Set-VMFirmware -VMName $VMName -BootOrder $dvd, $disk
        Set-VMFirmware -VMName $VMName -EnableSecureBoot Off
        Start-VM -Name $VMName
        Add-VMToInventory -VMName $VMName -VMip $VMip
        Write-Log "VM '$VMName' creada con IP $VMip" "OK"
        return @{ success = $true; name = $VMName; ip = $VMip; status = "running" }
    }
    catch {
        Write-Log ("Error creando VM '" + $VMName + "': " + $_) "ERROR"
        if (Get-VM -Name $VMName -ErrorAction SilentlyContinue) { Remove-VM -Name $VMName -Force }
        if (Test-Path $vmPath) { Remove-Item $vmPath -Recurse -Force }
        return @{ success = $false; error = $_.ToString() }
    }
}

# Normalizar inventario existente (elimina espacios en IPs)
$invNormalize = Get-VMInventory
$cambios = $false
foreach ($vm in $invNormalize) {
    $ipOriginal = $vm.IP
    $ipLimpia = "$($vm.IP)".Trim()
    if ($ipOriginal -ne $ipLimpia) {
        $vm.IP = $ipLimpia
        $cambios = $true
    }
}
if ($cambios) {
    $invNormalize | ConvertTo-Json | Out-File $inventoryPath -Encoding UTF8
    Write-Log "Inventario normalizado (espacios eliminados de IPs)" "INFO"
}

Import-Module Hyper-V -ErrorAction Stop

$url = "http://+:$($CONFIG.ListenerPort)/"
$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add($url)

try { $listener.Start() }
catch {
    Write-Log ("No se pudo iniciar el listener en " + $url + " : " + $_) "ERROR"
    Write-Log "Prueba a ejecutar como Administrador o comprueba que el puerto no esta en uso." "WARN"
    exit 1
}

Write-Host ""
Write-Host "EVE-NG Lab - Listener activo" -ForegroundColor Cyan
Write-Host ""
Write-Log ("Listener iniciado en " + $url) "OK"
Write-Log "Endpoints disponibles:" "INFO"
Write-Log ("  POST http://<IP-HOST>:" + $CONFIG.ListenerPort + "/create-vm") "INFO"
Write-Log ("  GET  http://<IP-HOST>:" + $CONFIG.ListenerPort + "/status") "INFO"
Write-Log ("  GET  http://<IP-HOST>:" + $CONFIG.ListenerPort + "/health") "INFO"
Write-Host ""

while ($listener.IsListening) {
    try {
        $context = $listener.GetContext()
        $request = $context.Request
        $response = $context.Response
        $method = $request.HttpMethod
        $path = $request.Url.AbsolutePath

        Write-Log ($method + " " + $path + " desde " + $request.RemoteEndPoint.Address) "INFO"

        if ($method -eq "GET" -and $path -eq "/health") {
            Send-Response $response 200 '{"status":"ok"}'
            continue
        }

        if ($method -eq "GET" -and $path -eq "/status") {
            $inv = Get-VMInventory
            $body = $inv | ConvertTo-Json
            if (-not $body) { $body = "[]" }
            Send-Response $response 200 $body
            continue
        }

        if ($method -eq "POST" -and $path -eq "/create-vm") {
            $reader = [System.IO.StreamReader]::new($request.InputStream)
            $rawBody = $reader.ReadToEnd()
            $reader.Close()
            try { $data = $rawBody | ConvertFrom-Json }
            catch { Send-Response $response 400 '{"error":"JSON invalido"}'; continue }
            if (-not $data.name) { Send-Response $response 400 '{"error":"Campo name requerido"}'; continue }
            if ($data.name -notmatch '^[a-zA-Z0-9\-]+$') { Send-Response $response 400 '{"error":"Nombre invalido"}'; continue }
            $nextIP = Get-NextIP
            if (-not $nextIP) { Send-Response $response 503 '{"error":"Rango de IPs agotado"}'; continue }
            $result = New-EVENGvm -VMName $data.name -VMip $nextIP
            if ($result.success) { $body = $result | ConvertTo-Json; Send-Response $response 201 $body }
            else { $body = @{ error = $result.error } | ConvertTo-Json; Send-Response $response 409 $body }
            continue
        }

        Send-Response $response 404 '{"error":"Endpoint no encontrado"}'
    }
    catch {
        Write-Log ("Error en el bucle del listener: " + $_) "ERROR"
    }
}