#Requires -RunAsAdministrator
<#
.SYNOPSIS
    PC Alumno — Configuracion inicial para EVE-NG Lab
.DESCRIPTION
    Ejecutar UNA sola vez en el PC del alumno como Administrador.
    Habilita Hyper-V, crea la carpeta local, guarda la configuracion
    y crea los accesos directos en el escritorio.
.NOTES
    Uso: PowerShell como Admin -> .\setup-client.ps1
#>

# ============================================================
#  LOG
# ============================================================
function Write-Step { param($msg) Write-Host "`n[*] $msg" -ForegroundColor Cyan }
function Write-OK   { param($msg) Write-Host "    [OK] $msg" -ForegroundColor Green }
function Write-Warn { param($msg) Write-Host "    [!!] $msg" -ForegroundColor Yellow }
function Write-Fail { param($msg) Write-Host "    [ERROR] $msg" -ForegroundColor Red }

# ============================================================
#  BANNER
# ============================================================
Clear-Host
Write-Host "╔══════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║   EVE-NG Lab — Setup PC Alumno              ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Cyan

# ============================================================
#  PASO 1 — Verificar SO compatible
# ============================================================
Write-Step "Verificando sistema operativo..."
$os = Get-CimInstance Win32_OperatingSystem
Write-Host "    SO: $($os.Caption) (Build $($os.BuildNumber))"

if ($os.BuildNumber -lt 19041) {
    Write-Fail "Se requiere Windows 10 build 19041 o superior."
    exit 1
}
if ($os.Caption -match "Home") {
    Write-Fail "Windows Home no soporta Hyper-V. Necesitas Pro o Education."
    exit 1
}
Write-OK "SO compatible."

# ============================================================
#  PASO 2 — Habilitar Hyper-V y Management Tools
# ============================================================
Write-Step "Comprobando Hyper-V..."
$feature = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All
if ($feature.State -eq "Enabled") {
    Write-OK "Hyper-V ya habilitado."
    $needsReboot = $false
} else {
    Write-Warn "Habilitando Hyper-V..."
    Enable-WindowsOptionalFeature -Online -FeatureName @(
        "Microsoft-Hyper-V-All",
        "Microsoft-Hyper-V",
        "Microsoft-Hyper-V-Tools-All",
        "Microsoft-Hyper-V-Management-PowerShell",
        "Microsoft-Hyper-V-Hypervisor"
    ) -All -NoRestart | Out-Null
    Write-OK "Hyper-V habilitado. Se necesita reinicio al finalizar."
    $needsReboot = $true
}

# ============================================================
#  PASO 3 — Cambiar perfil de red a Privado
# ============================================================
Write-Step "Configurando perfil de red..."
Get-NetConnectionProfile | ForEach-Object {
    if ($_.NetworkCategory -ne "Private") {
        Set-NetConnectionProfile -InterfaceIndex $_.InterfaceIndex -NetworkCategory Private
        Write-OK "Red '$($_.Name)' cambiada a Privada."
    } else {
        Write-OK "Red '$($_.Name)' ya es Privada."
    }
}

# ============================================================
#  PASO 4 — Recoger datos del alumno
# ============================================================
Write-Step "Configuracion del alumno..."
Write-Host ""
$serverHost = Read-Host "  IP del servidor Ubuntu (ej: 192.168.0.100)"
$folder     = Read-Host "  Nombre de tu carpeta SMB (el que usaste en curl)"
$vmname     = Read-Host "  Nombre de tu VM (el que usaste en curl)"
$username   = Read-Host "  Tu usuario Samba"
$password   = Read-Host "  Tu contrasena Samba"

$localPath  = "C:\EVE-NG-Local\$folder"
$switchName = "EVE-NG-Switch"

# ============================================================
#  PASO 5 — Crear carpeta local
# ============================================================
Write-Step "Creando carpeta local de trabajo..."
if (-not (Test-Path $localPath)) {
    New-Item -ItemType Directory -Path $localPath -Force | Out-Null
    Write-OK "Creada: $localPath"
} else {
    Write-OK "Ya existe: $localPath"
}

# ============================================================
#  PASO 6 — Guardar configuracion en client-config.json
# ============================================================
Write-Step "Guardando configuracion..."
$configPath = "C:\EVE-NG-Local\client-config.json"
@{
    ServerHost  = $serverHost
    Folder      = $folder
    VMName      = $vmname
    Username    = $username
    Password    = $password
    LocalPath   = $localPath
    SwitchName  = $switchName
    SetupDate   = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
} | ConvertTo-Json | Out-File $configPath -Encoding UTF8

# Proteger el fichero — solo el usuario actual puede leerlo
$acl = Get-Acl $configPath
$acl.SetAccessRuleProtection($true, $false)
$rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
    $env:USERNAME, "FullControl", "Allow"
)
$acl.AddAccessRule($rule)
Set-Acl $configPath $acl
Write-OK "Config guardada: $configPath"

# ============================================================
#  PASO 7 — Crear switch Hyper-V local en modo bridge
# ============================================================
Write-Step "Configurando switch Hyper-V local..."
try {
    Import-Module Hyper-V -ErrorAction Stop
    if (Get-VMSwitch -Name $switchName -ErrorAction SilentlyContinue) {
        Write-OK "Switch '$switchName' ya existe."
    } else {
        $ethAdapter = Get-NetAdapter -Physical | Where-Object {
            $_.Status -eq "Up" -and
            $_.MediaType -eq "802.3" -and
            $_.InterfaceDescription -notmatch "Wi-Fi|Wireless|WiFi|Bluetooth"
        } | Select-Object -First 1

        if ($ethAdapter) {
            New-VMSwitch -Name $switchName `
                -NetAdapterName $ethAdapter.Name `
                -AllowManagementOS $true | Out-Null
            Write-OK "Switch bridge '$switchName' creado."
        } else {
            Write-Warn "No se encontro Ethernet activo. El switch se creara al hacer import-vm.ps1."
        }
    }
} catch {
    if ($needsReboot) {
        Write-Warn "Switch se creara tras el reinicio."
    } else {
        $errMsg = $_.Exception.Message
        Write-Warn "No se pudo crear el switch: $errMsg"
    }
}

# ============================================================
#  PASO 8 — Crear accesos directos en el escritorio
# ============================================================
Write-Step "Creando accesos directos en el escritorio..."
$desktopPath = [Environment]::GetFolderPath("Desktop")
$scriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$wsh = New-Object -ComObject WScript.Shell

# Acceso directo: Inicio de clase (pull)
$shortcutPull = $wsh.CreateShortcut("$desktopPath\EVE-NG Inicio de clase.lnk")
$shortcutPull.TargetPath = "powershell.exe"
$shortcutPull.Arguments  = "-ExecutionPolicy Bypass -File `"$scriptDir\sync.ps1`" -mode pull"
$shortcutPull.WorkingDirectory = $scriptDir
$shortcutPull.Description = "Descargar VM de EVE-NG del servidor"
$shortcutPull.Save()
Write-OK "Acceso directo creado: EVE-NG Inicio de clase"

# Acceso directo: Final de clase (push)
$shortcutPush = $wsh.CreateShortcut("$desktopPath\EVE-NG Final de clase.lnk")
$shortcutPush.TargetPath = "powershell.exe"
$shortcutPush.Arguments  = "-ExecutionPolicy Bypass -File `"$scriptDir\sync.ps1`" -mode push"
$shortcutPush.WorkingDirectory = $scriptDir
$shortcutPush.Description = "Subir cambios de VM al servidor"
$shortcutPush.Save()
Write-OK "Acceso directo creado: EVE-NG Final de clase"

# Acceso directo: Importar VM
$shortcutImport = $wsh.CreateShortcut("$desktopPath\EVE-NG Importar VM.lnk")
$shortcutImport.TargetPath = "powershell.exe"
$shortcutImport.Arguments  = "-ExecutionPolicy Bypass -File `"$scriptDir\import-vm.ps1`""
$shortcutImport.WorkingDirectory = $scriptDir
$shortcutImport.Description = "Importar VM en Hyper-V local"
$shortcutImport.Save()
Write-OK "Acceso directo creado: EVE-NG Importar VM"

# ============================================================
#  RESUMEN
# ============================================================
Write-Host "`n══════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  RESUMEN" -ForegroundColor Cyan
Write-Host "══════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Servidor  : $serverHost"
Write-Host "  Carpeta   : $folder"
Write-Host "  VM        : $vmname"
Write-Host "  Usuario   : $username"
Write-Host "  Local     : $localPath"
Write-Host "  Config    : $configPath"
Write-Host "══════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Proximos pasos:" -ForegroundColor Yellow
Write-Host "  1. Si es la primera vez: doble clic en 'EVE-NG Inicio de clase'"
Write-Host "  2. Luego doble clic en 'EVE-NG Importar VM'"
Write-Host "  3. Arranca la VM desde Hyper-V Manager"
Write-Host ""

if ($needsReboot) {
    Write-Host "  !! REINICIO NECESARIO para activar Hyper-V !!" -ForegroundColor Yellow
    $r = Read-Host "`nReiniciar ahora? [s/N]"
    if ($r -eq 's' -or $r -eq 'S') { Restart-Computer -Force }
}