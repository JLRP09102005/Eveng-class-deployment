#!/bin/bash
# ============================================================
#  listener.sh — Servidor HTTP EVE-NG Lab
#  Arranca socat que llama a handler.sh por cada conexion
# ============================================================

set -uo pipefail

# Verificar root
if [[ $EUID -ne 0 ]]; then
    echo "[ERROR] Debe ejecutarse como root" >&2
    exit 1
fi

# Cargar configuracion
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -f "$SCRIPT_DIR/server.conf" ]]; then
    echo "[ERROR] No se encuentra server.conf" >&2
    exit 1
fi
source "$SCRIPT_DIR/server.conf"

mkdir -p "$LOGS_DIR"

# Verificar dependencias
for cmd in socat jq smbpasswd; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "[ERROR] $cmd no esta instalado" >&2
        exit 1
    fi
done

# Verificar handler
if [[ ! -f "$SCRIPT_DIR/handler.sh" ]]; then
    echo "[ERROR] No se encuentra handler.sh en $SCRIPT_DIR" >&2
    exit 1
fi
chmod +x "$SCRIPT_DIR/handler.sh"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] Listener iniciado en $SERVER_IP:$LISTENER_PORT" \
    | tee -a "$LOGS_DIR/listener.log"

# socat llama a handler.sh por cada conexion entrante
exec socat TCP-LISTEN:"$LISTENER_PORT",reuseaddr,fork \
    EXEC:"bash $SCRIPT_DIR/handler.sh" \
    2>>"$LOGS_DIR/listener.log"