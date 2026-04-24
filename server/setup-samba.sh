#!/bin/bash
# ============================================================
#  setup-samba.sh — Configuracion inicial del servidor Ubuntu
#  Ejecutar UNA sola vez como root tras instalar Ubuntu Server
#
#  Uso: sudo ./setup-samba.sh
# ============================================================

set -euo pipefail

# ── Cargar configuracion ─────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/server.conf"

# ── Colores ──────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'

log_step() { echo -e "\n${CYAN}[*] $1${NC}"; }
log_ok()   { echo -e "${GREEN}    [OK] $1${NC}"; }
log_warn() { echo -e "${YELLOW}    [!!] $1${NC}"; }
log_fail() { echo -e "${RED}    [ERROR] $1${NC}"; exit 1; }

# ── Banner ───────────────────────────────────────────────────
clear
echo -e "${CYAN}"
echo "╔══════════════════════════════════════════════╗"
echo "║   EVE-NG Lab — Setup Ubuntu Server          ║"
echo "╚══════════════════════════════════════════════╝"
echo -e "${NC}"

# ── Paso 1: Verificar root ───────────────────────────────────
log_step "Verificando permisos..."
[[ $EUID -ne 0 ]] && log_fail "Ejecuta como root: sudo ./setup-samba.sh"
log_ok "Corriendo como root."

# ── Paso 2: Actualizar e instalar dependencias ───────────────
log_step "Instalando dependencias..."
apt-get update -qq
apt-get install -y -qq samba samba-common-bin netcat-openbsd jq curl
log_ok "Dependencias instaladas."

# ── Paso 3: Crear estructura de directorios ──────────────────
log_step "Creando estructura de directorios..."
for dir in "$BASE_DIR" "$SHARES_DIR" "$TEMPLATE_DIR" "$LOGS_DIR"; do
    if [[ ! -d "$dir" ]]; then
        mkdir -p "$dir"
        log_ok "Creado: $dir"
    else
        log_ok "Ya existe: $dir"
    fi
done

# ── Paso 4: Crear credentials.json protegido ─────────────────
log_step "Creando fichero de credenciales..."
if [[ ! -f "$CREDENTIALS_FILE" ]]; then
    echo "[]" > "$CREDENTIALS_FILE"
    chmod 600 "$CREDENTIALS_FILE"
    chown root:root "$CREDENTIALS_FILE"
    log_ok "Creado: $CREDENTIALS_FILE (solo root)"
else
    log_ok "Ya existe: $CREDENTIALS_FILE"
fi

# ── Paso 5: Verificar plantilla ──────────────────────────────
log_step "Verificando plantilla de VM..."
if [[ ! -f "$TEMPLATE_DIR/$TEMPLATE_VHDX" ]]; then
    log_warn "Plantilla .vhdx no encontrada en: $TEMPLATE_DIR/$TEMPLATE_VHDX"
    log_warn "Copia manualmente el fichero antes de crear VMs de alumnos."
else
    log_ok "Plantilla .vhdx encontrada."
fi

if [[ ! -f "$TEMPLATE_DIR/$TEMPLATE_ISO" ]]; then
    log_warn "ISO EVE-NG no encontrada en: $TEMPLATE_DIR/$TEMPLATE_ISO"
    log_warn "Copia manualmente la ISO antes de crear VMs de alumnos."
else
    log_ok "ISO EVE-NG encontrada."
fi

# ── Paso 6: Configurar Samba ─────────────────────────────────
log_step "Configurando Samba..."

# Backup de la config original
if [[ ! -f /etc/samba/smb.conf.bak ]]; then
    cp /etc/samba/smb.conf /etc/samba/smb.conf.bak
    log_ok "Backup de smb.conf guardado."
fi

# Escribir configuracion global de Samba
cat > /etc/samba/smb.conf << EOF
[global]
    workgroup = ${SAMBA_WORKGROUP}
    server string = EVE-NG Lab Server
    security = user
    map to guest = never
    log file = /var/log/samba/log.%m
    max log size = 50
    logging = file
    panic action = /usr/share/samba/panic-action %d
    server role = standalone server
    obey pam restrictions = yes
    unix password sync = yes
    passwd program = /usr/bin/passwd %u
    passwd chat = *Enter\snew\s*\spassword:* %n\n *Retype\snew\s*\spassword:* %n\n *password\supdated\ssuccessfully* .
    pam password change = yes
    usershare allow guests = no

# Las shares de los alumnos se incluyen desde un fichero separado
# Se genera automaticamente por listener.sh
include = /etc/samba/shares.conf
EOF

# Crear fichero de shares vacio si no existe
if [[ ! -f /etc/samba/shares.conf ]]; then
    echo "# Shares de alumnos — generado automaticamente por listener.sh" \
        > /etc/samba/shares.conf
    log_ok "Creado: /etc/samba/shares.conf"
fi

# Verificar configuracion
testparm -s &>/dev/null && log_ok "Configuracion Samba valida." \
    || log_warn "Advertencia en la configuracion de Samba."

# ── Paso 7: Habilitar y arrancar Samba ──────────────────────
log_step "Habilitando servicios Samba..."
systemctl enable smbd nmbd
systemctl restart smbd nmbd
log_ok "Samba activo."

# ── Paso 8: Firewall ─────────────────────────────────────────
log_step "Configurando firewall..."
if command -v ufw &>/dev/null; then
    ufw allow samba
    ufw allow "$LISTENER_PORT/tcp" comment "EVE-NG listener"
    log_ok "Reglas UFW añadidas."
else
    log_warn "UFW no disponible. Configura el firewall manualmente."
fi

# ── Paso 9: Instalar listener como servicio systemd ──────────
log_step "Instalando listener como servicio systemd..."

cat > /etc/systemd/system/eveng-listener.service << EOF
[Unit]
Description=EVE-NG Lab Listener
After=network.target smbd.service

[Service]
Type=simple
ExecStart=/bin/bash ${SCRIPT_DIR}/listener.sh
Restart=always
RestartSec=5
StandardOutput=append:${LOGS_DIR}/listener.log
StandardError=append:${LOGS_DIR}/listener.log

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable eveng-listener
log_ok "Servicio eveng-listener registrado."
log_warn "Arrancalo con: systemctl start eveng-listener"

# ── Resumen ──────────────────────────────────────────────────
echo ""
echo -e "${CYAN}══════════════════════════════════════════════${NC}"
echo -e "${CYAN}  SETUP COMPLETADO${NC}"
echo -e "${CYAN}══════════════════════════════════════════════${NC}"
echo "  IP servidor    : $SERVER_IP"
echo "  Puerto listener: $LISTENER_PORT"
echo "  Shares dir     : $SHARES_DIR"
echo "  Plantilla dir  : $TEMPLATE_DIR"
echo "  Credenciales   : $CREDENTIALS_FILE"
echo -e "${CYAN}══════════════════════════════════════════════${NC}"
echo ""
echo -e "${YELLOW}  Proximos pasos:${NC}"
echo "  1. Copia eve-ng-base.vhdx a $TEMPLATE_DIR/"
echo "  2. Copia eve-ce-6.2.0-4-full.iso a $TEMPLATE_DIR/"
echo "  3. systemctl start eveng-listener"
echo ""