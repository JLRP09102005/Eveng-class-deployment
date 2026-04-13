#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Bloque 2 — Listener HTTP + creador de VMs EVE-NG en Hyper-V
.DESCRIPTION
    Servidor HTTP que escucha en el puerto 8080.
    Los alumnos hacen POST /create-vm desde su navegador o terminal
    y el script crea automaticamente una VM con la ISO de EVE-NG Community.

    Endpoints:
      POST /create-vm   { "name": "alumno-a" }  -> IP asignada automaticamente
      GET  /status      -> lista de VMs creadas
      GET  /health      -> ping de estado del servidor

.NOTES
    Uso: PowerShell como Admin -> .\listener.ps1
    Detener: Ctrl+C
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
#  FUNCIONES DE LOG
# ============================================================
$logFolder = Join-Path $CONFIG.VMBasePath "logs"
if (-not (Test-Path $logFolder)) {
    New-Item -ItemType Directory -Path $logFolder -Force | Out-Null
}

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

# ============================================================
#  INVENTARIO DE VMs (fichero JSON simple)
# ============================================================
$inventoryPath = Join-Path $CONFIG.VMBasePath "inventory.json"

function Get-VMInventory {
    if (Test-Path $inventoryPath) {
        $content = Get-Content $inventoryPath -Raw -ErrorAction SilentlyContinue
        if ($content) {
            return $content | ConvertFrom-Json
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
#  CONFIGURACION DE RANGO IP
# ============================================================
$IP_BASE  = "192.168.0"
$IP_START = 2
$IP_END   = 254

function Get-NextIP {
    $inv  = Get-VMInventory
    $used = @()
    if ($inv -and $inv.Count -gt 0) {
        $used = $inv | ForEach-Object { if ($_.IP) { [int]($_.IP -split '\.')[-1] } }
    }
    for ($i = $IP_START; $i -le $IP_END; $i++) {
        if ($i -notin $used) { return "$IP_BASE.$i" }
    }
    return $null
}

# ============================================================
#  FUNCION: CREAR VM EN HYPER-V
# ============================================================
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
        $vmPath  = Join-Path $CONFIG.VMBasePath "vms\$VMName"
        $vhdPath = Join-Path $vmPath "$VMName-disk.vhdx"

        New-Item -ItemType Directory -Path $vmPath -Force | Out-Null
        New-VHD -Path $vhdPath -SizeBytes $CONFIG.VMDefaultDisk -Dynamic | Out-Null

        # Crear VM sin usar backticks
        $vmParams = @{
            Name                    = $VMName
            MemoryStartupBytes      = $CONFIG.VMDefaultRAM
            Generation              = 2
            VHDPath                 = $vhdPath
            SwitchName              = $CONFIG.SwitchName
            Path                    = $vmPath
        }
        $vm = New-VM @vmParams

        Set-VMProcessor -VMName $VMName -Count $CONFIG.VMDefaultCPU
        Set-VMMemory -VMName $VMName -DynamicMemoryEnabled $false
        Set-VMProcessor -VMName $VMName -ExposeVirtualizationExtensions $true
        Add-VMDvdDrive -VMName $VMName -Path $CONFIG.ISOPath

        $dvd  = Get-VMDvdDrive -VMName $VMName
        $disk = Get-VMHardDiskDrive -VMName $VMName
        Set-VMFirmware -VMName $VMName -BootOrder $dvd, $disk
        Set-VMFirmware -VMName $VMName -EnableSecureBoot Off

        Start-VM -Name $VMName
        Add-VMToInventory -VMName $VMName -VMip $VMip

        Write-Log "VM '$VMName' creada con IP $VMip" "OK"
        return @{ success = $true; name = $VMName; ip = $VMip; status = "running" }
    }
    catch {
        Write-Log "Error creando VM '$VMName': $_" "ERROR"
        if (Get-VM -Name $VMName -ErrorAction SilentlyContinue) {
            Remove-VM -Name $VMName -Force
        }
        if (Test-Path $vmPath) {
            Remove-Item $vmPath -Recurse -Force
        }
        return @{ success = $false; error = $_.ToString() }
    }
}

# ============================================================
#  SERVIDOR HTTP
# ============================================================
Import-Module Hyper-V -ErrorAction Stop

$url = "http://+:$($CONFIG.ListenerPort)/"
$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add($url)

try {
    $listener.Start()
}
catch {
    Write-Log "No se pudo iniciar el listener en $url : $_" "ERROR"
    Write-Log "Prueba a ejecutar como Administrador o comprueba que el puerto no esta en uso." "WARN"
    exit 1
}

Write-Host ""
Write-Host "╔══════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║   EVE-NG Lab — Bloque 2: Listener activo    ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""
Write-Log "Listener iniciado en $url" "OK"
Write-Log "Endpoints disponibles:" "INFO"
Write-Log "  POST http://<IP-HOST>:$($CONFIG.ListenerPort)/create-vm" "INFO"
Write-Log "  GET  http://<IP-HOST>:$($CONFIG.ListenerPort)/status" "INFO"
Write-Log "  GET  http://<IP-HOST>:$($CONFIG.ListenerPort)/health" "INFO"
Write-Host ""

while ($listener.IsListening) {
    try {
        $context  = $listener.GetContext()
        $request  = $context.Request
        $response = $context.Response
        $method   = $request.HttpMethod
        $path     = $request.Url.AbsolutePath

        Write-Log "$method $path desde $($request.RemoteEndPoint.Address)" "INFO"

        # GET /health
        if ($method -eq "GET" -and $path -eq "/health") {
            Send-Response $response 200 '{"status":"ok"}'
            continue
        }

        # GET /status
        if ($method -eq "GET" -and $path -eq "/status") {
            $inv  = Get-VMInventory
            $body = $inv | ConvertTo-Json
            if (-not $body) { $body = "[]" }
            Send-Response $response 200 $body
            continue
        }

        # POST /create-vm
        if ($method -eq "POST" -and $path -eq "/create-vm") {
            $reader = [System.IO.StreamReader]::new($request.InputStream)
            $rawBody = $reader.ReadToEnd()
            $reader.Close()

            try {
                $data = $rawBody | ConvertFrom-Json
            }
            catch {
                Send-Response $response 400 '{"error":"JSON invalido en el body"}'
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
                Send-Response $response 503 '{"error":"Rango de IPs agotado. Contacta con el profesor."}'
                continue
            }

            $result = New-EVENGvm -VMName $data.name -VMip $nextIP

            if ($result.success) {
                $body = $result | ConvertTo-Json
                Send-Response $response 201 $body
            }
            else {
                $body = @{ error = $result.error } | ConvertTo-Json
                Send-Response $response 409 $body
            }
            continue
        }

        Send-Response $response 404 '{"error":"Endpoint no encontrado"}'
    }
    catch {
        Write-Log "Error en el bucle del listener: $_" "ERROR"
    }
}