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
    Detener: Cerrar la ventana (Ctrl+C puede no responder, usar la X)
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
# Crear carpeta de logs si no existe
$logFolder = Join-Path $CONFIG.VMBasePath "logs"
if (-not (Test-Path $logFolder)) { New-Item -ItemType Directory -Path $logFolder -Force | Out-Null }

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
    try {
        $response.StatusCode = $statusCode
        $response.ContentType = "application/json; charset=utf-8"
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
        $response.ContentLength64 = $bytes.Length
        $response.OutputStream.Write($bytes, 0, $bytes.Length)
        $response.OutputStream.Close()
    } catch {
        Write-Log "Error enviando respuesta: $_" "ERROR"
    }
}

# ============================================================
#  INVENTARIO DE VMs (fichero JSON simple)
# ============================================================
$inventoryPath = Join-Path $CONFIG.VMBasePath "inventory.json"
Write-Log "Inventario en: $inventoryPath" "INFO"

# Función que SIEMPRE devuelve un array (nunca $null ni un objeto suelto)
# Esto evita el error 'op_Addition' al añadir nuevas entradas.
function Get-Inventory {
    if (Test-Path $inventoryPath) {
        $content = Get-Content $inventoryPath -Raw -ErrorAction SilentlyContinue
        if ($content -and $content.Trim() -ne "") {
            try {
                # Forzar a que sea array usando @() y asegurando que cualquier objeto se convierta en array de 1 elemento
                $data = @( $content | ConvertFrom-Json )
                if ($data.Count -eq 0) { return @() }
                if ($data[0] -eq $null) { return @() }
                if ($data -isnot [array]) { return @($data) }
                return $data
            } catch {
                Write-Log "Error al leer JSON: $_" "ERROR"
                return @()
            }
        }
    }
    return @()
}

# Guarda el inventario (recibe un array, lo convierte a JSON y lo escribe en disco)
function Save-Inventory($inv) {
    if ($inv -eq $null) { $inv = @() }
    if ($inv -isnot [array]) { $inv = @($inv) }
    $inv | ConvertTo-Json | Out-File $inventoryPath -Encoding UTF8
    Write-Log "Inventario guardado con $($inv.Count) entrada(s)" "INFO"
}

# ============================================================
#  CONFIGURACION DE RANGO IP
# ============================================================
$IP_BASE  = "192.168.0"   # Tres primeros octetos de la red del aula
$IP_START = 2             # Primera IP asignable (.1 es el gateway/host)
$IP_END   = 254           # Ultima IP asignable

# ============================================================
#  FUNCION: CALCULAR SIGUIENTE IP DISPONIBLE
# ============================================================
function Get-NextIP {
    $inv = Get-Inventory
    $used = @()
    foreach ($vm in $inv) {
        if ($vm.IP) {
            $ipStr = "$($vm.IP)".Trim()
            if ($ipStr -match '(\d+)$') { $used += [int]$matches[1] }
        }
    }
    Write-Log "IPs usadas: ($($used -join ', '))" "INFO"
    for ($i = $IP_START; $i -le $IP_END; $i++) {
        if ($i -notin $used) {
            $next = "$IP_BASE.$i"
            Write-Log "Siguiente IP libre: $next" "INFO"
            return $next
        }
    }
    Write-Log "ERROR: No hay IPs libres en el rango" "ERROR"
    return $null
}

# ============================================================
#  FUNCION: CREAR VM EN HYPER-V
# ============================================================
function New-VMFromRequest {
    param($VMName, $VMip)

    # Comprobar que la VM no existe ya en Hyper-V
    if (Get-VM -Name $VMName -ErrorAction SilentlyContinue) {
        return @{ success = $false; error = "Ya existe una VM con el nombre '$VMName'" }
    }

    # Comprobar que la IP no esta en uso (según el inventario)
    $inv = Get-Inventory
    if ($inv -isnot [array]) { $inv = @($inv) }
    if ($inv | Where-Object { $_.IP -eq $VMip }) {
        return @{ success = $false; error = "La IP $VMip ya esta asignada a otra VM" }
    }

    try {
        $vmPath = Join-Path $CONFIG.VMBasePath "vms\$VMName"
        $vhdPath = Join-Path $vmPath "$VMName-disk.vhdx"

        # Crear carpeta de la VM
        New-Item -ItemType Directory -Path $vmPath -Force | Out-Null

        # Crear disco virtual dinámico
        New-VHD -Path $vhdPath -SizeBytes $CONFIG.VMDefaultDisk -Dynamic | Out-Null

        # Crear la VM con los parámetros definidos en lab-config.json
        $vmParams = @{
            Name = $VMName
            MemoryStartupBytes = $CONFIG.VMDefaultRAM
            Generation = 2
            VHDPath = $vhdPath
            SwitchName = $CONFIG.SwitchName
            Path = $vmPath
        }
        $vm = New-VM @vmParams

        # Configurar CPU y deshabilitar memoria dinámica
        Set-VMProcessor -VMName $VMName -Count $CONFIG.VMDefaultCPU
        Set-VMMemory -VMName $VMName -DynamicMemoryEnabled $false

        # Habilitar virtualización anidada (necesaria para EVE-NG)
        Set-VMProcessor -VMName $VMName -ExposeVirtualizationExtensions $true

        # Montar la ISO (por ejemplo, Ubuntu Server para EVE-NG)
        Add-VMDvdDrive -VMName $VMName -Path $CONFIG.ISOPath

        # Ajustar orden de arranque: DVD primero
        $dvd = Get-VMDvdDrive -VMName $VMName
        $disk = Get-VMHardDiskDrive -VMName $VMName
        Set-VMFirmware -VMName $VMName -BootOrder $dvd, $disk

        # Deshabilitar Secure Boot (necesario para sistemas Linux/Ubuntu)
        Set-VMFirmware -VMName $VMName -EnableSecureBoot Off

        # Intentar arrancar la VM (si falla, solo se registra como advertencia)
        try {
            Start-VM -Name $VMName -ErrorAction Stop
            Write-Log "VM '$VMName' iniciada correctamente" "OK"
        } catch {
            Write-Log "VM '$VMName' creada pero no se pudo iniciar: $_" "WARN"
        }

        # Añadir la VM al inventario con la IP asignada
        $newEntry = [PSCustomObject]@{
            Name    = $VMName
            IP      = $VMip
            Created = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
            Status  = "created"
        }
        $inv += $newEntry
        Save-Inventory $inv

        Write-Log "VM '$VMName' creada con IP $VMip" "OK"
        return @{ success = $true; name = $VMName; ip = $VMip; status = "created" }

    } catch {
        Write-Log "Error creando VM '$VMName': $_" "ERROR"
        # Limpiar si algo falló a medias
        if (Get-VM -Name $VMName -ErrorAction SilentlyContinue) { Remove-VM -Name $VMName -Force }
        if (Test-Path $vmPath) { Remove-Item $vmPath -Recurse -Force }
        return @{ success = $false; error = $_.ToString() }
    }
}

# ============================================================
#  IMPORTAR MODULO HYPER-V Y SINCRONIZAR INVENTARIO INICIAL
# ============================================================
Import-Module Hyper-V -ErrorAction Stop

# Sincronización inicial: añadir al inventario las VMs existentes en Hyper-V que no tengan entrada
$vmsHyperV = Get-VM | Where-Object { $_.Name -ne "" }
$inventory = Get-Inventory
$changed = $false
foreach ($vm in $vmsHyperV) {
    if (($inventory | Where-Object { $_.Name -eq $vm.Name }) -eq $null) {
        $inventory += [PSCustomObject]@{
            Name    = $vm.Name
            IP      = $null
            Created = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
            Status  = $vm.State
        }
        $changed = $true
    }
}
if ($changed) { Save-Inventory $inventory }

# ============================================================
#  SERVIDOR HTTP (LISTENER)
# ============================================================
$url = "http://+:$($CONFIG.ListenerPort)/"
$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add($url)

try {
    $listener.Start()
} catch {
    Write-Log "No se pudo iniciar el listener en $url : $_" "ERROR"
    Write-Log "Prueba a ejecutar como Administrador o comprueba que el puerto no esta en uso." "WARN"
    exit 1
}

# Mostrar banner y endpoints disponibles
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

# ============================================================
#  BUCLE PRINCIPAL: ATENDER PETICIONES HTTP
# ============================================================
while ($listener.IsListening) {
    try {
        # Esperar petición (bloqueante)
        $context  = $listener.GetContext()
        $request  = $context.Request
        $response = $context.Response
        $method   = $request.HttpMethod
        $path     = $request.Url.AbsolutePath

        Write-Log "$method $path desde $($request.RemoteEndPoint.Address)" "INFO"

        # ── GET /health ──────────────────────────────────────
        if ($method -eq "GET" -and $path -eq "/health") {
            Send-Response $response 200 '{"status":"ok"}'
            continue
        }

        # ── GET /status ──────────────────────────────────────
        if ($method -eq "GET" -and $path -eq "/status") {
            $inv = Get-Inventory
            $body = $inv | ConvertTo-Json
            Send-Response $response 200 $body
            continue
        }

        # ── POST /create-vm ──────────────────────────────────
        if ($method -eq "POST" -and $path -eq "/create-vm") {
            # Leer body JSON
            $rawBody = ""
            try {
                $reader = [System.IO.StreamReader]::new($request.InputStream)
                $rawBody = $reader.ReadToEnd()
                $reader.Close()
            } catch {
                Send-Response $response 400 '{"error":"Error al leer la petición"}'
                continue
            }

            if ([string]::IsNullOrWhiteSpace($rawBody)) {
                Send-Response $response 400 '{"error":"Body vacío"}'
                continue
            }

            try {
                $data = $rawBody | ConvertFrom-Json
            } catch {
                Send-Response $response 400 '{"error":"JSON inválido en el body"}'
                continue
            }

            # Validar campo obligatorio
            if (-not $data.name) {
                Send-Response $response 400 '{"error":"Campo requerido: name"}' 
                continue
            }

            # Validar formato del nombre (solo letras, números y guiones)
            if ($data.name -notmatch '^[a-zA-Z0-9\-]+$') {
                Send-Response $response 400 '{"error":"Nombre inválido. Solo letras, números y guiones."}' 
                continue
            }

            # Calcular siguiente IP disponible automáticamente
            $nextIP = Get-NextIP
            if (-not $nextIP) {
                Send-Response $response 503 '{"error":"Rango de IPs agotado. Contacta con el profesor."}' 
                continue
            }

            # Crear la VM con la IP asignada
            $result = New-VMFromRequest -VMName $data.name -VMip $nextIP

            if ($result.success) {
                $body = $result | ConvertTo-Json
                Send-Response $response 201 $body
            } else {
                $body = @{ error = $result.error } | ConvertTo-Json
                Send-Response $response 409 $body
            }
            continue
        }

        # ── Ruta no encontrada ────────────────────────────────
        Send-Response $response 404 '{"error":"Endpoint no encontrado"}'

    } catch {
        Write-Log "Error en el bucle del listener: $_" "ERROR"
    }
}