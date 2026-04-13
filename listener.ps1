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
    try {
        $response.StatusCode = $statusCode
        $response.ContentType = "application/json; charset=utf-8"
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
        $response.ContentLength64 = $bytes.Length
        $response.OutputStream.Write($bytes, 0, $bytes.Length)
        $response.OutputStream.Close()
    } catch { Write-Log "Error enviando respuesta: $_" "ERROR" }
}

$inventoryPath = Join-Path $CONFIG.VMBasePath "inventory.json"

# Función que SIEMPRE devuelve un ARRAY (nunca $null)
function Get-VMInventory {
    if (Test-Path $inventoryPath) {
        $content = Get-Content $inventoryPath -Raw -ErrorAction SilentlyContinue
        if ($content -and $content.Trim() -ne "") {
            try {
                $data = $content | ConvertFrom-Json
                # Forzar a que sea un array
                if ($data -is [array]) { return $data }
                elseif ($data -is [PSCustomObject]) { return @($data) }
                else { return @() }
            } catch {
                Write-Log "ERROR al convertir JSON: $_" "ERROR"
                return @()
            }
        }
    }
    return @()
}

function Add-VMToInventory {
    param($VMName, $VMip)
    $inv = @(Get-VMInventory)   # Aseguramos array
    $inv = $inv | Where-Object { $_.Name -ne $VMName }
    $inv += [PSCustomObject]@{ Name = $VMName; IP = $VMip; Created = (Get-Date -Format "yyyy-MM-dd HH:mm:ss"); Status = "running" }
    $inv | ConvertTo-Json | Out-File $inventoryPath -Encoding UTF8
    Write-Log "Inventario actualizado: $VMName -> $VMip" "INFO"
}

$IP_BASE = "192.168.0"
$IP_START = 2
$IP_END = 254

function Get-NextIP {
    $inv = Get-VMInventory
    $used = @()
    if ($inv.Count -gt 0) {
        $used = $inv | ForEach-Object {
            if ($_.IP) {
                $ipStr = "$($_.IP)".Trim()
                if ($ipStr -match '(\d+)$') { [int]$matches[1] }
            }
        } | Where-Object { $_ -ne $null }
    }
    Write-Log "DEBUG: IPs usadas = ($($used -join ', '))" "INFO"
    for ($i = $IP_START; $i -le $IP_END; $i++) {
        if ($i -notin $used) {
            $nextIP = "$IP_BASE.$i"
            Write-Log "DEBUG: Siguiente IP libre = $nextIP" "INFO"
            return $nextIP
        }
    }
    return $null
}

function New-EVENGvm {
    param($VMName, $VMip)
    # Verificar si ya existe en Hyper-V
    if (Get-VM -Name $VMName -ErrorAction SilentlyContinue) {
        return @{ success = $false; error = "Ya existe una VM con el nombre '$VMName'" }
    }
    # Verificar IP no asignada en inventario
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
        # Intentar iniciar la VM (puede fallar si Hyper-V no está bien)
        try {
            Start-VM -Name $VMName -ErrorAction Stop
            Write-Log "VM '$VMName' iniciada correctamente" "OK"
        } catch {
            Write-Log "VM '$VMName' creada pero no se pudo iniciar: $_" "WARN"
            # No lanzamos excepción, la VM ya está creada
        }
        Add-VMToInventory -VMName $VMName -VMip $VMip
        Write-Log "VM '$VMName' creada con IP $VMip" "OK"
        return @{ success = $true; name = $VMName; ip = $VMip; status = "created" }
    }
    catch {
        Write-Log ("Error creando VM '" + $VMName + "': " + $_) "ERROR"
        if (Get-VM -Name $VMName -ErrorAction SilentlyContinue) { Remove-VM -Name $VMName -Force }
        if (Test-Path $vmPath) { Remove-Item $vmPath -Recurse -Force }
        return @{ success = $false; error = $_.ToString() }
    }
}

Import-Module Hyper-V -ErrorAction Stop

# Sincronización inicial: si hay VMs en Hyper-V sin inventario, se añaden sin IP (luego se asignará)
$vmsExistentes = Get-VM | Where-Object { $_.Name -ne "" }
$invActual = Get-VMInventory
foreach ($vm in $vmsExistentes) {
    if (($invActual | Where-Object { $_.Name -eq $vm.Name }) -eq $null) {
        # VM sin entrada en inventario -> la añadimos con IP pendiente
        $invActual += [PSCustomObject]@{ Name = $vm.Name; IP = $null; Created = (Get-Date -Format "yyyy-MM-dd HH:mm:ss"); Status = $vm.State }
    }
}
if ($invActual.Count -gt 0) {
    $invActual | ConvertTo-Json | Out-File $inventoryPath -Encoding UTF8
    Write-Log "Inventario sincronizado con VMs existentes. Total: $($invActual.Count)" "INFO"
}

$url = "http://+:$($CONFIG.ListenerPort)/"
$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add($url)

try { $listener.Start() }
catch {
    Write-Log ("No se pudo iniciar el listener en " + $url + " : " + $_) "ERROR"
    exit 1
}

Write-Host ""
Write-Host "EVE-NG Lab - Listener activo" -ForegroundColor Cyan
Write-Log ("Listener iniciado en " + $url) "OK"
Write-Log "Endpoints:" "INFO"
Write-Log "  POST /create-vm" "INFO"
Write-Log "  GET  /status" "INFO"
Write-Log "  GET  /health" "INFO"
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
            Send-Response $response 200 $body
            continue
        }

        if ($method -eq "POST" -and $path -eq "/create-vm") {
            $rawBody = ""
            try {
                $reader = [System.IO.StreamReader]::new($request.InputStream)
                $rawBody = $reader.ReadToEnd()
                $reader.Close()
            } catch {
                Write-Log "Error leyendo body: $_" "WARN"
                Send-Response $response 400 '{"error":"Error al leer la petición"}'
                continue
            }
            if ([string]::IsNullOrWhiteSpace($rawBody)) {
                Send-Response $response 400 '{"error":"Body vacío"}'
                continue
            }
            try { $data = $rawBody | ConvertFrom-Json }
            catch { Send-Response $response 400 '{"error":"JSON inválido"}'; continue }

            if (-not $data.name) { Send-Response $response 400 '{"error":"Campo name requerido"}'; continue }
            if ($data.name -notmatch '^[a-zA-Z0-9\-]+$') { Send-Response $response 400 '{"error":"Nombre inválido"}'; continue }

            $nextIP = Get-NextIP
            if (-not $nextIP) { Send-Response $response 503 '{"error":"Rango de IPs agotado"}'; continue }

            $result = New-EVENGvm -VMName $data.name -VMip $nextIP
            if ($result.success) {
                $body = $result | ConvertTo-Json
                Send-Response $response 201 $body
            } else {
                $body = @{ error = $result.error } | ConvertTo-Json
                Send-Response $response 409 $body
            }
            continue
        }

        Send-Response $response 404 '{"error":"Endpoint no encontrado"}'
    }
    catch {
        Write-Log ("Error en bucle principal: " + $_) "ERROR"
    }
}