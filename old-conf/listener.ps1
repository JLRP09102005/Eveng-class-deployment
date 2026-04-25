#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Bloque 2 - Listener HTTP + creador de VMs EVE-NG en Hyper-V
.DESCRIPTION
    Endpoints:
      POST /create-vm        { "name": "alumno-a" }  -> crea la VM
      GET  /vm-ip/{nombre}   -> consulta la IP de la VM (puede tardar)
      GET  /status           -> lista de VMs del inventario
      GET  /health           -> ping
.NOTES
    Uso: PowerShell como Admin -> .\listener.ps1
#>

# ============================================================
#  CARGAR CONFIGURACION
# ============================================================
$configPath = "C:\HyperV\EVE-NG\lab-config.json"
if (-not (Test-Path $configPath)) {
    Write-Host "[ERROR] No se encuentra lab-config.json" -ForegroundColor Red
    exit 1
}
$CONFIG = Get-Content $configPath | ConvertFrom-Json

$logFolder = Join-Path $CONFIG.VMBasePath "logs"
if (-not (Test-Path $logFolder)) {
    New-Item -ItemType Directory -Path $logFolder -Force | Out-Null
}

# ============================================================
#  LOG
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
    $logFile = Join-Path $logFolder "listener.log"
    $line | Out-File $logFile -Append -Encoding UTF8
}

# ============================================================
#  RESPUESTA HTTP
# ============================================================
function Send-Response {
    param($response, $statusCode, $body)
    try {
        $response.StatusCode = $statusCode
        $response.ContentType = "application/json; charset=utf-8"
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
        $response.ContentLength64 = $bytes.Length
        $response.OutputStream.Write($bytes, 0, $bytes.Length)
        $response.OutputStream.Close()
    } catch {
        $errMsg = $_.Exception.Message
        Write-Log "Error enviando respuesta: $errMsg" "ERROR"
    }
}

# ============================================================
#  INVENTARIO
# ============================================================
$inventoryPath = Join-Path $CONFIG.VMBasePath "inventory.json"

function Get-Inventory {
    if (Test-Path $inventoryPath) {
        $content = Get-Content $inventoryPath -Raw -ErrorAction SilentlyContinue
        if ($content -and $content.Trim() -ne "") {
            try {
                $data = @($content | ConvertFrom-Json)
                return $data
            } catch {
                $errMsg = $_.Exception.Message
                Write-Log "Error leyendo inventario: $errMsg" "ERROR"
            }
        }
    }
    return @()
}

function Save-Inventory {
    param($inv)
    if (-not $inv) { $inv = @() }
    $inv | ConvertTo-Json | Out-File $inventoryPath -Encoding UTF8
}

function Update-VMip {
    param($VMName, $ip)
    $inv = @(Get-Inventory)
    $entry = $inv | Where-Object { $_.Name -eq $VMName }
    if ($entry) {
        $entry.IP     = $ip
        $entry.Status = "ready"
        Save-Inventory $inv
        Write-Log "IP de $VMName actualizada a $ip" "OK"
    }
}

# ============================================================
#  OBTENER IP DE VM VIA HYPER-V
#  Hyper-V tarda en detectar la IP tras el arranque — reintentamos
# ============================================================
function Get-VMip {
    param($VMName)
    $addrs = (Get-VMNetworkAdapter -VMName $VMName -ErrorAction SilentlyContinue).IPAddresses
    if ($addrs) {
        # Filtrar solo IPv4
        $ipv4 = $addrs | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' } | Select-Object -First 1
        return $ipv4
    }
    return $null
}

# ============================================================
#  CREAR VM EN HYPER-V
# ============================================================
function New-EVENGvm {
    param($VMName)

    if (Get-VM -Name $VMName -ErrorAction SilentlyContinue) {
        return @{ success = $false; error = "Ya existe una VM con el nombre $VMName" }
    }

    $vmPath  = Join-Path $CONFIG.VMBasePath "vms\$VMName"
    $vhdPath = Join-Path $vmPath "$VMName-disk.vhdx"

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
        Set-VMMemory    -VMName $VMName -DynamicMemoryEnabled $false
        Set-VMProcessor -VMName $VMName -ExposeVirtualizationExtensions $true

        Add-VMDvdDrive  -VMName $VMName -Path $CONFIG.ISOPath

        $dvd  = Get-VMDvdDrive      -VMName $VMName
        $disk = Get-VMHardDiskDrive -VMName $VMName
        Set-VMFirmware  -VMName $VMName -BootOrder $dvd, $disk
        Set-VMFirmware  -VMName $VMName -EnableSecureBoot Off

        Start-VM -Name $VMName

        # Guardar en inventario sin IP todavia — se actualiza cuando Hyper-V la detecte
        $inv = @(Get-Inventory)
        $inv += [PSCustomObject]@{
            Name    = $VMName
            IP      = $null
            Created = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
            Status  = "creating"
        }
        Save-Inventory $inv

        Write-Log "VM $VMName creada y arrancando — esperando IP del DHCP" "OK"
        return @{ success = $true; name = $VMName; status = "creating" }

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
Write-Log "POST /create-vm        {name}  -> crea la VM" "INFO"
Write-Log "GET  /vm-ip/{nombre}          -> consulta la IP" "INFO"
Write-Log "GET  /status                  -> lista de VMs" "INFO"
Write-Log "GET  /health                  -> ping" "INFO"
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

        # ── GET /health ──────────────────────────────────────
        if ($method -eq "GET" -and $path -eq "/health") {
            Send-Response $response 200 '{"status":"ok"}'
            continue
        }

        # ── GET /status ──────────────────────────────────────
        if ($method -eq "GET" -and $path -eq "/status") {
            $inv = @(Get-Inventory)
            if ($inv.Count -eq 0) {
                Send-Response $response 200 '[]'
            } else {
                Send-Response $response 200 ($inv | ConvertTo-Json)
            }
            continue
        }

        # ── GET /vm-ip/{nombre} ──────────────────────────────
        if ($method -eq "GET" -and $path -match '^/vm-ip/(.+)$') {
            $vmName = $Matches[1]

            # Comprobar que la VM existe
            if (-not (Get-VM -Name $vmName -ErrorAction SilentlyContinue)) {
                Send-Response $response 404 "{`"error`":`"No existe ninguna VM llamada $vmName`"}"
                continue
            }

            # Intentar obtener IP via Hyper-V
            $ip = Get-VMip -VMName $vmName

            if ($ip) {
                # Actualizar inventario si todavia no tenia IP
                $inv = @(Get-Inventory)
                $entry = $inv | Where-Object { $_.Name -eq $vmName }
                if ($entry -and (-not $entry.IP)) {
                    Update-VMip -VMName $vmName -ip $ip
                }
                $body = "{`"name`":`"$vmName`",`"ip`":`"$ip`",`"status`":`"ready`"}"
                Send-Response $response 200 $body
            } else {
                # VM todavia arrancando o instalando EVE-NG
                $body = "{`"name`":`"$vmName`",`"ip`":null,`"status`":`"creating`",`"message`":`"La VM esta arrancando. Vuelve a consultar en unos segundos.`"}"
                Send-Response $response 202 $body
            }
            continue
        }

        # ── POST /create-vm ──────────────────────────────────
        if ($method -eq "POST" -and $path -eq "/create-vm") {

            $reader  = [System.IO.StreamReader]::new($request.InputStream)
            $rawBody = $reader.ReadToEnd()
            $reader.Close()

            if ([string]::IsNullOrWhiteSpace($rawBody)) {
                Send-Response $response 400 '{"error":"Body vacio"}'
                continue
            }

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

            $result = New-EVENGvm -VMName $data.name

            if ($result.success) {
                $body = "{`"name`":`"$($result.name)`",`"status`":`"creating`",`"message`":`"VM arrancando. Consulta GET /vm-ip/$($result.name) para obtener la IP cuando este lista.`"}"
                Send-Response $response 202 $body
            } else {
                $errJson = "{`"error`":`"$($result.error)`"}"
                Send-Response $response 409 $errJson
            }
            continue
        }

        # ── 404 ──────────────────────────────────────────────
        Send-Response $response 404 '{"error":"Endpoint no encontrado"}'

    } catch {
        $errMsg = $_.Exception.Message
        Write-Log "Error en bucle listener: $errMsg" "ERROR"
    }
}