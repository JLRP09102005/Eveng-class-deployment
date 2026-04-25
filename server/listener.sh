#!/bin/bash
# ============================================================
#  listener.sh — Servidor HTTP EVE-NG Lab
#  Corre permanentemente como servicio systemd
#
#  Endpoints:
#    POST /create-vm  {folder, vmname, username, password}
#    GET  /status     -> lista de shares activas (sin passwords)
#    GET  /health     -> ping
# ============================================================

set -uo pipefail

# ── Verificar root ───────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    echo "[ERROR] El listener debe ejecutarse como root (via systemd)" >&2
    exit 1
fi

# ── Cargar configuracion ─────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -f "$SCRIPT_DIR/server.conf" ]]; then
    echo "[ERROR] No se encuentra server.conf en $SCRIPT_DIR" >&2
    exit 1
fi
source "$SCRIPT_DIR/server.conf"

# ── Crear logs dir si no existe ──────────────────────────────
mkdir -p "$LOGS_DIR"

# ── Verificar socat ──────────────────────────────────────────
if ! command -v socat &>/dev/null; then
    echo "[ERROR] socat no esta instalado. Ejecuta: apt-get install -y socat" >&2
    exit 1
fi

# ── Log ──────────────────────────────────────────────────────
log() {
    local level="$1"; shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*" \
        | tee -a "$LOGS_DIR/listener.log"
}

# ── Respuesta HTTP ───────────────────────────────────────────
send_response() {
    local status="$1"
    local body="$2"
    local len=${#body}
    printf "HTTP/1.1 %s\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s" \
        "$status" "$len" "$body"
}

# ── Crear carpeta SMB del alumno ─────────────────────────────
create_vm() {
    local folder="$1"
    local vmname="$2"
    local username="$3"
    local password="$4"

    local share_path="$SHARES_DIR/$folder"

    if [[ -d "$share_path" ]]; then
        echo '{"error":"La carpeta ya existe"}'
        return 1
    fi

    if id "$username" &>/dev/null; then
        echo '{"error":"El usuario ya existe en el sistema"}'
        return 1
    fi

    if [[ ! -f "$TEMPLATE_DIR/$TEMPLATE_ISO" ]]; then
        echo '{"error":"ISO de EVE-NG no encontrada en el servidor"}'
        return 1
    fi

    log "INFO" "Creando carpeta para $username (folder: $folder, vmname: $vmname)"

    # Crear usuario Linux sin shell (solo Samba)
    useradd -M -s /usr/sbin/nologin "$username" 2>/dev/null || {
        echo '{"error":"Error creando usuario del sistema"}'
        return 1
    }

    # Contrasena Samba
    printf "%s\n%s\n" "$password" "$password" | smbpasswd -a -s "$username" 2>/dev/null || {
        userdel "$username" 2>/dev/null
        echo '{"error":"Error configurando contrasena Samba"}'
        return 1
    }

    # Crear carpeta con permisos solo para ese usuario
    mkdir -p "$share_path"
    chown "$username":root "$share_path"
    chmod 700 "$share_path"

    # Copiar ISO
    log "INFO" "Copiando ISO -> $share_path/$TEMPLATE_ISO"
    cp "$TEMPLATE_DIR/$TEMPLATE_ISO" "$share_path/$TEMPLATE_ISO" || {
        log "ERROR" "Error copiando ISO"
        rm -rf "$share_path"
        userdel "$username" 2>/dev/null
        echo '{"error":"Error copiando ISO de EVE-NG"}'
        return 1
    }

    # Fichero info con datos de la VM
    cat > "$share_path/vm-info.txt" << EOF
folder=$folder
vmname=$vmname
username=$username
created=$(date '+%Y-%m-%d %H:%M:%S')
EOF

    chown -R "$username":root "$share_path"
    chmod 600 "$share_path/$TEMPLATE_ISO"
    chmod 600 "$share_path/vm-info.txt"

    # Añadir share a Samba
    cat >> /etc/samba/shares.conf << EOF

[$folder]
    path = $share_path
    valid users = $username
    read only = no
    browseable = no
    create mask = 0600
    directory mask = 0700
    force user = $username
EOF

    smbcontrol smbd reload-config 2>/dev/null || systemctl reload smbd

    # Guardar en credentials.json
    local created_at
    created_at=$(date '+%Y-%m-%d %H:%M:%S')
    local new_entry
    new_entry=$(jq -n \
        --arg folder "$folder" \
        --arg vmname "$vmname" \
        --arg username "$username" \
        --arg password "$password" \
        --arg share "\\\\$SERVER_IP\\$folder" \
        --arg created "$created_at" \
        '{folder:$folder,vmname:$vmname,username:$username,password:$password,share:$share,created:$created}')

    local tmp
    tmp=$(mktemp)
    jq --argjson entry "$new_entry" '. += [$entry]' "$CREDENTIALS_FILE" > "$tmp"
    mv "$tmp" "$CREDENTIALS_FILE"
    chmod 600 "$CREDENTIALS_FILE"

    log "OK" "Carpeta $folder creada para $username"

    jq -n \
        --arg folder "$folder" \
        --arg vmname "$vmname" \
        --arg username "$username" \
        --arg password "$password" \
        --arg share "\\\\$SERVER_IP\\$folder" \
        --arg iso "$TEMPLATE_ISO" \
        '{
            folder: $folder,
            vmname: $vmname,
            username: $username,
            password: $password,
            share: $share,
            iso: $iso,
            status: "ready",
            message: "Ejecuta sync.ps1 -mode pull en tu PC para descargar la carpeta"
        }'
}

# ── GET /status ───────────────────────────────────────────────
get_status() {
    jq '[.[] | {folder,vmname,username,share,created}]' \
        "$CREDENTIALS_FILE" 2>/dev/null || echo "[]"
}

# ── Manejar peticion ─────────────────────────────────────────
handle_request() {
    local request=""
    local body=""
    local method=""
    local path=""
    local content_length=0

    # Leer cabeceras
    while IFS= read -r -t 10 line; do
        line="${line%$'\r'}"
        [[ -z "$line" ]] && break
        if [[ -z "$request" ]]; then
            request="$line"
            method="${line%% *}"
            path="${line#* }"; path="${path%% *}"
        fi
        if [[ "$line" =~ ^Content-Length:[[:space:]]([0-9]+) ]]; then
            content_length="${BASH_REMATCH[1]}"
        fi
    done

    # Leer body
    if [[ "$content_length" -gt 0 ]]; then
        read -r -t 10 -n "$content_length" body || true
    fi

    log "INFO" "$method $path"

    # GET /health
    if [[ "$method" == "GET" && "$path" == "/health" ]]; then
        send_response "200 OK" '{"status":"ok"}'
        return
    fi

    # GET /status
    if [[ "$method" == "GET" && "$path" == "/status" ]]; then
        send_response "200 OK" "$(get_status)"
        return
    fi

    # POST /create-vm
    if [[ "$method" == "POST" && "$path" == "/create-vm" ]]; then
        if [[ -z "$body" ]]; then
            send_response "400 Bad Request" '{"error":"Body vacio"}'
            return
        fi

        local folder vmname username password
        folder=$(echo "$body"   | jq -r '.folder   // empty' 2>/dev/null)
        vmname=$(echo "$body"   | jq -r '.vmname   // empty' 2>/dev/null)
        username=$(echo "$body" | jq -r '.username // empty' 2>/dev/null)
        password=$(echo "$body" | jq -r '.password // empty' 2>/dev/null)

        if [[ -z "$folder" || -z "$vmname" || -z "$username" || -z "$password" ]]; then
            send_response "400 Bad Request" \
                '{"error":"Campos requeridos: folder, vmname, username, password"}'
            return
        fi

        if ! [[ "$folder"   =~ ^[a-zA-Z0-9\-]+$ ]] || \
           ! [[ "$vmname"   =~ ^[a-zA-Z0-9\-]+$ ]] || \
           ! [[ "$username" =~ ^[a-zA-Z0-9\-]+$ ]]; then
            send_response "400 Bad Request" \
                '{"error":"Formato invalido. Solo letras, numeros y guiones."}'
            return
        fi

        local result
        if result=$(create_vm "$folder" "$vmname" "$username" "$password" 2>&1); then
            send_response "201 Created" "$result"
        else
            send_response "409 Conflict" "$result"
        fi
        return
    fi

    send_response "404 Not Found" '{"error":"Endpoint no encontrado"}'
}

# ── Bucle principal con socat ────────────────────────────────
log "INFO" "========================================"
log "INFO" "Listener iniciado en $SERVER_IP:$LISTENER_PORT"
log "INFO" "POST /create-vm  {folder,vmname,username,password}"
log "INFO" "GET  /status"
log "INFO" "GET  /health"
log "INFO" "========================================"

# socat acepta conexiones TCP y llama a handle_request por cada una
# SYSTEM ejecuta la funcion exportada como subshell
export -f handle_request send_response create_vm get_status log
export LOGS_DIR SHARES_DIR TEMPLATE_DIR TEMPLATE_ISO CREDENTIALS_FILE SERVER_IP

socat TCP-LISTEN:"$LISTENER_PORT",reuseaddr,fork \
    SYSTEM:"bash -c handle_request" 2>>"$LOGS_DIR/listener.log"