<#
.SYNOPSIS
    Configura el equipo para que no se suspenda/hiberne automáticamente,
    hiberne a las 2AM, despierte a las 7AM y active Wake‑On‑LAN.
.DESCRIPTION
    - Desactiva los timeouts de suspensión e hibernación.
    - Crea tareas programadas para hibernar a las 2AM y despertar a las 7AM.
    - Habilita Wake‑On‑LAN en las tarjetas de red compatibles.
.NOTES
    Requiere ejecutarse como Administrador.
#>

#region [Verificar administrador]
if (-NOT ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Host "❌ Este script necesita permisos de administrador." -ForegroundColor Red
    Write-Host "   Vuelve a ejecutar PowerShell como Administrador." -ForegroundColor Yellow
    pause
    exit 1
}
#endregion

Write-Host "=== CONFIGURANDO GESTIÓN DE ENERGÍA ===" -ForegroundColor Cyan

#region [Desactivar suspensiones e hibernación automática]
Write-Host "`n📌 Desactivando timeouts automáticos..." -ForegroundColor Yellow
powercfg /change standby-timeout-ac 0      # Nunca suspender en AC
powercfg /change standby-timeout-dc 0      # Nunca suspender en batería
powercfg /change hibernate-timeout-ac 0    # Nunca hibernar por tiempo en AC
powercfg /change hibernate-timeout-dc 0    # Nunca hibernar por tiempo en batería
Write-Host "✅ Suspensión e hibernación automática desactivadas." -ForegroundColor Green
#endregion

#region [Activar hibernación como estado]
Write-Host "`n📌 Activando la función de hibernación (necesaria para hibernar a las 2AM)..." -ForegroundColor Yellow
powercfg -h on
if ($LASTEXITCODE -eq 0) {
    Write-Host "✅ Hibernación habilitada correctamente." -ForegroundColor Green
} else {
    Write-Host "⚠️  No se pudo activar la hibernación. Verifica que el disco tenga espacio suficiente." -ForegroundColor Red
}
#endregion

#region [Programar hibernación a las 2AM]
Write-Host "`n📌 Creando tarea programada: Hibernar a las 2:00 AM..." -ForegroundColor Yellow
$hibernateTask = "HibernateAt2AM"
$hibernateAction = "shutdown"
$hibernateArgs = "/h /f"   # /h = hibernar, /f = forzar cierre de aplicaciones
try {
    schtasks /create /tn $hibernateTask /tr "$hibernateAction $hibernateArgs" /sc daily /st 02:00 /ru system /f | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "✅ Tarea '$hibernateTask' creada. El equipo hibernará a las 2:00 AM." -ForegroundColor Green
    } else {
        throw "Error al crear la tarea de hibernación."
    }
} catch {
    Write-Host "⚠️  No se pudo crear la tarea de hibernación: $_" -ForegroundColor Red
}
#endregion

#region [Programar despertador a las 7AM]
Write-Host "`n📌 Creando tarea programada para despertar a las 7:00 AM..." -ForegroundColor Yellow
$wakeTask = "WakeAt7AM"
# Crear una tarea que ejecute un comando trivial y que pueda despertar el equipo
$action = New-ScheduledTaskAction -Execute "cmd.exe" -Argument "/c echo Equipo despertado a las 7AM >> %TEMP%\wake_log.txt"
$trigger = New-ScheduledTaskTrigger -Daily -At 07:00AM
$settings = New-ScheduledTaskSettingsSet -WakeToRun -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
try {
    Register-ScheduledTask -TaskName $wakeTask -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
    Write-Host "✅ Tarea '$wakeTask' creada. El equipo se despertará a las 7:00 AM (desde hibernación/suspensión)." -ForegroundColor Green
    Write-Host "   (Nota: El despertar desde hibernación depende del hardware. Si falla, revisa la BIOS/UEFI para habilitar 'Wake on RTC' o similar)" -ForegroundColor Yellow
} catch {
    Write-Host "⚠️  No se pudo crear la tarea de despertador: $_" -ForegroundColor Red
}
#endregion

#region [Comprobar y activar Wake‑On‑LAN]
Write-Host "`n📌 Comprobando adaptadores de red para Wake‑On‑LAN..." -ForegroundColor Yellow

# Obtener adaptadores de red Ethernet (cableados)
$adapters = Get-NetAdapter -Physical | Where-Object { $_.MediaType -eq "802.3" -and $_.Name -notlike "*Bluetooth*" -and $_.Name -notlike "*WiFi*" -and $_.Name -notlike "*Wireless*" }

if (-not $adapters) {
    Write-Host "⚠️  No se encontraron adaptadores Ethernet cableados. Wake‑On‑LAN no se puede configurar." -ForegroundColor Yellow
} else {
    foreach ($adapter in $adapters) {
        Write-Host "`n🔌 Adaptador: $($adapter.Name) (Interface $($adapter.InterfaceDescription))" -ForegroundColor Cyan
        # Verificar soporte de Wake‑On‑LAN mediante la propiedad 'WakeOnMagicPacket'
        $powerMgmt = Get-NetAdapterPowerManagement -Name $adapter.Name -ErrorAction SilentlyContinue
        if ($powerMgmt) {
            $wolSupported = $powerMgmt.WakeOnMagicPacketSupported
            $wolEnabled = $powerMgmt.WakeOnMagicPacket
            Write-Host "   Wake on Magic Packet soportado: $wolSupported" -ForegroundColor Gray
            if ($wolSupported) {
                # Activar Wake on Magic Packet
                Set-NetAdapterPowerManagement -Name $adapter.Name -WakeOnMagicPacket Enabled -ErrorAction SilentlyContinue
                if ($?) {
                    Write-Host "   ✅ Wake‑On‑LAN (Magic Packet) activado en este adaptador." -ForegroundColor Green
                } else {
                    Write-Host "   ❌ No se pudo activar Wake‑On‑LAN. Prueba a deshabilitar 'Inicio rápido' en el Panel de Control." -ForegroundColor Red
                }
                # También activar 'Wake on Pattern Match' (para responder a peticiones de red)
                Set-NetAdapterPowerManagement -Name $adapter.Name -WakeOnPattern Enabled -ErrorAction SilentlyContinue
            } else {
                Write-Host "   ❌ Este adaptador no soporta Wake‑On‑LAN. No se puede activar." -ForegroundColor Red
            }
        } else {
            Write-Host "   ❌ No se pudo obtener la información de administración de energía del adaptador." -ForegroundColor Red
        }
    }
}
#endregion

Write-Host "`n=== CONFIGURACIÓN COMPLETADA ===" -ForegroundColor Green
Write-Host "🔁 El equipo nunca se suspenderá ni hibernará automáticamente." -ForegroundColor White
Write-Host "⏰ Hibernará cada día a las 2:00 AM y despertará a las 7:00 AM." -ForegroundColor White
Write-Host "🌐 Wake‑On‑LAN activado en los adaptadores compatibles (para despertar remotamente)." -ForegroundColor White
Write-Host "`nRecomendación: Si el despertador automático no funciona, revisa la BIOS/UEFI y activa 'Resume by RTC Alarm' o similar." -ForegroundColor Yellow
pause