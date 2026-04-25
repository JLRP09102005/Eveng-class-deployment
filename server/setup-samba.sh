#!/bin/bash
# ============================================================
#  setup-samba.sh — Configuracion inicial del servidor Ubuntu
#  Ejecutar UNA sola vez como root tras instalar Ubuntu Server
#
#  Uso: sudo ./setup-samba.sh
# ============================================================

set -euo pipefail

# ── Verificar root ───────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    echo -e "\033[0;31m[ERROR] Este script debe ejecutarse como root.\033[0m"
    echo -e "\033[1;33m        Usa: sudo ./setup-samba.sh\033[0m"
    exit 1
fi

# ── Cargar configuracion ─────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -f "$SCRIPT_DIR/server.conf" ]]; then
    echo -e "\033[0;31m[ERROR] No se encuentra server.conf en $SCRIPT_DIR\033[0m"
    exit 1
fi
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

# ── Paso 1: Actualizar e instalar dependencias ───────────────
log_step "Instalando dependencias..."
apt-get update -qq
apt-get install -y -qq samba samba-common-bin netcat-openbsd socat jq curl
log_ok "Dependencias instaladas."

# ── Paso 2: Crear estructura de directorios ──────────────────
log_step "Creando estructura de directorios..."
for dir in "$BASE_DIR" "$SHARES_DIR" "$TEMPLATE_DIR" "$LOGS_DIR"; do
    if [[ ! -d "$dir" ]]; then
        mkdir -p "$dir"
        chmod 755 "$dir"
        chown root:root "$dir"
        log_ok "Creado: $dir"
    else
        log_ok "Ya existe: $dir"
    fi
done

# ── Paso 3: Crear credentials.json protegido ─────────────────
log_step "Creando fichero de credenciales..."
if [[ ! -f "$CREDENTIALS_FILE" ]]; then
    echo "[]" > "$CREDENTIALS_FILE"
    chmod 600 "$CREDENTIALS_FILE"
    chown root:root "$CREDENTIALS_FILE"
    log_ok "Creado: $CREDENTIALS_FILE (solo root)"
else
    # Asegurar permisos aunque ya existiera
    chmod 600 "$CREDENTIALS_FILE"
    chown root:root "$CREDENTIALS_FILE"
    log_ok "Ya existe: $CREDENTIALS_FILE — permisos verificados."
fi

# ── Paso 4: Permisos del script listener ─────────────────────
log_step "Configurando permisos de los scripts..."
chmod +x "$SCRIPT_DIR/listener.sh"
chown root:root "$SCRIPT_DIR/listener.sh"
log_ok "listener.sh: ejecutable por root."

chmod 644 "$SCRIPT_DIR/server.conf"
chown root:root "$SCRIPT_DIR/server.conf"
log_ok "server.conf: permisos correctos."

# ── Paso 5: Verificar ISO ────────────────────────────────────
log_step "Verificando ISO de EVE-NG..."
if [[ ! -f "$TEMPLATE_DIR/$TEMPLATE_ISO" ]]; then
    log_warn "ISO no encontrada en: $TEMPLATE_DIR/$TEMPLATE_ISO"
    log_warn "Copia la ISO antes de crear VMs:"
    log_warn "  cp /ruta/a/$TEMPLATE_ISO $TEMPLATE_DIR/"
else
    chmod 644 "$TEMPLATE_DIR/$TEMPLATE_ISO"
    log_ok "ISO encontrada y permisos verificados."
fi

# ── Paso 6: Configurar Samba ─────────────────────────────────
log_step "Configurando Samba..."

# Backup de la config original
if [[ ! -f /etc/samba/smb.conf.bak ]]; then
    cp /etc/samba/smb.conf /etc/samba/smb.conf.bak
    log_ok "Backup guardado: /etc/samba/smb.conf.bak"
fi

cat > /etc/samba/smb.conf << EOF
[global]
    workgroup = ${SAMBA_WORKGROUP}
    server string = EVE-NG Lab Server
    security = user
    map to guest = never
    log file = /var/log/samba/log.%m
    max log size = 50
    logging = file
    server role = standalone server
    obey pam restrictions = yes
    unix password sync = yes
    passwd program = /usr/bin/passwd %u
    pam password change = yes
    usershare allow guests = no

# Shares de alumnos — generadas automaticamente por listener.sh
include = /etc/samba/shares.conf
EOF

# Crear shares.conf vacio si no existe
if [[ ! -f /etc/samba/shares.conf ]]; then
    echo "# Shares de alumnos — generado por listener.sh" \
        > /etc/samba/shares.conf
    chmod 644 /etc/samba/shares.conf
    log_ok "Creado: /etc/samba/shares.conf"
else
    log_ok "Ya existe: /etc/samba/shares.conf"
fi

testparm -s &>/dev/null \
    && log_ok "Configuracion Samba valida." \
    || log_warn "Advertencia en la configuracion de Samba — revisa con: testparm"

# ── Paso 7: Habilitar Samba ──────────────────────────────────
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
    log_warn "UFW no disponible — configura el firewall manualmente si es necesario."
fi

# ── Paso 9: Instalar servicio systemd ───────────────────────
log_step "Instalando servicio systemd del listener..."

cat > /etc/systemd/system/eveng-listener.service << EOF
[Unit]
Description=EVE-NG Lab Listener
After=network.target smbd.service
Requires=smbd.service

[Service]
Type=simple
User=root
ExecStart=/bin/bash ${SCRIPT_DIR}/listener.sh
Restart=always
RestartSec=5
StandardOutput=append:${LOGS_DIR}/listener.log
StandardError=append:${LOGS_DIR}/listener.log

[Install]
WantedBy=multi-user.target
EOF

chmod 644 /etc/systemd/system/eveng-listener.service
systemctl daemon-reload
systemctl enable eveng-listener
log_ok "Servicio eveng-listener instalado y habilitado."

# Intentar arrancarlo si la ISO ya esta presente
if [[ -f "$TEMPLATE_DIR/$TEMPLATE_ISO" ]]; then
    systemctl start eveng-listener \
        && log_ok "Listener arrancado correctamente." \
        || log_warn "No se pudo arrancar el listener — revisa: journalctl -u eveng-listener"
else
    log_warn "Listener NO arrancado — falta la ISO."
    log_warn "Una vez copies la ISO ejecuta: systemctl start eveng-listener"
fi

# ── Resumen ──────────────────────────────────────────────────
echo ""
echo -e "${CYAN}══════════════════════════════════════════════${NC}"
echo -e "${CYAN}  SETUP COMPLETADO${NC}"
echo -e "${CYAN}══════════════════════════════════════════════${NC}"
echo "  IP servidor    : $SERVER_IP"
echo "  Puerto listener: $LISTENER_PORT"
echo "  Shares dir     : $SHARES_DIR"
echo "  ISO dir        : $TEMPLATE_DIR"
echo "  Credenciales   : $CREDENTIALS_FILE (solo root)"
echo "  Service file   : /etc/systemd/system/eveng-listener.service"
echo -e "${CYAN}══════════════════════════════════════════════${NC}"
echo ""
if [[ ! -f "$TEMPLATE_DIR/$TEMPLATE_ISO" ]]; then
    echo -e "${YELLOW}  PENDIENTE:${NC}"
    echo "  1. Copia la ISO de EVE-NG:"
    echo "     cp /ruta/a/$TEMPLATE_ISO $TEMPLATE_DIR/"
    echo "  2. Arranca el listener:"
    echo "     systemctl start eveng-listener"
    echo ""
fi