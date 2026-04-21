#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Bloque 1 — Preparacion del host Windows para EVE-NG via Hyper-V
.DESCRIPTION
    Ejecutar UNA sola vez por PC del centro, como Administrador.
    Habilita Hyper-V, crea el bridge de red, descarga la ISO de Ubuntu
    y guarda la configuracion para los scripts del Bloque 2.
.NOTES
    Uso: PowerShell como Admin -> Set-ExecutionPolicy Bypass -Scope Process -> .\enable-hyperv.ps1
#>

# ============================================================
#  CONFIGURACION — ajustar segun el aula
# ============================================================
$CONFIG = @{
    SwitchName    = "EVE-NG-Switch"
    VMBasePath    = "C:\HyperV\EVE-NG"
    ISOPath       = "C:\HyperV\EVE-NG\iso\eve-ce-6.2.0-4-full.iso"
    ISOUrl        = "https://customers.eve-ng.net/eve-ce-prod-6.2.0-4-full.iso"
    HostIP        = "192.168.0.1"
    SubnetPrefix  = 24
    VMSubnet      = "192.168.0.0/24"
    ListenerPort  = 8080
    VMDefaultRAM  = 8GB
    VMDefaultCPU  = 4
    VMDefaultDisk = 60GB
}

# ============================================================
#  FUNCIONES DE LOG
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
Write-Host "║   EVE-NG Lab — Bloque 1: Preparacion host   ║" -ForegroundColor Cyan
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
    Write-Fail "Windows Home no soporta Hyper-V. Necesitas Pro, Education o Enterprise."
    exit 1
}
Write-OK "SO compatible."

# ============================================================
#  PASO 2 — Verificar hardware
# ============================================================
Write-Step "Verificando hardware..."
$ramGB = [math]::Round($os.TotalVisibleMemorySize / 1MB)
$diskFree = [math]::Round((Get-PSDrive C).Free / 1GB)
Write-Host "    RAM total  : $ramGB GB"
Write-Host "    Disco libre: $diskFree GB en C:"

if ($ramGB -lt 8)   { Write-Warn "Se recomiendan minimo 8 GB de RAM." }
else                { Write-OK "RAM suficiente." }

if ($diskFree -lt 80) {
    Write-Fail "Espacio insuficiente. Se necesitan minimo 80 GB libres en C:."
    exit 1
}
Write-OK "Espacio en disco suficiente."

# ============================================================
#  PASO 3 — Habilitar Hyper-V
# ============================================================
Write-Step "Comprobando Hyper-V..."
$feature = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All

if ($feature.State -eq "Enabled") {
    Write-OK "Hyper-V ya esta habilitado."
    $needsReboot = $false
} else {
    Write-Warn "Hyper-V no esta habilitado."
    if (-not (Confirm-Step "Habilitar Hyper-V ahora? (requiere reinicio)")) { exit 0 }

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
    "$($CONFIG.VMBasePath)\logs"
) | ForEach-Object {
    if (-not (Test-Path $_)) {
        New-Item -ItemType Directory -Path $_ -Force | Out-Null
        Write-OK "Creado: $_"
    } else {
        Write-OK "Ya existe: $_"
    }
}

# ============================================================
#  PASO 5 — Crear switch virtual
# ============================================================
Write-Step "Configurando switch virtual de Hyper-V..."

try {
    Import-Module Hyper-V -ErrorAction Stop

    if (Get-VMSwitch -Name $CONFIG.SwitchName -ErrorAction SilentlyContinue) {
        Write-OK "Switch '$($CONFIG.SwitchName)' ya existe."
    } else {
        New-VMSwitch -Name $CONFIG.SwitchName -SwitchType Internal | Out-Null
        Write-OK "Switch interno '$($CONFIG.SwitchName)' creado."

        $adapter = Get-NetAdapter | Where-Object { $_.Name -like "*$($CONFIG.SwitchName)*" }
        if ($adapter) {
            New-NetIPAddress -InterfaceAlias $adapter.Name `
                -IPAddress $CONFIG.HostIP -PrefixLength $CONFIG.SubnetPrefix | Out-Null
            Write-OK "IP del host en red lab: $($CONFIG.HostIP)/$($CONFIG.SubnetPrefix)"
        }
    }
} catch {
    if ($needsReboot) {
        Write-Warn "Modulo Hyper-V no disponible hasta reiniciar. El switch se creara tras reinicio."

        $script = @"
Import-Module Hyper-V
if (-not (Get-VMSwitch -Name '$($CONFIG.SwitchName)' -ErrorAction SilentlyContinue)) {
    New-VMSwitch -Name '$($CONFIG.SwitchName)' -SwitchType Internal
    `$a = Get-NetAdapter | Where-Object { `$_.Name -like '*$($CONFIG.SwitchName)*' }
    if (`$a) { New-NetIPAddress -InterfaceAlias `$a.Name -IPAddress '$($CONFIG.HostIP)' -PrefixLength $($CONFIG.SubnetPrefix) }
}
Unregister-ScheduledTask -TaskName 'EVE-NG-CreateSwitch' -Confirm:`$false
"@
        $scriptPath = "$($CONFIG.VMBasePath)\post-reboot-switch.ps1"
        $script | Out-File $scriptPath -Encoding UTF8

        $action  = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -File `"$scriptPath`""
        $trigger = New-ScheduledTaskTrigger -AtStartup
        Register-ScheduledTask -TaskName "EVE-NG-CreateSwitch" -Action $action `
            -Trigger $trigger -RunLevel Highest -User "SYSTEM" -Force | Out-Null
        Write-OK "Tarea programada registrada para post-reinicio."
    } else {
        Write-Fail "No se pudo cargar el modulo Hyper-V: $_"
    }
}

# ============================================================
#  PASO 6 — Descargar ISO EVE-NG
# ============================================================
Write-Step "ISO de EVE-NG Community..."
if (Test-Path $CONFIG.ISOPath) {
    $size = [math]::Round((Get-Item $CONFIG.ISOPath).Length / 1MB)
    Write-OK "ISO ya presente ($size MB)."
} else {
    Write-Warn "ISO no encontrada en: $($CONFIG.ISOPath)"
    if (Confirm-Step "Descargar ahora? (~4 GB)") {
        try {
            Start-BitsTransfer -Source $CONFIG.ISOUrl -Destination $CONFIG.ISOPath `
                -Description "EVE-NG Community 6.2.0" -DisplayName "EVE-NG Lab"
            Write-OK "ISO descargada."
        } catch {
            Write-Fail "Error de descarga: $_"
            Write-Warn "Descarga manual: $($CONFIG.ISOUrl)"
            Write-Warn "Destino: $($CONFIG.ISOPath)"
        }
    } else {
        Write-Warn "Recuerda descargar la ISO antes de ejecutar el Bloque 2."
    }
}

# ============================================================
#  PASO 7 — Registrar URL en HTTP.sys para peticiones externas
# ============================================================
Write-Step "Registrando URL en HTTP.sys (acceso externo al listener)..."

$urlacl = netsh http show urlacl url="http://+:$($CONFIG.ListenerPort)/" 2>&1
if ($urlacl -match "Reserved URL") {
    Write-OK "URL ya registrada en HTTP.sys."
} else {
    try {
        $result = netsh http add urlacl url="http://+:$($CONFIG.ListenerPort)/" user="Todos" 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-OK "URL registrada: http://+:$($CONFIG.ListenerPort)/ para usuario 'Todos'."
        } else {
            # Intentar con "Everyone" por si el SO esta en ingles
            $result = netsh http add urlacl url="http://+:$($CONFIG.ListenerPort)/" user="Everyone" 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-OK "URL registrada: http://+:$($CONFIG.ListenerPort)/ para usuario 'Everyone'."
            } else {
                Write-Fail "No se pudo registrar la URL en HTTP.sys: $result"
            }
        }
    } catch {
        Write-Fail "Error al ejecutar netsh: $_"
    }
}

# ============================================================
#  PASO 8 — Regla de firewall para el listener
# ============================================================
Write-Step "Configurando firewall de Windows..."
$ruleName = "EVE-NG Lab Listener"
if (-not (Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName $ruleName -Direction Inbound `
        -Protocol TCP -LocalPort $CONFIG.ListenerPort `
        -Action Allow -Profile Domain,Private | Out-Null
    Write-OK "Puerto TCP $($CONFIG.ListenerPort) abierto."
} else {
    Write-OK "Regla de firewall ya existe."
}

# ============================================================
#  PASO 9 — Guardar configuracion para Bloque 2
# ============================================================
Write-Step "Guardando configuracion..."
$configPath = "$($CONFIG.VMBasePath)\lab-config.json"
@{
    SwitchName    = $CONFIG.SwitchName
    VMBasePath    = $CONFIG.VMBasePath
    ISOPath       = $CONFIG.ISOPath
    HostIP        = $CONFIG.HostIP
    VMSubnet      = $CONFIG.VMSubnet
    ListenerPort  = $CONFIG.ListenerPort
    VMDefaultRAM  = $CONFIG.VMDefaultRAM
    VMDefaultCPU  = $CONFIG.VMDefaultCPU
    VMDefaultDisk = $CONFIG.VMDefaultDisk
    SetupDate     = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    Hostname      = $env:COMPUTERNAME
} | ConvertTo-Json | Out-File $configPath -Encoding UTF8
Write-OK "Configuracion guardada en: $configPath"

# ============================================================
#  RESUMEN
# ============================================================
Write-Host "`n══════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  RESUMEN" -ForegroundColor Cyan
Write-Host "══════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Host        : $env:COMPUTERNAME"
Write-Host "  Switch      : $($CONFIG.SwitchName)"
Write-Host "  IP host     : $($CONFIG.HostIP)/$($CONFIG.SubnetPrefix)"
Write-Host "  Red VMs     : $($CONFIG.VMSubnet)"
Write-Host "  Puerto      : $($CONFIG.ListenerPort)"
Write-Host "  URL HTTP.sys: http://+:$($CONFIG.ListenerPort)/"
Write-Host "  Config JSON : $configPath"
Write-Host "══════════════════════════════════════════════" -ForegroundColor Cyan

if ($needsReboot) {
    Write-Host "`n  !! REINICIO NECESARIO !!" -ForegroundColor Yellow
    Write-Host "  Tras reiniciar, ejecuta este script de nuevo para verificar." -ForegroundColor Yellow
    if (Confirm-Step "Reiniciar ahora?") { Restart-Computer -Force }
} else {
    Write-Host ""
    Write-OK "Todo listo. Continua con el Bloque 2: listener.ps1"
}