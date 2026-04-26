#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Host Windows — Preparacion de Hyper-V para EVE-NG Lab
.DESCRIPTION
    Ejecutar UNA sola vez en el host Windows que creara la plantilla.
    Habilita Hyper-V con switch bridge. La plantilla .vhdx resultante
    se sube manualmente al servidor Ubuntu.
.NOTES
    Uso: PowerShell como Admin -> .\enable-hyperv.ps1
#>

# ============================================================
#  CONFIGURACION
# ============================================================
$CONFIG = @{
    SwitchName   = "EVE-NG-Switch"
    VMBasePath   = "C:\HyperV\EVE-NG"
    ISOPath      = "C:\HyperV\EVE-NG\iso\eve-ce-6.2.0-4-full.iso"
    ISOUrl       = "https://customers.eve-ng.net/eve-ce-prod-6.2.0-4-full.iso"
    VMDefaultRAM = 8GB
    VMDefaultCPU = 4
    VMDefaultDisk= 60GB
}

# ============================================================
#  LOG
# ============================================================
function Write-Step { param($msg) Write-Host "`n[*] $msg" -ForegroundColor Cyan }
function Write-OK   { param($msg) Write-Host "    [OK] $msg" -ForegroundColor Green }
function Write-Warn { param($msg) Write-Host "    [!!] $msg" -ForegroundColor Yellow }
function Write-Fail { param($msg) Write-Host "    [ERROR] $msg" -ForegroundColor Red }
function Confirm-Step {
    param($q)
    $r = Read-Host "`n$q [s/N]"
    return ($r -eq 's' -or $r -eq 'S')
}

# ============================================================
#  BANNER
# ============================================================
Clear-Host
Write-Host "╔══════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║   EVE-NG Lab — Preparacion host Windows     ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Cyan

# ============================================================
#  PASO 1 — Verificar SO
# ============================================================
Write-Step "Verificando sistema operativo..."
$os = Get-CimInstance Win32_OperatingSystem
Write-Host "    SO: $($os.Caption) (Build $($os.BuildNumber))"

if ($os.BuildNumber -lt 19041) {
    Write-Fail "Se requiere Windows 10 build 19041 o superior."
    exit 1
}
if ($os.Caption -match "Home") {
    Write-Fail "Windows Home no soporta Hyper-V."
    exit 1
}
Write-OK "SO compatible."

# ============================================================
#  PASO 2 — Verificar hardware
# ============================================================
Write-Step "Verificando hardware..."
$ramGB    = [math]::Round($os.TotalVisibleMemorySize / 1MB)
$diskFree = [math]::Round((Get-PSDrive C).Free / 1GB)
Write-Host "    RAM total  : $ramGB GB"
Write-Host "    Disco libre: $diskFree GB"
if ($ramGB   -lt 8)  { Write-Warn "Se recomiendan minimo 8 GB de RAM." }
else                  { Write-OK "RAM suficiente." }
if ($diskFree -lt 80) { Write-Fail "Se necesitan minimo 80 GB libres."; exit 1 }
else                  { Write-OK "Espacio suficiente." }

# ============================================================
#  PASO 3 — Habilitar Hyper-V
# ============================================================
Write-Step "Comprobando Hyper-V..."
$feature = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All
if ($feature.State -eq "Enabled") {
    Write-OK "Hyper-V ya habilitado."
    $needsReboot = $false
} else {
    Write-Warn "Hyper-V no habilitado."
    if (-not (Confirm-Step "Habilitar Hyper-V? (requiere reinicio)")) { exit 0 }
    Enable-WindowsOptionalFeature -Online -FeatureName @(
        "Microsoft-Hyper-V-All",
        "Microsoft-Hyper-V",
        "Microsoft-Hyper-V-Tools-All",
        "Microsoft-Hyper-V-Management-PowerShell",
        "Microsoft-Hyper-V-Hypervisor"
    ) -All -NoRestart | Out-Null
    Write-OK "Hyper-V habilitado. Se necesita reinicio."
    $needsReboot = $true
}

# ============================================================
#  PASO 4 — Crear carpetas
# ============================================================
Write-Step "Creando estructura de directorios..."
@(
    $CONFIG.VMBasePath,
    "$($CONFIG.VMBasePath)\iso",
    "$($CONFIG.VMBasePath)\vms",
    "$($CONFIG.VMBasePath)\template"
) | ForEach-Object {
    if (-not (Test-Path $_)) {
        New-Item -ItemType Directory -Path $_ -Force | Out-Null
        Write-OK "Creado: $_"
    } else { Write-OK "Ya existe: $_" }
}

# ============================================================
#  PASO 5 — Crear switch externo en modo bridge
# ============================================================
Write-Step "Configurando switch virtual (modo bridge)..."
try {
    Import-Module Hyper-V -ErrorAction Stop
    if (Get-VMSwitch -Name $CONFIG.SwitchName -ErrorAction SilentlyContinue) {
        Write-OK "Switch '$($CONFIG.SwitchName)' ya existe."
    } else {
        $ethAdapter = Get-NetAdapter -Physical | Where-Object {
            $_.Status -eq "Up" -and
            $_.MediaType -eq "802.3" -and
            $_.InterfaceDescription -notmatch "Wi-Fi|Wireless|WiFi|Bluetooth"
        } | Select-Object -First 1

        if (-not $ethAdapter) {
            Write-Fail "No se encontro adaptador Ethernet activo."
            exit 1
        }
        Write-Host "    Adaptador: $($ethAdapter.Name)"
        New-VMSwitch -Name $CONFIG.SwitchName `
            -NetAdapterName $ethAdapter.Name `
            -AllowManagementOS $true | Out-Null
        Write-OK "Switch bridge '$($CONFIG.SwitchName)' creado."
        Write-Warn "El host puede perder red unos segundos — es normal."
    }
} catch {
    if ($needsReboot) {
        Write-Warn "Switch se creara tras reinicio."
        $scriptPath = "$($CONFIG.VMBasePath)\post-reboot-switch.ps1"
        @"
Import-Module Hyper-V
if (-not (Get-VMSwitch -Name '$($CONFIG.SwitchName)' -ErrorAction SilentlyContinue)) {
    `$eth = Get-NetAdapter -Physical | Where-Object {
        `$_.Status -eq 'Up' -and `$_.MediaType -eq '802.3' -and
        `$_.InterfaceDescription -notmatch 'Wi-Fi|Wireless|WiFi|Bluetooth'
    } | Select-Object -First 1
    if (`$eth) {
        New-VMSwitch -Name '$($CONFIG.SwitchName)' -NetAdapterName `$eth.Name -AllowManagementOS `$true
    }
}
Unregister-ScheduledTask -TaskName 'EVE-NG-CreateSwitch' -Confirm:`$false
"@ | Out-File $scriptPath -Encoding UTF8
        $action  = New-ScheduledTaskAction -Execute "powershell.exe" `
            -Argument "-ExecutionPolicy Bypass -File `"$scriptPath`""
        $trigger = New-ScheduledTaskTrigger -AtStartup
        Register-ScheduledTask -TaskName "EVE-NG-CreateSwitch" -Action $action `
            -Trigger $trigger -RunLevel Highest -User "SYSTEM" -Force | Out-Null
        Write-OK "Tarea programada registrada."
    } else {
        $errMsg = $_.Exception.Message
        Write-Fail "Error creando switch: $errMsg"
    }
}

# ============================================================
#  PASO 6 — Descargar ISO EVE-NG
# ============================================================
Write-Step "ISO de EVE-NG Community..."
if (Test-Path $CONFIG.ISOPath) {
    $size = [math]::Round((Get-Item $CONFIG.ISOPath).Length / 1MB)
    Write-OK "ISO presente ($size MB)."
} else {
    Write-Warn "ISO no encontrada en: $($CONFIG.ISOPath)"
    if (Confirm-Step "Descargar ahora? (~4 GB)") {
        try {
            Start-BitsTransfer -Source $CONFIG.ISOUrl -Destination $CONFIG.ISOPath `
                -Description "EVE-NG Community 6.2.0" -DisplayName "EVE-NG Lab"
            Write-OK "ISO descargada."
        } catch {
            $errMsg = $_.Exception.Message
            Write-Fail "Error: $errMsg"
            Write-Warn "Descarga manual: $($CONFIG.ISOUrl)"
        }
    }
}

# ============================================================
#  PASO 7 — Guardar configuracion
# ============================================================
Write-Step "Guardando configuracion..."
$configPath = "$($CONFIG.VMBasePath)\lab-config.json"
@{
    SwitchName    = $CONFIG.SwitchName
    VMBasePath    = $CONFIG.VMBasePath
    ISOPath       = $CONFIG.ISOPath
    VMDefaultRAM  = $CONFIG.VMDefaultRAM
    VMDefaultCPU  = $CONFIG.VMDefaultCPU
    VMDefaultDisk = $CONFIG.VMDefaultDisk
    SetupDate     = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    Hostname      = $env:COMPUTERNAME
} | ConvertTo-Json | Out-File $configPath -Encoding UTF8
Write-OK "Config guardada: $configPath"

# ============================================================
#  RESUMEN
# ============================================================
Write-Host "`n══════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  RESUMEN" -ForegroundColor Cyan
Write-Host "══════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Host    : $env:COMPUTERNAME"
Write-Host "  Switch  : $($CONFIG.SwitchName) (bridge)"
Write-Host "  Config  : $configPath"
Write-Host "══════════════════════════════════════════════" -ForegroundColor Cyan

if ($needsReboot) {
    Write-Host "`n  !! REINICIO NECESARIO !!" -ForegroundColor Yellow
    if (Confirm-Step "Reiniciar ahora?") { Restart-Computer -Force }
} else {
    Write-Host ""
    Write-OK "Listo. Crea la VM plantilla y exporta el .vhdx al servidor Ubuntu."
}