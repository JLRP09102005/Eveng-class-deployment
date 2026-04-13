#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Bloque 2 - Listener HTTP + creador de VMs EVE-NG en Hyper-V
.DESCRIPTION
    POST /create-vm  { "name": "alumno-a" }  -> IP asignada automaticamente
    GET  /status     -> lista de VMs creadas
    GET  /health     -> ping de estado
.NOTES
    Uso: PowerShell como Admin -> .\listener.ps1
#>

# ============================================================
#  CARGAR CONFIGURACION DEL BLOQUE 1
# ============================================================
$configPath = "C:\HyperV\EVE-NG\lab-config.json"
if (-not (Test-Path $configPath)) {
    Write-Host "[ERROR] No se encuentra lab-config.json. Ejecuta primero enable-hyperv.ps1" -ForegroundColor Red
    exit 1
}
$CONFIG = Get-Content $configPath | ConvertFrom-Json

# ============================================================
#  RANGO DE IPs ASIGNABLES
# ============================================================
$IP_BASE  = "192.168.0"
$IP_START = 2
$IP_END   = 254

# ============================================================
#  FUNCIONES DE LOG
# ============================================================
function Write-Log {
    param($msg, $level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] [$level] $msg"
    $color = switch ($level) {
        "OK"    { "Green" }
        "WARN"  { "Yellow" }
        "ERROR" { "Red" }
        default { "Cyan" }
    }
    Write-Host $line -ForegroundColor $color
    Add-Content -Path "$($CONFIG.VMBasePath)\logs\listener.log" -Value $line -Encoding UTF8
}

# ============================================================
#  FUNCION: ENVIAR RESPUESTA HTTP
# ============================================================
function Send-Response {
    param($response, $statusCode, $body)
    $response.StatusCode = $statusCode
    $response.ContentType = "application/json; charset=utf-8"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
    $response.ContentLength64 = $bytes.Length
    $response.OutputStream.Write($bytes, 0, $bytes.Length)
    $response.OutputStream.Close()
}

# ============================================================
#  INVENTARIO DE VMs
# ============================================================
$inventoryPath = "$($CONFIG.VMBasePath)\inventory.json"

function Get-VMInventory {
    if (Test-Path $inventoryPath) {
        $raw = Get-Content $inventoryPath -Raw
        if ($raw) {
            $parsed = $raw | ConvertFrom-Json
            if ($parsed -isnot [Array]) { return @($parsed) }
            return $parsed
        }
    }
    return @()
}

function Add-VMToInventory {
    param($VMName, $VMip)
    $inv = @(Get-VMInventory)
    $inv += [PSCustomObject]@{
        Name    = $VMName
        IP      = $VMip
        Created = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        Status  = "running"
    }
    $inv | ConvertTo-Json | Out-File $inventoryPath -Encoding UTF8
}

# ============================================================
#  FUNCION: SIGUIENTE IP LIBRE
# ============================================================
function Get-NextIP {
    $inv  = Get-VMInventory
    $used = @($inv | ForEach-Object { [int]($_.IP -split '\.')[-1] })
    for ($i = $IP_START; $i -le $IP_END; $i++) {
        if ($i -notin $used) {
            return "$IP_BASE.$i"
        }
    }
    return $null
}

# ============================================================
#  FUNCION: CREAR VM EN HYPER-V
# ============================================================
function New-EVENGvm {
    param([string]$VMName, [string]$VMip)

    if (Get-VM -Name $VMName -ErrorAction SilentlyContinue) {
        return @{ success = $false; error = "Ya existe una VM con el nombre $VMName" }
    }

    $vmPath  = "$($CONFIG.VMBasePath)\vms\$VMName"
    $vhdPath = "$vmPath\$VMName-disk.vhdx"

    try {
        New-Item -ItemType Directory -Path $vmPath -Force | Out-Null
        New-VHD -Path $vhdPath -SizeBytes $CONFIG.VMDefaultDisk -Dynamic | Out-Null

        New-VM -Name $VMName `
            -MemoryStartupBytes $CONFIG.VMDefaultRAM `
            -Generation 2 `
            -VHDPath $vhdPath `
            -SwitchName $CONFIG.SwitchName `
            -Path $vmPath | Out-Null

        Set-VMProcessor -VMName $VMName -Count $CONFIG.VMDefaultCPU
        Set-VMProcessor -VMName $VMName -ExposeVirtualizationExtensions $true
        Set-VMMemory    -VMName $VMName -DynamicMemoryEnabled $false

        Add-VMDvdDrive  -VMName $VMName -Path $CONFIG.ISOPath

        $dvd  = Get-VMDvdDrive      -VMName $VMName
        $disk = Get-VMHardDiskDrive -VMName $VMName
        Set-VMFirmware  -VMName $VMName -BootOrder $dvd, $disk
        Set-VMFirmware  -VMName $VMName -EnableSecureBoot Off

        Start-VM -Name $VMName

        Add-VMToInventory -VMName $VMName -VMip $VMip

        Write-Log "VM $VMName creada con IP $VMip" "OK"
        return @{ success = $true; name = $VMName; ip = $VMip; status = "running" }

    } catch {
        $errMsg = $_.Exception.Message
        Write-Log "Error creando VM $VMName : $errMsg" "ERROR"
        if (Get-VM -Name $VMName -ErrorAction SilentlyContinue) {
            Remove-VM -Name $VMName -Force | Out-Null
        }
        if (Test-Path $vmPath) { Remove-Item $vmPath -Recurse -Force | Out-Null }
        return @{ success = $false; error = $errMsg }
    }
}

# ============================================================
#  ARRANCAR SERVIDOR HTTP
# ============================================================
Import-Module Hyper-V -ErrorAction Stop

$url = "http://+:$($CONFIG.ListenerPort)/"
$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add($url)

try {
    $listener.Start()
} catch {
    $errMsg = $_.Exception.Message
    Write-Log "No se pudo iniciar el listener: $errMsg" "ERROR"
    exit 1
}

Write-Host ""
Write-Host "╔══════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║   EVE-NG Lab - Bloque 2: Listener activo    ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""
Write-Log "Listener iniciado en $url" "OK"
Write-Log "POST http://<IP>:$($CONFIG.ListenerPort)/create-vm  {name}" "INFO"
Write-Log "GET  http://<IP>:$($CONFIG.ListenerPort)/status" "INFO"
Write-Log "GET  http://<IP>:$($CONFIG.ListenerPort)/health" "INFO"
Write-Host ""

# ============================================================
#  BUCLE PRINCIPAL
# ============================================================
while ($listener.IsListening) {
    try {
        $context  = $listener.GetContext()
        $request  = $context.Request
        $response = $context.Response
        $method   = $request.HttpMethod
        $path     = $request.Url.AbsolutePath
        $clientIP = $request.RemoteEndPoint.Address

        Write-Log "$method $path desde $clientIP" "INFO"

        # GET /health
        if ($method -eq "GET" -and $path -eq "/health") {
            Send-Response $response 200 '{"status":"ok"}'
            continue
        }

        # GET /status
        if ($method -eq "GET" -and $path -eq "/status") {
            $inv = Get-VMInventory
            if ($inv.Count -eq 0) {
                Send-Response $response 200 '[]'
            } else {
                Send-Response $response 200 ($inv | ConvertTo-Json)
            }
            continue
        }

        # POST /create-vm
        if ($method -eq "POST" -and $path -eq "/create-vm") {

            $reader  = [System.IO.StreamReader]::new($request.InputStream)
            $rawBody = $reader.ReadToEnd()
            $reader.Close()

            try {
                $data = $rawBody | ConvertFrom-Json
            } catch {
                Send-Response $response 400 '{"error":"JSON invalido"}'
                continue
            }

            if (-not $data.name) {
                Send-Response $response 400 '{"error":"Campo requerido: name"}'
                continue
            }

            if ($data.name -notmatch '^[a-zA-Z0-9\-]+$') {
                Send-Response $response 400 '{"error":"Nombre invalido. Solo letras, numeros y guiones."}'
                continue
            }

            $nextIP = Get-NextIP
            if (-not $nextIP) {
                Send-Response $response 503 '{"error":"Rango de IPs agotado"}'
                continue
            }

            $result = New-EVENGvm -VMName $data.name -VMip $nextIP

            if ($result.success) {
                Send-Response $response 201 ($result | ConvertTo-Json)
            } else {
                $errJson = '{"error":"' + $result.error + '"}'
                Send-Response $response 409 $errJson
            }
            continue
        }

        # 404
        Send-Response $response 404 '{"error":"Endpoint no encontrado"}'

    } catch {
        $errMsg = $_.Exception.Message
        Write-Log "Error en bucle listener: $errMsg" "ERROR"
    }
}