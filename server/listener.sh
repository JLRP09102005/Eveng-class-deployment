#!/bin/bash
# ============================================================
#  listener.sh — Servidor HTTP EVE-NG Lab
#  Corre permanentemente como servicio systemd
#
#  Endpoints:
#    POST /create-vm  {folder, vmname, username, password}
#    GET  /status     -> lista de shares activas
#    GET  /health     -> ping
# ============================================================

set -uo pipefail

# ── Cargar configuracion ─────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/server.conf"

# ── Log ──────────────────────────────────────────────────────
log() {
    local level="$1"; shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*" \
        | tee -a "$LOGS_DIR/listener.log"
}

# ── Respuesta HTTP ───────────────────────────────────────────
send_response() {
    local fd="$1"
    local status="$2"
    local body="$3"
    local len=${#body}
    printf "HTTP/1.1 %s\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s" \
        "$status" "$len" "$body" >&"$fd"
}

# ── Crear VM: copia plantilla y configura share ──────────────
create_vm() {
    local folder="$1"
    local vmname="$2"
    local username="$3"
    local password="$4"

    local share_path="$SHARES_DIR/$folder"

    # Validar que no existen ya
    if [[ -d "$share_path" ]]; then
        echo '{"error":"La carpeta ya existe"}'
        return 1
    fi

    if id "$username" &>/dev/null; then
        echo '{"error":"El usuario ya existe en el sistema"}'
        return 1
    fi

    # Comprobar que existe la plantilla
    if [[ ! -f "$TEMPLATE_DIR/$TEMPLATE_VHDX" ]]; then
        echo '{"error":"Plantilla .vhdx no encontrada en el servidor"}'
        return 1
    fi

    log "INFO" "Creando VM para $username (folder: $folder, vmname: $vmname)"

    # Crear usuario de sistema Linux (sin shell, solo para Samba)
    useradd -M -s /usr/sbin/nologin "$username" 2>/dev/null || {
        echo '{"error":"Error creando usuario del sistema"}'
        return 1
    }

    # Establecer contrasena Samba para el usuario
    printf "%s\n%s\n" "$password" "$password" | smbpasswd -a -s "$username" 2>/dev/null || {
        userdel "$username" 2>/dev/null
        echo '{"error":"Error configurando contrasena Samba"}'
        return 1
    }

    # Crear carpeta de la share
    mkdir -p "$share_path"
    chown "$username":root "$share_path"
    chmod 700 "$share_path"

    # Copiar plantilla .vhdx con el nombre de la VM
    log "INFO" "Copiando plantilla .vhdx -> $share_path/$vmname.vhdx"
    cp "$TEMPLATE_DIR/$TEMPLATE_VHDX" "$share_path/$vmname.vhdx" || {
        log "ERROR" "Error copiando plantilla"
        rm -rf "$share_path"
        userdel "$username" 2>/dev/null
        echo '{"error":"Error copiando plantilla .vhdx"}'
        return 1
    }

    # Copiar ISO de EVE-NG
    log "INFO" "Copiando ISO -> $share_path/$TEMPLATE_ISO"
    cp "$TEMPLATE_DIR/$TEMPLATE_ISO" "$share_path/$TEMPLATE_ISO" || {
        log "WARN" "Error copiando ISO — continuando sin ella"
    }

    # Ajustar permisos de los ficheros
    chown -R "$username":root "$share_path"
    chmod 600 "$share_path/$vmname.vhdx"

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

    # Recargar Samba sin interrumpir conexiones activas
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
        --arg share "\\\\\\\\$SERVER_IP\\\\$folder" \
        --arg created "$created_at" \
        '{folder:$folder, vmname:$vmname, username:$username, password:$password, share:$share, created:$created}')

    local tmp
    tmp=$(mktemp)
    jq --argjson entry "$new_entry" '. += [$entry]' "$CREDENTIALS_FILE" > "$tmp"
    mv "$tmp" "$CREDENTIALS_FILE"
    chmod 600 "$CREDENTIALS_FILE"

    log "OK" "VM $vmname creada para $username en \\\\$SERVER_IP\\$folder"

    # Respuesta al cliente
    jq -n \
        --arg folder "$folder" \
        --arg vmname "$vmname" \
        --arg username "$username" \
        --arg password "$password" \
        --arg share "\\\\\\\\$SERVER_IP\\\\$folder" \
        --arg vhdx "$vmname.vhdx" \
        --arg iso "$TEMPLATE_ISO" \
        '{
            folder: $folder,
            vmname: $vmname,
            username: $username,
            password: $password,
            share: $share,
            vhdx: $vhdx,
            iso: $iso,
            status: "ready",
            message: "Ejecuta sync.ps1 -mode pull en tu PC para descargar la VM"
        }'
}

# ── GET /status ───────────────────────────────────────────────
get_status() {
    # Devolver lista de shares activas sin las contraseñas
    jq '[.[] | {folder, vmname, username, share, created}]' \
        "$CREDENTIALS_FILE" 2>/dev/null || echo "[]"
}

# ── Parsear request HTTP ──────────────────────────────────────
handle_request() {
    local fd="$1"
    local request=""
    local body=""
    local method=""
    local path=""
    local content_length=0

    # Leer cabeceras
    while IFS= read -r -t 10 line <&"$fd"; do
        line="${line%$'\r'}"
        [[ -z "$line" ]] && break
        if [[ -z "$request" ]]; then
            request="$line"
            method="${line%% *}"
            path="${line#* }"; path="${path%% *}"
        fi
        if [[ "$line" =~ ^Content-Length:\ ([0-9]+) ]]; then
            content_length="${BASH_REMATCH[1]}"
        fi
    done

    # Leer body si hay Content-Length
    if [[ "$content_length" -gt 0 ]]; then
        read -r -t 10 -n "$content_length" body <&"$fd" || true
    fi

    log "INFO" "$method $path"

    # ── GET /health ───────────────────────────────────────────
    if [[ "$method" == "GET" && "$path" == "/health" ]]; then
        send_response "$fd" "200 OK" '{"status":"ok"}'
        return
    fi

    # ── GET /status ───────────────────────────────────────────
    if [[ "$method" == "GET" && "$path" == "/status" ]]; then
        local status_body
        status_body=$(get_status)
        send_response "$fd" "200 OK" "$status_body"
        return
    fi

    # ── POST /create-vm ───────────────────────────────────────
    if [[ "$method" == "POST" && "$path" == "/create-vm" ]]; then
        if [[ -z "$body" ]]; then
            send_response "$fd" "400 Bad Request" '{"error":"Body vacio"}'
            return
        fi

        # Extraer campos del JSON
        local folder vmname username password
        folder=$(echo "$body"   | jq -r '.folder   // empty' 2>/dev/null)
        vmname=$(echo "$body"   | jq -r '.vmname   // empty' 2>/dev/null)
        username=$(echo "$body" | jq -r '.username // empty' 2>/dev/null)
        password=$(echo "$body" | jq -r '.password // empty' 2>/dev/null)

        # Validar campos obligatorios
        if [[ -z "$folder" || -z "$vmname" || -z "$username" || -z "$password" ]]; then
            send_response "$fd" "400 Bad Request" \
                '{"error":"Campos requeridos: folder, vmname, username, password"}'
            return
        fi

        # Validar formato (solo letras, numeros y guion)
        if ! [[ "$folder"   =~ ^[a-zA-Z0-9\-]+$ ]] || \
           ! [[ "$vmname"   =~ ^[a-zA-Z0-9\-]+$ ]] || \
           ! [[ "$username" =~ ^[a-zA-Z0-9\-]+$ ]]; then
            send_response "$fd" "400 Bad Request" \
                '{"error":"Formato invalido. Solo letras, numeros y guiones."}'
            return
        fi

        # Crear VM
        local result
        if result=$(create_vm "$folder" "$vmname" "$username" "$password"); then
            send_response "$fd" "201 Created" "$result"
        else
            send_response "$fd" "409 Conflict" "$result"
        fi
        return
    fi

    # ── 404 ──────────────────────────────────────────────────
    send_response "$fd" "404 Not Found" '{"error":"Endpoint no encontrado"}'
}

# ── Bucle principal ───────────────────────────────────────────
log "INFO" "Listener iniciado en $SERVER_IP:$LISTENER_PORT"
log "INFO" "POST /create-vm  {folder, vmname, username, password}"
log "INFO" "GET  /status"
log "INFO" "GET  /health"

while true; do
    # Aceptar conexion TCP con netcat
    # -l escucha, -q1 cierra tras 1s sin datos, -p puerto
    nc -l -q 1 -p "$LISTENER_PORT" -e /dev/null 2>/dev/null &

    # Usar coproc para manejar la conexion
    coproc NC { nc -l -p "$LISTENER_PORT" 2>/dev/null; }

    handle_request "${NC[0]}" <&"${NC[0]}" >&"${NC[1]}" 2>/dev/null || true

    # Cerrar coproc
    exec {NC[0]}>&- {NC[1]}>&- 2>/dev/null || true
    wait "$NC_PID" 2>/dev/null || true
done