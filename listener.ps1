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

# Función que sincroniza el inventario con las VMs reales de Hyper-V
function Sync-InventoryWithHyperV {
    Write-Log "Sincronizando inventario con Hyper-V..." "INFO"
    $vms = Get-VM | Where-Object { $_.Name -ne "" } | Select-Object Name, State
    $inventory = @()
    
    # Intentar cargar inventario existente para conservar IPs asignadas previamente
    $oldInventory = @()
    if (Test-Path $inventoryPath) {
        try {
            $oldInventory = Get-Content $inventoryPath -Raw | ConvertFrom-Json
        } catch { Write-Log "Inventario previo corrupto, se reconstruirá" "WARN" }
    }
    
    foreach ($vm in $vms) {
        # Buscar si la VM ya tenía IP asignada en el inventario antiguo
        $oldEntry = $oldInventory | Where-Object { $_.Name -eq $vm.Name }
        if ($oldEntry) {
            $inventory += [PSCustomObject]@{
                Name    = $vm.Name
                IP      = $oldEntry.IP
                Created = $oldEntry.Created
                Status  = $vm.State
            }
        } else {
            # VM nueva sin IP asignada aún, se asignará después
            $inventory += [PSCustomObject]@{
                Name    = $vm.Name
                IP      = $null
                Created = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
                Status  = $vm.State
            }
        }
    }
    
    # Guardar inventario sincronizado
    $inventory | ConvertTo-Json | Out-File $inventoryPath -Encoding UTF8
    Write-Log ("Inventario sincronizado. VMs encontradas: " + $vms.Count) "INFO"
    return $inventory
}

function Get-VMInventory {
    if (Test-Path $inventoryPath) {
        $content = Get-Content $inventoryPath -Raw -ErrorAction SilentlyContinue
        if ($content) {
            try { return $content | ConvertFrom-Json }
            catch { return @() }
        }
    }
    return @()
}

function Add-VMToInventory {
    param($VMName, $VMip)
    $inv = @(Get-VMInventory)
    # Eliminar entrada anterior si existe (por si se recrea)
    $inv = $inv | Where-Object { $_.Name -ne $VMName }
    $inv += [PSCustomObject]@{ Name = $VMName; IP = $VMip; Created = (Get-Date -Format "yyyy-MM-dd HH:mm:ss"); Status = "running" }
    $inv | ConvertTo-Json | Out-File $inventoryPath -Encoding UTF8
}

$IP_BASE = "192.168.0"
$IP_START = 2
$IP_END = 254

function Get-NextIP {
    $inv = Get-VMInventory
    $used = @()
    if ($inv -and $inv.Count -gt 0) {
        $used = $inv | ForEach-Object {
            if ($_.IP) {
                $ipStr = "$($_.IP)".Trim()
                if ($ipStr -match '(\d+)$') { [int]$matches[1] }
            }
        } | Where-Object { $_ -ne $null }
    }
    Write-Log ("DEBUG: IPs usadas = " + ($used -join ', ')) "INFO"
    for ($i = $IP_START; $i -le $IP_END; $i++) {
        if ($i -notin $used) {
            $nextIP = "$IP_BASE.$i"
            Write-Log ("DEBUG: Siguiente IP libre = $nextIP") "INFO"
            return $nextIP
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

Import-Module Hyper-V -ErrorAction Stop

# Sincronizar inventario con las VMs reales de Hyper-V al arrancar
Sync-InventoryWithHyperV | Out-Null

$url = "http://+:$($CONFIG.ListenerPort)/"
$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add($url)

# Manejo de Ctrl+C
$consoleHandler = [ConsoleCancelEventHandler]::new({
    param($sender, $e)
    Write-Host "`n[INFO] Ctrl+C detectado. Cerrando listener..."
    $e.Cancel = $true
    $listener.Stop()
    Write-Host "[INFO] Listener detenido. Saliendo..."
    [Environment]::Exit(0)
})
[Console]::CancelKeyPress += $consoleHandler

try { $listener.Start() }
catch {
    Write-Log ("No se pudo iniciar el listener en " + $url + " : " + $_) "ERROR"
    Write-Log "Prueba a ejecutar como Administrador o comprueba que el puerto no esta en uso." "WARN"
    exit 1
}

Write-Host ""
Write-Host "EVE-NG Lab - Listener activo (Ctrl+C para salir)" -ForegroundColor Cyan
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