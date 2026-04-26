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
#  CREDENCIALES SMB
# ============================================================
$secPassword = ConvertTo-SecureString $CONFIG.Password -AsPlainText -Force
$credential  = New-Object System.Management.Automation.PSCredential(
    $CONFIG.Username, $secPassword
)
$uncBase = "\\$($CONFIG.ServerHost)\$($CONFIG.Folder)"

# ============================================================
#  MONTAR / DESMONTAR SHARE
# ============================================================
$driveLetter = "Z"

function Mount-Share {
    # Desmontar si ya estaba montada
    if (Get-PSDrive -Name $driveLetter -ErrorAction SilentlyContinue) {
        Remove-PSDrive -Name $driveLetter -Force -ErrorAction SilentlyContinue
    }
    # Eliminar conexion previa si existe
    net use "${driveLetter}:" /delete /y 2>$null | Out-Null

    Write-Log "Montando $uncBase como unidad ${driveLetter}:..."
    try {
        # Usar net use que es mas fiable con robocopy
        $result = net use "${driveLetter}:" $uncBase /user:$($CONFIG.Username) $($CONFIG.Password) /persistent:no 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Log "Share montada en ${driveLetter}:" "OK"
            return $true
        } else {
            Write-Log "Error montando share: $result" "ERROR"
            return $false
        }
    } catch {
        $errMsg = $_.Exception.Message
        Write-Log "Error montando share: $errMsg" "ERROR"
        return $false
    }
}

function Dismount-Share {
    net use "${driveLetter}:" /delete /y 2>$null | Out-Null
    Write-Log "Share desmontada." "OK"
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
#  PULL — Descargar del servidor
# ============================================================
if ($mode -eq "pull") {

    if (-not (Test-Path $CONFIG.LocalPath)) {
        New-Item -ItemType Directory -Path $CONFIG.LocalPath -Force | Out-Null
        Write-Log "Carpeta local creada: $($CONFIG.LocalPath)" "OK"
    }

    if (-not (Mount-Share)) {
        Read-Host "Error de conexion. Pulsa Enter para salir"
        exit 1
    }

    try {
        $remoteVhdx = "${driveLetter}:\$($CONFIG.VMName).vhdx"
        $remoteIso  = "${driveLetter}:\eve-ce-6.2.0-4-full.iso"
        $localIso   = "$($CONFIG.LocalPath)\eve-ce-6.2.0-4-full.iso"

        # Descargar .vhdx si existe (sesiones posteriores a la primera)
        if (Test-Path $remoteVhdx) {
            Write-Log "Descargando $($CONFIG.VMName).vhdx (puede tardar)..." "INFO"
            robocopy "${driveLetter}:\" $CONFIG.LocalPath "$($CONFIG.VMName).vhdx" /J /NP /NFL /NDL
            Write-Log "VHDX descargado correctamente." "OK"
        } else {
            Write-Log "No hay .vhdx en el servidor — primera sesion." "WARN"
        }

        # Descargar ISO si no esta ya en local
        if (Test-Path $remoteIso) {
            if (-not (Test-Path $localIso)) {
                Write-Log "Descargando ISO de EVE-NG (solo la primera vez, puede tardar)..." "INFO"
                robocopy "${driveLetter}:\" $CONFIG.LocalPath "eve-ce-6.2.0-4-full.iso" /J /NP /NFL /NDL
                Write-Log "ISO descargada." "OK"
            } else {
                Write-Log "ISO ya presente en local." "OK"
            }
        } else {
            Write-Log "ISO no encontrada en el servidor." "WARN"
        }

    } finally {
        Dismount-Share
    }

    Write-Host ""
    Write-Host "══════════════════════════════════════════════" -ForegroundColor Green
    Write-Host "  Sincronizacion completada." -ForegroundColor Green
    if (-not (Test-Path "$($CONFIG.LocalPath)\$($CONFIG.VMName).vhdx")) {
        Write-Host "  Primera sesion: ejecuta 'EVE-NG Importar VM'." -ForegroundColor Yellow
    } else {
        Write-Host "  Arranca la VM desde Hyper-V Manager." -ForegroundColor Green
    }
    Write-Host "══════════════════════════════════════════════" -ForegroundColor Green
}

# ============================================================
#  PUSH — Subir cambios al servidor
# ============================================================
if ($mode -eq "push") {

    # Verificar que la VM esta apagada
    try {
        Import-Module Hyper-V -ErrorAction Stop
        $vm = Get-VM -Name $CONFIG.VMName -ErrorAction SilentlyContinue
        if ($vm -and $vm.State -ne "Off") {
            Write-Log "La VM '$($CONFIG.VMName)' esta en estado '$($vm.State)'." "WARN"
            Write-Host ""
            Write-Host "  !! Apaga la VM desde Hyper-V Manager antes de subir." -ForegroundColor Yellow
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

    if (-not (Mount-Share)) {
        Read-Host "Error de conexion. Pulsa Enter para salir"
        exit 1
    }

    try {
        Write-Log "Subiendo $($CONFIG.VMName).vhdx al servidor (puede tardar)..." "INFO"
        robocopy $CONFIG.LocalPath "${driveLetter}:\" "$($CONFIG.VMName).vhdx" /J /NP /NFL /NDL
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