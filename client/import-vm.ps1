#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Importar VM — Registra la VM descargada en Hyper-V local
.DESCRIPTION
    Lee client-config.json, importa el .vhdx en Hyper-V con
    switch bridge y virtualizacion anidada habilitada.
    Solo hace falta ejecutarlo UNA vez por VM.
.NOTES
    Uso: .\import-vm.ps1
    Requisito: haber ejecutado sync.ps1 -mode pull primero
#>

# ============================================================
#  CARGAR CONFIGURACION
# ============================================================
$configPath = "C:\EVE-NG-Local\client-config.json"
if (-not (Test-Path $configPath)) {
    Write-Host "[ERROR] No se encuentra client-config.json" -ForegroundColor Red
    Write-Host "        Ejecuta primero setup-client.ps1" -ForegroundColor Yellow
    Read-Host "Pulsa Enter para salir"
    exit 1
}
$CONFIG = Get-Content $configPath | ConvertFrom-Json

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
}

# ============================================================
#  BANNER
# ============================================================
Clear-Host
Write-Host "╔══════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║   EVE-NG Lab — Importar VM en Hyper-V       ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

# ============================================================
#  VERIFICAR FICHEROS
# ============================================================
$localVhdx = "$($CONFIG.LocalPath)\$($CONFIG.VMName).vhdx"
$localIso  = "$($CONFIG.LocalPath)\eve-ce-6.2.0-4-full.iso"

Write-Log "Verificando ficheros locales..."

if (-not (Test-Path $localVhdx)) {
    Write-Log "No se encuentra: $localVhdx" "ERROR"
    Write-Log "Ejecuta primero: sync.ps1 -mode pull" "WARN"
    Read-Host "Pulsa Enter para salir"
    exit 1
}
Write-Log "VHDX encontrado: $localVhdx" "OK"

if (-not (Test-Path $localIso)) {
    Write-Log "ISO no encontrada en local. Se montara sin DVD." "WARN"
    $hasISO = $false
} else {
    Write-Log "ISO encontrada: $localIso" "OK"
    $hasISO = $true
}

# ============================================================
#  CARGAR HYPER-V
# ============================================================
Import-Module Hyper-V -ErrorAction Stop

# ============================================================
#  COMPROBAR SI LA VM YA EXISTE
# ============================================================
if (Get-VM -Name $CONFIG.VMName -ErrorAction SilentlyContinue) {
    Write-Log "La VM '$($CONFIG.VMName)' ya existe en Hyper-V." "WARN"
    Write-Host ""
    Write-Host "  La VM ya esta importada. Arrancala desde Hyper-V Manager." -ForegroundColor Yellow
    Read-Host "`n  Pulsa Enter para salir"
    exit 0
}

# ============================================================
#  VERIFICAR SWITCH
# ============================================================
Write-Log "Verificando switch Hyper-V..."
if (-not (Get-VMSwitch -Name $CONFIG.SwitchName -ErrorAction SilentlyContinue)) {
    Write-Log "Switch '$($CONFIG.SwitchName)' no encontrado. Intentando crear..." "WARN"
    $ethAdapter = Get-NetAdapter -Physical | Where-Object {
        $_.Status -eq "Up" -and
        $_.MediaType -eq "802.3" -and
        $_.InterfaceDescription -notmatch "Wi-Fi|Wireless|WiFi|Bluetooth"
    } | Select-Object -First 1

    if ($ethAdapter) {
        New-VMSwitch -Name $CONFIG.SwitchName `
            -NetAdapterName $ethAdapter.Name `
            -AllowManagementOS $true | Out-Null
        Write-Log "Switch '$($CONFIG.SwitchName)' creado." "OK"
    } else {
        Write-Log "No se encontro adaptador Ethernet. Creando switch interno..." "WARN"
        New-VMSwitch -Name $CONFIG.SwitchName -SwitchType Internal | Out-Null
        Write-Log "Switch interno creado (sin acceso a red del aula)." "WARN"
    }
} else {
    Write-Log "Switch '$($CONFIG.SwitchName)' encontrado." "OK"
}

# ============================================================
#  CREAR LA VM
# ============================================================
Write-Log "Creando VM '$($CONFIG.VMName)' en Hyper-V..."

try {
    # Crear la VM con el .vhdx descargado
    New-VM -Name $CONFIG.VMName `
        -MemoryStartupBytes 8GB `
        -Generation 2 `
        -VHDPath $localVhdx `
        -SwitchName $CONFIG.SwitchName | Out-Null

    # Configurar CPU y memoria
    Set-VMProcessor -VMName $CONFIG.VMName -Count 4
    Set-VMMemory    -VMName $CONFIG.VMName -DynamicMemoryEnabled $false

    # Habilitar virtualizacion anidada (necesaria para EVE-NG)
    Set-VMProcessor -VMName $CONFIG.VMName -ExposeVirtualizationExtensions $true
    Write-Log "Virtualizacion anidada habilitada." "OK"

    # Montar ISO si esta disponible
    if ($hasISO) {
        Add-VMDvdDrive -VMName $CONFIG.VMName -Path $localIso
        $dvd  = Get-VMDvdDrive      -VMName $CONFIG.VMName
        $disk = Get-VMHardDiskDrive -VMName $CONFIG.VMName
        Set-VMFirmware -VMName $CONFIG.VMName -BootOrder $dvd, $disk
        Write-Log "ISO de EVE-NG montada como DVD." "OK"
    }

    # Deshabilitar Secure Boot
    Set-VMFirmware -VMName $CONFIG.VMName -EnableSecureBoot Off
    Write-Log "Secure Boot deshabilitado." "OK"

    Write-Log "VM '$($CONFIG.VMName)' importada correctamente." "OK"

} catch {
    $errMsg = $_.Exception.Message
    Write-Log "Error creando VM: $errMsg" "ERROR"
    # Limpiar si fallo a medias
    if (Get-VM -Name $CONFIG.VMName -ErrorAction SilentlyContinue) {
        Remove-VM -Name $CONFIG.VMName -Force | Out-Null
    }
    Read-Host "Pulsa Enter para salir"
    exit 1
}

# ============================================================
#  RESUMEN
# ============================================================
Write-Host ""
Write-Host "══════════════════════════════════════════════" -ForegroundColor Green
Write-Host "  VM importada correctamente." -ForegroundColor Green
Write-Host "══════════════════════════════════════════════" -ForegroundColor Green
Write-Host "  Nombre VM : $($CONFIG.VMName)"
Write-Host "  Switch    : $($CONFIG.SwitchName) (bridge)"
Write-Host "  VHDX      : $localVhdx"
if ($hasISO) {
    Write-Host "  ISO       : Montada (primera instalacion)"
}
Write-Host "══════════════════════════════════════════════" -ForegroundColor Green
Write-Host ""
Write-Host "  Abre Hyper-V Manager y arranca la VM." -ForegroundColor Yellow
Write-Host "  Sigue el instalador de EVE-NG en la consola." -ForegroundColor Yellow
Write-Host ""
Read-Host "Pulsa Enter para cerrar"