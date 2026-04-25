#!/bin/bash
# ============================================================
#  handler.sh — Manejador de peticiones HTTP
#  Llamado por socat por cada conexion entrante
#  NO ejecutar directamente
# ============================================================

# Cargar configuracion
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/server.conf"

# Log
log() {
    local level="$1"; shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*" >> "$LOGS_DIR/listener.log"
}

# Respuesta HTTP
send_response() {
    local status="$1"
    local body="$2"
    local len=${#body}
    printf "HTTP/1.1 %s\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s" \
        "$status" "$len" "$body"
}

# Crear carpeta SMB
create_vm() {
    local folder="$1" vmname="$2" username="$3" password="$4"
    local share_path="$SHARES_DIR/$folder"

    if [[ -d "$share_path" ]]; then
        echo '{"error":"La carpeta ya existe"}'; return 1
    fi
    if id "$username" &>/dev/null; then
        echo '{"error":"El usuario ya existe"}'; return 1
    fi
    if [[ ! -f "$TEMPLATE_DIR/$TEMPLATE_ISO" ]]; then
        echo '{"error":"ISO no encontrada en el servidor"}'; return 1
    fi

    useradd -M -s /usr/sbin/nologin "$username" 2>/dev/null || {
        echo '{"error":"Error creando usuario"}'; return 1
    }

    printf "%s\n%s\n" "$password" "$password" | smbpasswd -a -s "$username" 2>/dev/null || {
        userdel "$username" 2>/dev/null
        echo '{"error":"Error configurando contrasena Samba"}'; return 1
    }

    mkdir -p "$share_path"
    chown "$username":root "$share_path"
    chmod 700 "$share_path"

    cp "$TEMPLATE_DIR/$TEMPLATE_ISO" "$share_path/$TEMPLATE_ISO" || {
        rm -rf "$share_path"; userdel "$username" 2>/dev/null
        echo '{"error":"Error copiando ISO"}'; return 1
    }

    cat > "$share_path/vm-info.txt" << EOF
folder=$folder
vmname=$vmname
username=$username
created=$(date '+%Y-%m-%d %H:%M:%S')
EOF

    chown -R "$username":root "$share_path"
    chmod 600 "$share_path/$TEMPLATE_ISO" "$share_path/vm-info.txt"

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

    local created_at
    created_at=$(date '+%Y-%m-%d %H:%M:%S')
    local tmp
    tmp=$(mktemp)
    jq --argjson e "$(jq -n \
        --arg f "$folder" --arg v "$vmname" --arg u "$username" \
        --arg p "$password" --arg s "\\\\$SERVER_IP\\$folder" \
        --arg c "$created_at" \
        '{folder:$f,vmname:$v,username:$u,password:$p,share:$s,created:$c}')" \
        '. += [$e]' "$CREDENTIALS_FILE" > "$tmp"
    mv "$tmp" "$CREDENTIALS_FILE"
    chmod 600 "$CREDENTIALS_FILE"

    log "OK" "Carpeta $folder creada para $username"

    jq -n \
        --arg f "$folder" --arg v "$vmname" --arg u "$username" \
        --arg p "$password" --arg s "\\\\$SERVER_IP\\$folder" \
        --arg i "$TEMPLATE_ISO" \
        '{folder:$f,vmname:$v,username:$u,password:$p,share:$s,iso:$i,status:"ready",
          message:"Ejecuta sync.ps1 -mode pull en tu PC"}'
}

# Leer request
request=""; body=""; method=""; path=""; content_length=0

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

if [[ "$content_length" -gt 0 ]]; then
    read -r -t 10 -n "$content_length" body || true
fi

log "INFO" "$method $path"

# Routing
case "$method $path" in
    "GET /health")
        send_response "200 OK" '{"status":"ok"}'
        ;;
    "GET /status")
        result=$(jq '[.[] | {folder,vmname,username,share,created}]' \
            "$CREDENTIALS_FILE" 2>/dev/null || echo "[]")
        send_response "200 OK" "$result"
        ;;
    "POST /create-vm")
        if [[ -z "$body" ]]; then
            send_response "400 Bad Request" '{"error":"Body vacio"}'
        else
            folder=$(echo "$body"   | jq -r '.folder   // empty' 2>/dev/null)
            vmname=$(echo "$body"   | jq -r '.vmname   // empty' 2>/dev/null)
            username=$(echo "$body" | jq -r '.username // empty' 2>/dev/null)
            password=$(echo "$body" | jq -r '.password // empty' 2>/dev/null)

            if [[ -z "$folder" || -z "$vmname" || -z "$username" || -z "$password" ]]; then
                send_response "400 Bad Request" \
                    '{"error":"Campos requeridos: folder, vmname, username, password"}'
            elif ! [[ "$folder" =~ ^[a-zA-Z0-9\-]+$ && \
                      "$vmname" =~ ^[a-zA-Z0-9\-]+$ && \
                      "$username" =~ ^[a-zA-Z0-9\-]+$ ]]; then
                send_response "400 Bad Request" \
                    '{"error":"Formato invalido. Solo letras, numeros y guiones."}'
            else
                if result=$(create_vm "$folder" "$vmname" "$username" "$password" 2>&1); then
                    send_response "201 Created" "$result"
                else
                    send_response "409 Conflict" "$result"
                fi
            fi
        fi
        ;;
    *)
        send_response "404 Not Found" '{"error":"Endpoint no encontrado"}'
        ;;
esac