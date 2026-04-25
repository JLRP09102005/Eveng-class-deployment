#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Sync — Sincronizacion de VM con el servidor Ubuntu
.DESCRIPTION
    Pull: descarga la VM del servidor al PC local (inicio de clase)
    Push: sube los cambios al servidor (final de clase)
.PARAMETER mode
    pull o push
.NOTES
    Uso: .\sync.ps1 -mode pull
         .\sync.ps1 -mode push
    O usar los accesos directos del escritorio.
#>
param(
    [Parameter(Mandatory=$true)]
    [ValidateSet("pull","push")]
    [string]$mode
)

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
    $line | Out-File "C:\EVE-NG-Local\sync.log" -Append -Encoding UTF8
}

# ============================================================
#  MONTAR / DESMONTAR SHARE SMB
# ============================================================
$driveLetter = "Z"
$sharePath   = "\\$($CONFIG.ServerHost)\$($CONFIG.Folder)"

function Mount-Share {
    if (Test-Path "${driveLetter}:") {
        Write-Log "Unidad $driveLetter ya montada." "OK"
        return $true
    }
    Write-Log "Montando $sharePath como unidad ${driveLetter}:..."
    $secPassword = ConvertTo-SecureString $CONFIG.Password -AsPlainText -Force
    $credential  = New-Object System.Management.Automation.PSCredential(
        $CONFIG.Username, $secPassword
    )
    try {
        New-PSDrive -Name $driveLetter -PSProvider FileSystem `
            -Root $sharePath -Credential $credential -Persist -ErrorAction Stop | Out-Null
        Write-Log "Share montada en ${driveLetter}:" "OK"
        return $true
    } catch {
        $errMsg = $_.Exception.Message
        Write-Log "Error montando share: $errMsg" "ERROR"
        return $false
    }
}

function Dismount-Share {
    if (Test-Path "${driveLetter}:") {
        Remove-PSDrive -Name $driveLetter -Force -ErrorAction SilentlyContinue
        Write-Log "Share desmontada." "OK"
    }
}

# ============================================================
#  BANNER
# ============================================================
Clear-Host
$modeLabel = if ($mode -eq "pull") { "Inicio de clase — descargando VM" } `
             else { "Final de clase — subiendo cambios" }
Write-Host "╔══════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║   EVE-NG Lab — Sync: $($modeLabel.PadRight(22))║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""
Write-Log "Modo: $mode | Servidor: $($CONFIG.ServerHost) | Carpeta: $($CONFIG.Folder)" "INFO"

# ============================================================
#  PULL — Descargar VM del servidor
# ============================================================
if ($mode -eq "pull") {

    # Crear carpeta local si no existe
    if (-not (Test-Path $CONFIG.LocalPath)) {
        New-Item -ItemType Directory -Path $CONFIG.LocalPath -Force | Out-Null
        Write-Log "Carpeta local creada: $($CONFIG.LocalPath)" "OK"
    }

    # Montar share
    if (-not (Mount-Share)) {
        Read-Host "Error de conexion. Pulsa Enter para salir"
        exit 1
    }

    try {
        $remoteVhdx = "${driveLetter}:\$($CONFIG.VMName).vhdx"
        $remoteIso  = "${driveLetter}:\eve-ce-6.2.0-4-full.iso"
        $localVhdx  = "$($CONFIG.LocalPath)\$($CONFIG.VMName).vhdx"
        $localIso   = "$($CONFIG.LocalPath)\eve-ce-6.2.0-4-full.iso"

        # Copiar .vhdx
        if (Test-Path $remoteVhdx) {
            Write-Log "Descargando $($CONFIG.VMName).vhdx (puede tardar)..." "INFO"
            robocopy (Split-Path $remoteVhdx) $CONFIG.LocalPath `
                "$($CONFIG.VMName).vhdx" /J /NP /NFL /NDL | Out-Null
            Write-Log "VHDX descargado correctamente." "OK"
        } else {
            Write-Log "No se encontro el .vhdx en el servidor." "ERROR"
            Dismount-Share
            exit 1
        }

        # Copiar ISO si no esta ya en local
        if (-not (Test-Path $localIso) -and (Test-Path $remoteIso)) {
            Write-Log "Descargando ISO de EVE-NG (solo la primera vez)..." "INFO"
            robocopy (Split-Path $remoteIso) $CONFIG.LocalPath `
                "eve-ce-6.2.0-4-full.iso" /J /NP /NFL /NDL | Out-Null
            Write-Log "ISO descargada." "OK"
        } elseif (Test-Path $localIso) {
            Write-Log "ISO ya presente en local." "OK"
        }

    } finally {
        Dismount-Share
    }

    Write-Host ""
    Write-Host "══════════════════════════════════════════════" -ForegroundColor Green
    Write-Host "  VM descargada correctamente." -ForegroundColor Green
    Write-Host "  Ejecuta 'EVE-NG Importar VM' si es la primera vez." -ForegroundColor Green
    Write-Host "  O arranca directamente desde Hyper-V Manager." -ForegroundColor Green
    Write-Host "══════════════════════════════════════════════" -ForegroundColor Green
}

# ============================================================
#  PUSH — Subir cambios al servidor
# ============================================================
if ($mode -eq "push") {

    # Verificar que la VM esta apagada antes de subir
    try {
        Import-Module Hyper-V -ErrorAction Stop
        $vm = Get-VM -Name $CONFIG.VMName -ErrorAction SilentlyContinue
        if ($vm -and $vm.State -ne "Off") {
            Write-Log "La VM '$($CONFIG.VMName)' esta en estado '$($vm.State)'." "WARN"
            Write-Host ""
            Write-Host "  !! La VM debe estar apagada antes de subir cambios." -ForegroundColor Yellow
            Write-Host "     Apagala desde Hyper-V Manager y vuelve a ejecutar este script." -ForegroundColor Yellow
            Read-Host "`n  Pulsa Enter para salir"
            exit 1
        }
    } catch {
        Write-Log "No se pudo verificar estado de la VM. Continuando..." "WARN"
    }

    $localVhdx = "$($CONFIG.LocalPath)\$($CONFIG.VMName).vhdx"
    if (-not (Test-Path $localVhdx)) {
        Write-Log "No se encontro el .vhdx local: $localVhdx" "ERROR"
        Read-Host "Pulsa Enter para salir"
        exit 1
    }

    # Montar share
    if (-not (Mount-Share)) {
        Read-Host "Error de conexion. Pulsa Enter para salir"
        exit 1
    }

    try {
        Write-Log "Subiendo $($CONFIG.VMName).vhdx al servidor (puede tardar)..." "INFO"
        robocopy $CONFIG.LocalPath "${driveLetter}:\" `
            "$($CONFIG.VMName).vhdx" /J /NP /NFL /NDL | Out-Null
        Write-Log "Cambios subidos correctamente." "OK"
    } finally {
        Dismount-Share
    }

    Write-Host ""
    Write-Host "══════════════════════════════════════════════" -ForegroundColor Green
    Write-Host "  Cambios guardados en el servidor." -ForegroundColor Green
    Write-Host "  Tu progreso estara disponible la proxima sesion." -ForegroundColor Green
    Write-Host "══════════════════════════════════════════════" -ForegroundColor Green
}

Read-Host "`nPulsa Enter para cerrar"