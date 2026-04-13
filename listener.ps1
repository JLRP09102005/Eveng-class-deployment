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
Write-Log "Inventario en: $inventoryPath" "INFO"

# Función que SIEMPRE devuelve un array (nunca $null ni un objeto suelto)
function Get-Inventory {
    if (Test-Path $inventoryPath) {
        $content = Get-Content $inventoryPath -Raw -ErrorAction SilentlyContinue
        if ($content -and $content.Trim() -ne "") {
            try {
                # Forzar a que sea array usando @() y asegurando que cualquier objeto se convierta en array de 1 elemento
                $data = @( $content | ConvertFrom-Json )
                # Si el array está vacío, devolver @()
                if ($data.Count -eq 0) { return @() }
                # Si el primer elemento es $null (por un JSON vacío) devolver @()
                if ($data[0] -eq $null) { return @() }
                # En caso de que $data sea un objeto suelto (no debería porque @() lo fuerza), lo envolvemos
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

# Función para guardar inventario (recibe un array)
function Save-Inventory($inv) {
    # Asegurar que $inv es un array
    if ($inv -eq $null) { $inv = @() }
    if ($inv -isnot [array]) { $inv = @($inv) }
    $inv | ConvertTo-Json | Out-File $inventoryPath -Encoding UTF8
    Write-Log "Inventario guardado con $($inv.Count) entrada(s)" "INFO"
}

# Función para obtener siguiente IP libre
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
    $IP_BASE = "192.168.0"
    for ($i = 2; $i -le 254; $i++) {
        if ($i -notin $used) {
            $next = "$IP_BASE.$i"
            Write-Log "Siguiente IP libre: $next" "INFO"
            return $next
        }
    }
    return $null
}

# Función para crear VM
function New-VMFromRequest {
    param($VMName, $VMip)
    if (Get-VM -Name $VMName -ErrorAction SilentlyContinue) {
        return @{ success = $false; error = "Ya existe una VM con el nombre '$VMName'" }
    }
    $inv = Get-Inventory
    # Asegurar que $inv es un array (doble verificación)
    if ($inv -isnot [array]) { $inv = @($inv) }
    if ($inv | Where-Object { $_.IP -eq $VMip }) {
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
        # Intentar iniciar
        try { Start-VM -Name $VMName -ErrorAction Stop }
        catch { Write-Log "VM creada pero no se pudo iniciar: $_" "WARN" }
        # Añadir al inventario
        $newEntry = [PSCustomObject]@{ Name = $VMName; IP = $VMip; Created = (Get-Date -Format "yyyy-MM-dd HH:mm:ss"); Status = "created" }
        $inv += $newEntry
        Save-Inventory $inv
        Write-Log "VM '$VMName' creada con IP $VMip" "OK"
        return @{ success = $true; name = $VMName; ip = $VMip; status = "created" }
    }
    catch {
        Write-Log "Error creando VM: $_" "ERROR"
        if (Get-VM -Name $VMName -ErrorAction SilentlyContinue) { Remove-VM -Name $VMName -Force }
        if (Test-Path $vmPath) { Remove-Item $vmPath -Recurse -Force }
        return @{ success = $false; error = $_.ToString() }
    }
}

Import-Module Hyper-V -ErrorAction Stop

# Sincronización inicial: añadir al inventario las VMs existentes que no tengan IP
$vmsHyperV = Get-VM | Where-Object { $_.Name -ne "" }
$inventory = Get-Inventory
$changed = $false
foreach ($vm in $vmsHyperV) {
    if (($inventory | Where-Object { $_.Name -eq $vm.Name }) -eq $null) {
        $inventory += [PSCustomObject]@{ Name = $vm.Name; IP = $null; Created = (Get-Date -Format "yyyy-MM-dd HH:mm:ss"); Status = $vm.State }
        $changed = $true
    }
}
if ($changed) { Save-Inventory $inventory }

$url = "http://+:$($CONFIG.ListenerPort)/"
$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add($url)

try { $listener.Start() }
catch {
    Write-Log "No se pudo iniciar listener: $_" "ERROR"
    exit 1
}

Write-Host "EVE-NG Lab - Listener activo" -ForegroundColor Cyan
Write-Log "Listener iniciado en $url" "OK"

while ($listener.IsListening) {
    try {
        $context = $listener.GetContext()
        $request = $context.Request
        $response = $context.Response
        $method = $request.HttpMethod
        $path = $request.Url.AbsolutePath

        Write-Log "$method $path desde $($request.RemoteEndPoint.Address)" "INFO"

        if ($method -eq "GET" -and $path -eq "/health") {
            Send-Response $response 200 '{"status":"ok"}'
            continue
        }

        if ($method -eq "GET" -and $path -eq "/status") {
            $inv = Get-Inventory
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
                Send-Response $response 400 '{"error":"Error al leer petición"}'
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

            $result = New-VMFromRequest -VMName $data.name -VMip $nextIP
            if ($result.success) {
                Send-Response $response 201 ($result | ConvertTo-Json)
            } else {
                Send-Response $response 409 (@{ error = $result.error } | ConvertTo-Json)
            }
            continue
        }

        Send-Response $response 404 '{"error":"Endpoint no encontrado"}'
    }
    catch {
        Write-Log "Error en bucle: $_" "ERROR"
    }
}