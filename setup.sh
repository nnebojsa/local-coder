#!/usr/bin/env bash
# Einrichtung von local-coder (llama-server + Open WebUI, rootless Podman).
#
# Ablauf:
#   1. setup.conf laden und alle Werte prüfen
#   2. Alle Voraussetzungen prüfen (System, RAM, CPU, Podman, Compose, Ports,
#      Speicherplatz, Netzwerk für fehlende Downloads). Bei einem Fehler
#      erfolgt der Abbruch, bevor etwas verändert wird.
#   3. Verzeichnisse, Sitzungsschlüssel und .env anlegen
#   4. Fehlende Modelle herunterladen (abgebrochene Downloads werden fortgesetzt)
#   5. llama-server-Image bauen, Open-WebUI-Image laden
#   6. Embedding-Modell aus dem Open-WebUI-Image übernehmen (Offline-Betrieb)
#   7. Container neu anlegen, starten und auf Bereitschaft warten
#
# Aufruf als normaler Benutzer im Projektverzeichnis:
#   ./setup.sh             einrichten bzw. geänderte setup.conf übernehmen
#   ./setup.sh --check     nur Voraussetzungen prüfen, nichts verändern
#   ./setup.sh --no-start  einrichten, Container nicht starten
#   ./setup.sh --update    zusätzlich neueste Images laden (Basis-Image, Open WebUI)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

CHECK_ONLY=0
NO_START=0
UPDATE=0

ERRORS=0
WARNINGS=0
PODMAN_OK=0
HAVE_SS=0
MEM_BYTES=0
CHAT_MODEL_BYTES=0
FIM_MODEL_BYTES=0
GRAPHROOT=""
DOWNLOADS=()
NEED_PULL_WEBUI=0
NEED_BASE_IMAGE=0
FRESH_WEBUI=1
REMOTE_SIZE=""
REMOTE_STATUS=""

usage() {
    cat <<EOF
Aufruf: $0 [--check] [--no-start] [--update]

  --check     nur Voraussetzungen und Konfiguration prüfen
  --no-start  einrichten, Container aber nicht starten
  --update    neueste Images laden (Open WebUI, llama.cpp-Basis-Image)
EOF
}

section() { printf '\n== %s ==\n' "$1"; }

check_err() {
    err "$1"
    shift
    local h
    for h in "$@"; do ehint "$h"; done
    ERRORS=$((ERRORS + 1))
}

check_warn() {
    warn "$1"
    shift
    local h
    for h in "$@"; do hint "$h"; done
    WARNINGS=$((WARNINGS + 1))
}

# ---------------------------------------------------------------------------
# Prüfung der Konfiguration
# ---------------------------------------------------------------------------

check_flag() {
    local name="$1" value="${!1}"
    case "$value" in
        0|1) ;;
        *)   check_err "$name muss 0 oder 1 sein (ist: '$value')" ;;
    esac
}

check_port() {
    local name="$1" value="${!1}"
    if ! is_uint "$value" || [ "$value" -lt 1024 ] || [ "$value" -gt 65535 ]; then
        check_err "$name muss zwischen 1024 und 65535 liegen (ist: '$value')" \
                  "Ports unter 1024 sind für rootless Podman nicht freigegeben"
    fi
}

check_uint_min() {
    local name="$1" min="$2" value="${!1}"
    if ! is_uint "$value" || [ "$value" -lt "$min" ]; then
        check_err "$name muss eine ganze Zahl ab $min sein (ist: '$value')"
    fi
}

check_gguf_name() {
    local name="$1" value="${!1}"
    if ! [[ "$value" =~ ^[A-Za-z0-9._+-]+\.gguf$ ]]; then
        check_err "$name muss ein Dateiname mit Endung .gguf sein, ohne Pfad (ist: '$value')"
    fi
}

check_repo() {
    local name="$1" value="${!1}"
    if ! [[ "$value" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
        check_err "$name muss die Form <besitzer>/<repo> haben (ist: '$value')"
    fi
}

# Zeichen, die in .env oder in Volume-Angaben Probleme verursachen
check_plain() {
    local name="$1" value="${!1}" extra="${2:-}"
    if [[ "$value" == *[\$\#\`\"\'\\]* ]]; then
        check_err "$name enthält unzulässige Zeichen (\$ # \` \" ' \\): '$value'"
    elif [ "$extra" = "path" ] && [[ "$value" == *:* ]]; then
        check_err "$name darf keinen Doppelpunkt enthalten: '$value'"
    fi
}

check_config() {
    section "Konfiguration ($CONF_FILE)"
    local before="$ERRORS"

    local f
    for f in WEBUI_AUTH WEBUI_OFFLINE WEBUI_TITLE_GENERATION WEBUI_BACKGROUND_TASKS \
             WEBUI_CONFIG_FROM_ENV CHAT_THINKING AUTOCOMPLETE; do
        check_flag "$f"
    done

    check_port WEBUI_PORT
    if [ "$AUTOCOMPLETE" = "1" ]; then
        check_port FIM_PORT
        if [ "$WEBUI_PORT" = "$FIM_PORT" ]; then
            check_err "WEBUI_PORT und FIM_PORT sind identisch ($WEBUI_PORT)"
        fi
    fi

    if ! [[ "$BIND_ADDRESS" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        check_err "BIND_ADDRESS muss eine IPv4-Adresse sein (ist: '$BIND_ADDRESS')"
    elif [ "$BIND_ADDRESS" != "127.0.0.1" ] && [ "$WEBUI_AUTH" != "1" ]; then
        check_err "BIND_ADDRESS=$BIND_ADDRESS ohne Anmeldung (WEBUI_AUTH=0) ist unzulässig" \
                  "Die Oberfläche wäre ohne Schutz im Netz erreichbar"
    fi

    check_uint_min CHAT_CTX 2048
    check_uint_min WEBUI_REQUEST_TIMEOUT 60
    check_uint_min FIM_THREADS 1
    check_uint_min MIN_RAM_GB 1
    check_uint_min MIN_IMAGE_SPACE_GB 1
    if [ "$CHAT_THREADS" != "auto" ]; then
        check_uint_min CHAT_THREADS 1
    fi

    case "$CHAT_SAMPLING" in
        qwen|default) ;;
        *) check_err "CHAT_SAMPLING muss qwen oder default sein (ist: '$CHAT_SAMPLING')" ;;
    esac

    check_repo CHAT_MODEL_REPO
    check_gguf_name CHAT_MODEL_FILE
    if [ "$AUTOCOMPLETE" = "1" ]; then
        check_repo FIM_MODEL_REPO
        check_gguf_name FIM_MODEL_FILE
    fi

    if ! [[ "$CHAT_ALIAS" =~ ^[A-Za-z0-9._:-]+$ ]]; then
        check_err "CHAT_ALIAS darf nur Buchstaben, Ziffern und . _ : - enthalten (ist: '$CHAT_ALIAS')"
    fi
    if [ -n "$WEBUI_LOCALE" ] && ! [[ "$WEBUI_LOCALE" =~ ^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,4})?$ ]]; then
        check_err "WEBUI_LOCALE hat kein gültiges Format, z.B. de-DE (ist: '$WEBUI_LOCALE')"
    fi
    case "$HF_ENDPOINT" in
        http://*|https://*) ;;
        *) check_err "HF_ENDPOINT muss mit http:// oder https:// beginnen (ist: '$HF_ENDPOINT')" ;;
    esac

    for f in WEBUI_IMAGE LLAMA_CPP_IMAGE LLM_IMAGE; do
        if [ -z "${!f}" ] || [[ "${!f}" == *[[:space:]]* ]]; then
            check_err "$f ist leer oder enthält Leerzeichen"
        fi
    done

    for f in MODELS_DIR WEBUI_DATA_DIR; do
        check_plain "$f" path
        if [ -z "${!f}" ] || [ "${!f}" = "/" ]; then
            check_err "$f ist leer oder /"
        fi
    done
    if [ "$MODELS_DIR" = "$WEBUI_DATA_DIR" ]; then
        check_err "MODELS_DIR und WEBUI_DATA_DIR dürfen nicht identisch sein"
    fi
    if [ "$WEBUI_DATA_DIR" = "$SCRIPT_DIR" ] || [ "$MODELS_DIR" = "$SCRIPT_DIR" ]; then
        check_err "MODELS_DIR bzw. WEBUI_DATA_DIR darf nicht das Projektverzeichnis selbst sein"
    fi
    for f in CHAT_EXTRA_ARGS FIM_EXTRA_ARGS WEBUI_LOCALE; do
        check_plain "$f"
    done

    if [ "$ERRORS" -eq "$before" ]; then
        ok "alle Werte gültig"
    fi
}

# ---------------------------------------------------------------------------
# Prüfung des Systems
# ---------------------------------------------------------------------------

check_system() {
    section "System"

    if [ "$(id -u)" -eq 0 ]; then
        check_err "Aufruf als root" "vorgesehen ist rootless Podman als normaler Benutzer"
    fi

    local os arch
    os="$(uname -s)"
    arch="$(uname -m)"
    if [ "$os" != "Linux" ]; then
        check_err "Betriebssystem $os wird nicht unterstützt, erforderlich: Linux"
    fi
    case "$arch" in
        x86_64|aarch64) ok "Architektur $arch" ;;
        *) check_err "Architektur $arch wird nicht unterstützt (x86_64, aarch64)" ;;
    esac

    local t missing=()
    for t in curl awk sed grep df du realpath od stat sort tail mktemp; do
        if ! command -v "$t" >/dev/null 2>&1; then
            missing+=("$t")
        fi
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        check_err "fehlende Werkzeuge: ${missing[*]}" \
                  "Abhilfe: sudo apt install curl coreutils gawk sed grep"
    else
        ok "Werkzeuge vorhanden (curl, awk, sed, coreutils)"
    fi
    if command -v ss >/dev/null 2>&1; then
        HAVE_SS=1
    else
        check_warn "ss nicht gefunden, die Prüfung der Ports entfällt" \
                   "Abhilfe: sudo apt install iproute2"
    fi

    # Arbeitsspeicher, 10 % Toleranz für reservierten Speicher (Firmware, iGPU)
    local mem_kib min_kib
    mem_kib="$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo)"
    MEM_BYTES=$((mem_kib * 1024))
    min_kib=$((MIN_RAM_GB * 1024 * 1024 * 90 / 100))
    if [ "$mem_kib" -lt "$min_kib" ]; then
        check_err "Arbeitsspeicher $(fmt_gb "$MEM_BYTES") GB, erforderlich sind mindestens $MIN_RAM_GB GB"
    else
        ok "Arbeitsspeicher $(fmt_gb "$MEM_BYTES") GB (Minimum $MIN_RAM_GB GB)"
    fi

    # CPU
    local cores
    cores="$(physical_cores)"
    if [ "$cores" -lt 4 ]; then
        check_warn "nur $cores physische CPU-Kerne, empfohlen sind mindestens 4"
    else
        ok "$cores physische CPU-Kerne"
    fi
    if [ "$arch" = "x86_64" ]; then
        if grep -qw avx2 /proc/cpuinfo; then
            ok "CPU unterstützt AVX2"
        else
            check_warn "CPU ohne AVX2, llama-server läuft damit deutlich langsamer"
        fi
    fi
}

check_podman() {
    section "Podman"

    if ! command -v podman >/dev/null 2>&1; then
        check_err "podman nicht gefunden" "Abhilfe: sudo apt install podman"
        return 0
    fi

    local pv major
    pv="$(podman version --format '{{.Client.Version}}' 2>/dev/null || true)"
    if [ -z "$pv" ]; then
        pv="$(podman --version 2>/dev/null | awk '{ print $NF }')"
    fi
    major="${pv%%.*}"
    if is_uint "$major" && [ "$major" -ge 4 ]; then
        ok "podman $pv"
    else
        check_err "podman $pv ist zu alt, erforderlich ist mindestens 4.0"
    fi

    if ! podman info >/dev/null 2>&1; then
        check_err "podman info schlägt fehl, Podman ist nicht funktionsfähig eingerichtet" \
                  "Details: podman info"
        return 0
    fi
    PODMAN_OK=1

    local user uid
    user="$(id -un)"
    uid="$(id -u)"
    if grep -qE "^(${user}|${uid}):" /etc/subuid 2>/dev/null \
       && grep -qE "^(${user}|${uid}):" /etc/subgid 2>/dev/null; then
        ok "subuid/subgid für $user eingetragen"
    else
        check_err "kein Eintrag für $user in /etc/subuid bzw. /etc/subgid" \
                  "Abhilfe: sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 $user" \
                  "danach: podman system migrate"
    fi

    # Open WebUI erreicht llama-server über den Container-Namen, dafür ist
    # die Namensauflösung im Podman-Netz (aardvark-dns) erforderlich
    local backend dns_path="" p
    backend="$(podman info --format '{{.Host.NetworkBackend}}' 2>/dev/null || echo unbekannt)"
    if [ "$backend" = "netavark" ]; then
        dns_path="$(podman info --format '{{.Host.NetworkBackendInfo.DNS.Path}}' 2>/dev/null || true)"
        if [ -z "$dns_path" ] || [ ! -x "$dns_path" ]; then
            dns_path=""
            for p in /usr/lib/podman/aardvark-dns /usr/libexec/podman/aardvark-dns \
                     /usr/local/libexec/podman/aardvark-dns; do
                if [ -x "$p" ]; then
                    dns_path="$p"
                    break
                fi
            done
        fi
        if [ -n "$dns_path" ]; then
            ok "Netzwerk: netavark mit aardvark-dns"
        else
            check_err "aardvark-dns nicht gefunden, Open WebUI erreicht den Chat-Container sonst nicht" \
                      "Abhilfe: sudo apt install aardvark-dns"
        fi
    else
        check_warn "Netzwerk-Backend '$backend', empfohlen ist netavark mit aardvark-dns" \
                   "Open WebUI benötigt die Namensauflösung zwischen Containern"
    fi

    GRAPHROOT="$(podman info --format '{{.Store.GraphRoot}}' 2>/dev/null || true)"
    if [ -n "$GRAPHROOT" ]; then
        info "Podman-Speicher: $GRAPHROOT"
    fi

    local rc=0
    detect_compose || rc=$?
    case "$rc" in
        0)
            ok "Compose-Provider: $COMPOSE_DESC"
            if [ "${COMPOSE[0]}" = "podman" ] && printf '%s' "$COMPOSE_DESC" | grep -qi docker; then
                if ! systemctl --user is-active --quiet podman.socket 2>/dev/null; then
                    check_warn "docker-compose als Provider, Podman-Socket ist nicht aktiv" \
                               "Abhilfe: systemctl --user enable --now podman.socket" \
                               "oder: sudo apt install podman-compose"
                fi
            fi
            ;;
        2)
            check_err "als Compose-Provider nur das veraltete docker-compose 1.x gefunden" \
                      "Abhilfe: sudo apt install podman-compose"
            ;;
        *)
            check_err "kein Compose-Provider gefunden" "Abhilfe: sudo apt install podman-compose"
            ;;
    esac
}

# Port frei oder von einem eigenen Container belegt (der neu angelegt wird)
check_port_free() {
    local port="$1" label="$2" holder=""
    if [ "$HAVE_SS" != "1" ]; then
        return 0
    fi
    if [ -z "$(ss -Hltn "sport = :$port" 2>/dev/null || true)" ]; then
        ok "Port $port frei ($label)"
        return 0
    fi
    if [ "$PODMAN_OK" = "1" ]; then
        holder="$(podman ps --format '{{.Names}} {{.Ports}}' 2>/dev/null \
                  | awk -v p=":$port->" 'index($0, p) && $1 ~ /^local-coder-/ { print $1 }' || true)"
    fi
    if [ -n "$holder" ]; then
        ok "Port $port von $holder belegt, der Container wird neu angelegt"
    else
        check_err "Port $port ($label) ist bereits belegt" \
                  "Prozess anzeigen: sudo ss -ltnp 'sport = :$port'" \
                  "Abhilfe: anderen Port in setup.conf setzen"
    fi
}

check_ports() {
    section "Ports"
    check_port_free "$WEBUI_PORT" "Open WebUI"
    if [ "$AUTOCOMPLETE" = "1" ]; then
        check_port_free "$FIM_PORT" "Autovervollständigung"
    fi
}

check_dir_writable() {
    local dir="$1" label="$2" parent
    parent="$(existing_parent "$dir")"
    if [ -d "$parent" ] && [ -w "$parent" ]; then
        ok "$label: $dir"
    else
        check_err "$label nicht anlegbar oder nicht beschreibbar: $dir" \
                  "Abhilfe: sudo mkdir -p $dir && sudo chown -R $(id -un): $dir"
    fi
}

check_dirs() {
    section "Verzeichnisse"
    check_dir_writable "$MODELS_DIR" "Modelle"
    check_dir_writable "$WEBUI_DATA_DIR" "Daten Open WebUI"

    local free
    free="$(free_bytes "$WEBUI_DATA_DIR")"
    if [ "$free" -lt $((2 * 1024 * 1024 * 1024)) ]; then
        check_warn "nur $(fmt_gb "$free") GB frei für die Daten von Open WebUI, empfohlen sind 2 GB"
    fi

    # Anmeldung abschalten geht nur bei einer neuen Installation
    local prev_auth
    prev_auth="$(env_value WEBUI_AUTH)"
    if [ -f "$WEBUI_DATA_DIR/webui.db" ]; then
        FRESH_WEBUI=0
        if [ "$WEBUI_AUTH" = "0" ] && [ "$prev_auth" != "False" ]; then
            check_err "WEBUI_AUTH=0 ist nur bei einer neuen Installation möglich" \
                      "In $WEBUI_DATA_DIR existiert bereits eine Datenbank mit Konten." \
                      "Abhilfe: WEBUI_AUTH=1 setzen oder mit ./cleanup.sh --keep-models neu beginnen"
        elif [ "$WEBUI_AUTH" = "1" ] && [ "$prev_auth" = "False" ]; then
            check_warn "Wechsel von WEBUI_AUTH=0 auf 1: das vorhandene Konto hat kein Passwort" \
                       "Eine Anmeldung ist damit eventuell nicht möglich"
        fi
    fi
}

# ---------------------------------------------------------------------------
# Modelle
# ---------------------------------------------------------------------------

# Ermittelt Größe einer Datei auf Hugging Face (setzt REMOTE_SIZE, REMOTE_STATUS)
remote_size() {
    local url="$HF_ENDPOINT/$1/resolve/main/$2" headers
    REMOTE_SIZE=""
    REMOTE_STATUS=""
    headers="$(curl -sIL --max-time 30 "$url" 2>/dev/null | tr -d '\r' || true)"
    REMOTE_STATUS="$(printf '%s\n' "$headers" | awk 'toupper($1) ~ /^HTTP\// { s = $2 } END { print s }')"
    if [ -z "$REMOTE_STATUS" ]; then
        REMOTE_STATUS="000"
    fi
    if [ "$REMOTE_STATUS" != "200" ]; then
        return 1
    fi
    # x-linked-size = Größe der LFS-Datei, sonst Content-Length der letzten Antwort
    REMOTE_SIZE="$(printf '%s\n' "$headers" | awk '
        tolower($1) == "x-linked-size:"  { linked = $2 }
        tolower($1) == "content-length:" { len = $2 }
        END { if (linked != "") print linked; else print len }')"
    is_uint "$REMOTE_SIZE" && [ "$REMOTE_SIZE" -gt 0 ]
}

check_models() {
    section "Modelle ($MODELS_DIR)"

    local entries=("chat|$CHAT_MODEL_REPO|$CHAT_MODEL_FILE")
    if [ "$AUTOCOMPLETE" = "1" ]; then
        entries+=("fim|$FIM_MODEL_REPO|$FIM_MODEL_FILE")
    fi

    local entry role repo file path size have need_bytes=0
    for entry in "${entries[@]}"; do
        IFS='|' read -r role repo file <<< "$entry"
        path="$MODELS_DIR/$file"
        size=0
        if [ -f "$path" ]; then
            size="$(stat -c %s "$path")"
            ok "$file vorhanden ($(fmt_gb "$size") GB)"
        elif remote_size "$repo" "$file"; then
            size="$REMOTE_SIZE"
            have=0
            if [ -f "$path.part" ]; then
                have="$(stat -c %s "$path.part")"
            fi
            need_bytes=$((need_bytes + size - have))
            DOWNLOADS+=("$repo|$file|$size")
            info "$file fehlt, Download von $repo ($(fmt_gb "$size") GB)"
        elif [ "$REMOTE_STATUS" = "000" ]; then
            check_err "$HF_ENDPOINT nicht erreichbar, $file kann nicht geladen werden" \
                      "Abhilfe: Netzwerk bzw. Proxy prüfen oder die Datei nach $MODELS_DIR kopieren"
        else
            check_err "$file in $repo nicht gefunden (HTTP $REMOTE_STATUS)" \
                      "Abhilfe: Repo und Dateinamen in setup.conf prüfen"
        fi
        if [ "$role" = "chat" ]; then
            CHAT_MODEL_BYTES="$size"
        else
            FIM_MODEL_BYTES="$size"
        fi
    done

    if [ "$need_bytes" -gt 0 ]; then
        local free margin=$((1024 * 1024 * 1024))
        free="$(free_bytes "$MODELS_DIR")"
        if [ $((need_bytes + margin)) -gt "$free" ]; then
            check_err "zu wenig Platz in $MODELS_DIR: $(fmt_gb "$((need_bytes + margin))") GB benötigt, $(fmt_gb "$free") GB frei"
        else
            ok "Platz für Downloads: $(fmt_gb "$need_bytes") GB benötigt, $(fmt_gb "$free") GB frei"
        fi
    fi
}

# Grobe Abschätzung des RAM-Bedarfs: Modell + Kontext + Open WebUI + System
check_ram_fit() {
    section "RAM-Bedarf"
    if [ "$CHAT_MODEL_BYTES" -eq 0 ]; then
        skip "Chat-Modell unbekannt, Abschätzung entfällt"
        return 0
    fi

    local mib=$((1024 * 1024)) ctx webui sys fim=0 need
    ctx=$((CHAT_CTX * 100 * 1024))       # ca. 0,1 MB je Token Kontext
    webui=$((1536 * mib))
    sys=$((2048 * mib))
    if [ "$AUTOCOMPLETE" = "1" ]; then
        fim=$((FIM_MODEL_BYTES + 512 * mib))
    fi
    need=$((CHAT_MODEL_BYTES + ctx + webui + sys + fim))

    if [ "$need" -gt "$MEM_BYTES" ]; then
        check_err "Konfiguration passt nicht in den Arbeitsspeicher: ca. $(fmt_gb "$need") GB benötigt, $(fmt_gb "$MEM_BYTES") GB vorhanden" \
                  "Abhilfe: kleineres Modell, kleineren CHAT_CTX oder AUTOCOMPLETE=0 in setup.conf"
    elif [ $((need * 100 / MEM_BYTES)) -gt 90 ]; then
        check_warn "Arbeitsspeicher knapp: ca. $(fmt_gb "$need") GB von $(fmt_gb "$MEM_BYTES") GB"
    else
        ok "ca. $(fmt_gb "$need") GB von $(fmt_gb "$MEM_BYTES") GB"
    fi

    # Aktuell freier Speicher, nur aussagekräftig, solange der Chat nicht läuft
    if [ "$PODMAN_OK" = "1" ] && container_running local-coder-chat; then
        return 0
    fi
    local avail_kib
    avail_kib="$(awk '/^MemAvailable:/ { print $2 }' /proc/meminfo)"
    if [ $((avail_kib * 1024)) -lt $((need - sys)) ]; then
        check_warn "derzeit nur $(fmt_gb "$((avail_kib * 1024))") GB RAM frei" \
                   "Andere Programme belegen Speicher, das Modell kann dann ausgelagert werden"
    fi
}

# ---------------------------------------------------------------------------
# Images
# ---------------------------------------------------------------------------

# Registry-Host eines Image-Namens (leer für lokale Images)
registry_host() {
    local first="${1%%/*}"
    if [ "$first" = "localhost" ]; then
        echo ""
    elif [ "$first" != "$1" ] && [[ "$first" == *.* || "$first" == *:* ]]; then
        echo "$first"
    else
        echo "registry-1.docker.io"
    fi
}

check_registry() {
    local image="$1" host code
    host="$(registry_host "$image")"
    if [ -z "$host" ]; then
        return 0
    fi
    code="$(curl -s -o /dev/null --max-time 15 -w '%{http_code}' "https://$host/v2/" 2>/dev/null || true)"
    if [ -z "$code" ] || [ "$code" = "000" ]; then
        check_err "Registry $host nicht erreichbar, $image kann nicht geladen werden" \
                  "Abhilfe: Netzwerk bzw. Proxy prüfen"
    fi
}

check_images() {
    section "Images"
    if [ "$PODMAN_OK" != "1" ]; then
        skip "Podman nicht funktionsfähig, Prüfung entfällt"
        return 0
    fi

    local need_space=0 gib=$((1024 * 1024 * 1024))

    if [ "$UPDATE" = "1" ] || ! image_exists "$WEBUI_IMAGE"; then
        NEED_PULL_WEBUI=1
        need_space=$((need_space + 5 * gib))
        info "$WEBUI_IMAGE wird geladen"
        check_registry "$WEBUI_IMAGE"
    else
        ok "$WEBUI_IMAGE vorhanden"
    fi

    if [ "$UPDATE" = "1" ] || ! image_exists "$LLAMA_CPP_IMAGE"; then
        NEED_BASE_IMAGE=1
        need_space=$((need_space + 1 * gib))
        info "$LLAMA_CPP_IMAGE wird geladen"
        check_registry "$LLAMA_CPP_IMAGE"
    else
        ok "$LLAMA_CPP_IMAGE vorhanden"
    fi

    if [ -n "$GRAPHROOT" ] && [ "$need_space" -gt 0 ]; then
        local free min=$((MIN_IMAGE_SPACE_GB * gib))
        free="$(free_bytes "$GRAPHROOT")"
        if [ "$free" -lt "$min" ]; then
            check_err "zu wenig Platz im Podman-Speicher $GRAPHROOT: $(fmt_gb "$free") GB frei, erforderlich $MIN_IMAGE_SPACE_GB GB"
        else
            ok "Podman-Speicher: $(fmt_gb "$free") GB frei"
        fi
    fi
}

# ---------------------------------------------------------------------------
# Einrichtung
# ---------------------------------------------------------------------------

prepare_dirs() {
    section "Vorbereitung"
    mkdir -p "$MODELS_DIR" "$WEBUI_DATA_DIR"
    ok "Verzeichnisse angelegt"
}

ensure_secret() {
    if [ ! -s "$SECRET_FILE" ]; then
        (umask 077 && od -An -tx1 -N32 /dev/urandom | tr -d ' \n' > "$SECRET_FILE")
        ok "Sitzungsschlüssel für Open WebUI erzeugt ($SECRET_FILE)"
    fi
    WEBUI_SECRET_KEY="$(tr -d ' \n' < "$SECRET_FILE")"
}

write_env() {
    local tmp="$ENV_FILE.tmp"
    local persistent=True
    if [ "$WEBUI_CONFIG_FROM_ENV" = "1" ]; then
        persistent=False
    fi

    (
        umask 077
        cat > "$tmp" <<EOF
# Erzeugt von setup.sh aus setup.conf am $(date '+%Y-%m-%d %H:%M:%S')
# Nicht von Hand bearbeiten: Änderungen in setup.conf, danach ./setup.sh
AUTOCOMPLETE=$AUTOCOMPLETE
LLM_IMAGE=$LLM_IMAGE
WEBUI_IMAGE=$WEBUI_IMAGE
MODELS_DIR=$MODELS_DIR
WEBUI_DATA_DIR=$WEBUI_DATA_DIR
BIND_ADDRESS=$BIND_ADDRESS
WEBUI_PORT=$WEBUI_PORT
FIM_PORT=$FIM_PORT
CHAT_MODEL_FILE=$CHAT_MODEL_FILE
CHAT_ALIAS=$CHAT_ALIAS
CHAT_THREADS=$(effective_chat_threads)
CHAT_CTX=$CHAT_CTX
CHAT_THINKING=$CHAT_THINKING
CHAT_SAMPLING=$CHAT_SAMPLING
CHAT_EXTRA_ARGS=$CHAT_EXTRA_ARGS
FIM_MODEL_FILE=$FIM_MODEL_FILE
FIM_THREADS=$FIM_THREADS
FIM_EXTRA_ARGS=$FIM_EXTRA_ARGS
WEBUI_SECRET_KEY=$WEBUI_SECRET_KEY
WEBUI_AUTH=$(to_bool "$WEBUI_AUTH")
WEBUI_LOCALE=$WEBUI_LOCALE
WEBUI_OFFLINE=$(to_bool "$WEBUI_OFFLINE")
WEBUI_TITLE_GENERATION=$(to_bool "$WEBUI_TITLE_GENERATION")
WEBUI_BACKGROUND_TASKS=$(to_bool "$WEBUI_BACKGROUND_TASKS")
WEBUI_REQUEST_TIMEOUT=$WEBUI_REQUEST_TIMEOUT
WEBUI_PERSISTENT_CONFIG=$persistent
EOF
    )
    mv -f "$tmp" "$ENV_FILE"
    ok ".env aus setup.conf erzeugt"
}

download_models() {
    if [ "${#DOWNLOADS[@]}" -eq 0 ]; then
        return 0
    fi
    section "Download der Modelle"

    local entry repo file size target url have
    for entry in "${DOWNLOADS[@]}"; do
        IFS='|' read -r repo file size <<< "$entry"
        target="$MODELS_DIR/$file"
        url="$HF_ENDPOINT/$repo/resolve/main/$file"

        have=0
        if [ -f "$target.part" ]; then
            have="$(stat -c %s "$target.part")"
        fi
        # Unvollständige Datei größer als erwartet: neu beginnen
        if [ "$have" -gt "$size" ]; then
            rm -f "$target.part"
            have=0
        fi
        if [ "$have" != "$size" ]; then
            info "lade $file ($(fmt_gb "$size") GB)"
            if ! curl -fL --retry 5 --retry-delay 5 -C - -# -o "$target.part" "$url"; then
                err "Download von $file abgebrochen"
                ehint "Ein erneuter Aufruf von ./setup.sh setzt an der gleichen Stelle fort"
                exit 1
            fi
            have="$(stat -c %s "$target.part")"
        fi
        if [ "$have" != "$size" ]; then
            err "Größe von $file stimmt nicht: $have statt $size Bytes"
            ehint "Abhilfe: $target.part löschen und ./setup.sh erneut ausführen"
            exit 1
        fi
        mv -f "$target.part" "$target"
        ok "$file"
    done
}

build_llm_image() {
    section "Images bauen und laden"
    local ctx pull_arg=()
    if [ "$UPDATE" = "1" ]; then
        pull_arg=(--pull=always)
    fi

    # Eigener Build-Kontext nur mit den benötigten Dateien (ohne Modelle)
    ctx="$(mktemp -d)"
    cp "$SCRIPT_DIR/Dockerfile" "$SCRIPT_DIR/entrypoint.sh" "$ctx/"
    info "baue $LLM_IMAGE (Basis: $LLAMA_CPP_IMAGE, Details in $LOG_FILE)"
    if ! run_logged podman build "${pull_arg[@]}" \
            --build-arg "LLAMA_CPP_IMAGE=$LLAMA_CPP_IMAGE" -t "$LLM_IMAGE" "$ctx"; then
        rm -rf "$ctx"
        exit 1
    fi
    rm -rf "$ctx"
    ok "$LLM_IMAGE gebaut"
}

pull_webui_image() {
    if [ "$NEED_PULL_WEBUI" != "1" ]; then
        return 0
    fi
    info "lade $WEBUI_IMAGE (ca. 2 GB)"
    if ! podman pull "$WEBUI_IMAGE"; then
        die "$WEBUI_IMAGE konnte nicht geladen werden"
    fi
    ok "$WEBUI_IMAGE geladen"
}

# Das Standard-Image enthält das Embedding-Modell für Wissen und Dateien
# unter /app/backend/data/cache. Der Bind-Mount des Datenverzeichnisses
# verdeckt diesen Pfad, deshalb wird der Cache einmalig herauskopiert.
seed_webui_cache() {
    if [ -d "$WEBUI_DATA_DIR/cache/embedding" ]; then
        ok "Embedding-Modell für Open WebUI vorhanden"
        return 0
    fi
    podman rm -f "$SEED_CONTAINER" >/dev/null 2>&1 || true
    if podman create --name "$SEED_CONTAINER" "$WEBUI_IMAGE" >/dev/null 2>&1 \
       && podman cp "$SEED_CONTAINER:/app/backend/data/cache" "$WEBUI_DATA_DIR/" >/dev/null 2>&1; then
        ok "Embedding-Modell aus dem Image übernommen"
    else
        warn "Embedding-Modell konnte nicht aus dem Image übernommen werden"
        if [ "$WEBUI_OFFLINE" = "1" ]; then
            hint "Mit WEBUI_OFFLINE=1 schlägt dann das Hochladen von Dateien fehl."
            hint "Abhilfe: einmalig mit WEBUI_OFFLINE=0 starten, Open WebUI lädt es selbst."
        fi
    fi
    podman rm -f "$SEED_CONTAINER" >/dev/null 2>&1 || true
}

start_stack() {
    section "Start"
    local services svc c failed=0
    read -r -a services <<< "$(enabled_services)"

    info "lege Container neu an: ${services[*]}"
    compose_logged down || true
    for c in "${CONTAINERS[@]}"; do
        if container_exists "$c"; then
            podman rm -f "$c" >/dev/null
        fi
    done
    if podman pod exists "$POD_NAME" 2>/dev/null; then
        podman pod rm -f "$POD_NAME" >/dev/null 2>&1 || true
    fi

    if ! compose_logged up -d "${services[@]}"; then
        exit 1
    fi
    for svc in "${services[@]}"; do
        if ! container_running "local-coder-$svc"; then
            err "local-coder-$svc läuft nicht (Status: $(container_status "local-coder-$svc"))"
            ehint "Log: ./ctl.sh logs $svc"
            failed=1
        fi
    done
    if [ "$failed" = "1" ]; then
        exit 1
    fi

    wait_ready chat 600 || failed=1
    wait_ready webui 300 || failed=1
    if [ "$AUTOCOMPLETE" = "1" ]; then
        wait_ready fim 300 || failed=1
    fi
    if [ "$failed" = "1" ]; then
        err "nicht alle Dienste sind bereit"
        ehint "Status: ./ctl.sh status, Logs: ./ctl.sh logs chat|webui|fim"
        exit 1
    fi
}

summary_checks() {
    section "Ergebnis der Prüfung"
    if [ "$ERRORS" -gt 0 ]; then
        err "$ERRORS Fehler, $WARNINGS Warnung(en). Es wurde nichts verändert."
        return 1
    fi
    ok "keine Fehler, $WARNINGS Warnung(en)"
}

print_done() {
    section "Fertig"
    if [ "$NO_START" = "1" ]; then
        echo "  Start:          ./ctl.sh start"
    else
        echo "  Oberfläche:     $(webui_url)"
        if [ "$WEBUI_AUTH" = "1" ] && [ "$FRESH_WEBUI" = "1" ]; then
            echo "                  (das erste angelegte Konto wird Admin)"
        fi
        if [ "$AUTOCOMPLETE" = "1" ]; then
            echo "  Autocomplete:   $(fim_url) (VS Code: llama-vscode)"
        fi
    fi
    echo "  Status:         ./ctl.sh status"
    echo "  Logs:           ./ctl.sh logs chat|webui|fim"
    echo "  Nach Neustart:  ./ctl.sh start"
}

# ---------------------------------------------------------------------------

main() {
    local arg
    for arg in "$@"; do
        case "$arg" in
            --check)    CHECK_ONLY=1 ;;
            --no-start) NO_START=1 ;;
            --update)   UPDATE=1 ;;
            -h|--help)  usage; exit 0 ;;
            *)          usage >&2; exit 1 ;;
        esac
    done

    cd "$SCRIPT_DIR"
    load_config
    echo "local-coder: Einrichtung in $SCRIPT_DIR"

    check_config
    if [ "$ERRORS" -gt 0 ]; then
        summary_checks || exit 1
    fi
    check_system
    check_podman
    check_ports
    check_dirs
    check_models
    check_ram_fit
    check_images
    summary_checks || exit 1

    if [ "$CHECK_ONLY" = "1" ]; then
        exit 0
    fi

    prepare_dirs
    ensure_secret
    write_env
    download_models
    build_llm_image
    pull_webui_image
    seed_webui_cache
    if [ "$NO_START" != "1" ]; then
        start_stack
    fi
    print_done
}

main "$@"
