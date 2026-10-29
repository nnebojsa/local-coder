#!/usr/bin/env bash
# Gemeinsame Funktionen und Standardwerte für setup.sh, ctl.sh und cleanup.sh.
# Wird per "source" eingebunden und nicht direkt ausgeführt.
# Voraussetzung: SCRIPT_DIR ist gesetzt.

PROJECT_NAME="local-coder"
CONTAINERS=(local-coder-chat local-coder-webui local-coder-fim)
SEED_CONTAINER="local-coder-seed"
NETWORK_NAME="${PROJECT_NAME}_default"
POD_NAME="pod_${PROJECT_NAME}"
IMAGE_LABEL="io.local-coder.project=local-coder"

CONF_FILE="$SCRIPT_DIR/setup.conf"
ENV_FILE="$SCRIPT_DIR/.env"
SECRET_FILE="$SCRIPT_DIR/.webui_secret"
LOG_FILE="$SCRIPT_DIR/.local-coder.log"
ENV_MARKER="# Erzeugt von setup.sh"

# ---------------------------------------------------------------------------
# Ausgabe (nur ASCII, feste Breite der Präfixe)
# ---------------------------------------------------------------------------

info() { printf 'INFO:  %s\n' "$*"; }
ok()   { printf 'OK:    %s\n' "$*"; }
skip() { printf 'SKIP:  %s\n' "$*"; }
warn() { printf 'WARN:  %s\n' "$*"; }
err()  { printf 'ERROR: %s\n' "$*" >&2; }
hint() { printf '       %s\n' "$*"; }
ehint() { printf '       %s\n' "$*" >&2; }
die()  { err "$@"; exit 1; }

# Ja/Nein-Abfrage. Ohne Terminal gilt "nein".
ask_yes_no() {
    local answer
    if [ ! -t 0 ]; then
        warn "keine interaktive Eingabe möglich, Antwort gilt als n"
        return 1
    fi
    while true; do
        read -r -p "$1 [y/n] " answer || return 1
        case "$answer" in
            y|Y|yes|j|J|ja) return 0 ;;
            n|N|no|nein)    return 1 ;;
            *)              echo "Eingabe: y oder n" ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Konfiguration
# ---------------------------------------------------------------------------

# Standardwerte, falls ein Schlüssel in setup.conf fehlt
set_defaults() {
    MODELS_DIR=./models
    WEBUI_DATA_DIR=./data/webui
    BIND_ADDRESS=127.0.0.1
    WEBUI_PORT=3000
    HF_ENDPOINT=https://huggingface.co
    WEBUI_IMAGE=ghcr.io/open-webui/open-webui:v0.12.1
    WEBUI_AUTH=1
    WEBUI_LOCALE=de-DE
    WEBUI_OFFLINE=1
    WEBUI_TITLE_GENERATION=0
    WEBUI_BACKGROUND_TASKS=0
    WEBUI_REQUEST_TIMEOUT=1800
    WEBUI_CONFIG_FROM_ENV=0
    CHAT_MODEL_REPO=unsloth/Qwen3.5-9B-GGUF
    CHAT_MODEL_FILE=Qwen3.5-9B-UD-Q4_K_XL.gguf
    CHAT_ALIAS=local-chat
    CHAT_CTX=16384
    CHAT_THREADS=auto
    CHAT_THINKING=0
    CHAT_SAMPLING=qwen
    CHAT_EXTRA_ARGS=""
    AUTOCOMPLETE=0
    FIM_MODEL_REPO=ggml-org/Qwen2.5-Coder-1.5B-Q8_0-GGUF
    FIM_MODEL_FILE=qwen2.5-coder-1.5b-q8_0.gguf
    FIM_PORT=8012
    FIM_THREADS=2
    FIM_EXTRA_ARGS=""
    LLAMA_CPP_IMAGE=ghcr.io/ggml-org/llama.cpp:server
    LLM_IMAGE=localhost/local-coder-llama:latest
    MIN_RAM_GB=16
    MIN_IMAGE_SPACE_GB=8
}

# Relativen Pfad auf das Projektverzeichnis beziehen und normalisieren
resolve_path() {
    local p="$1"
    case "$p" in
        "")      return 0 ;;
        "~")     p="$HOME" ;;
        "~/"*)   p="$HOME/${p#\~/}" ;;
        /*)      ;;
        *)       p="$SCRIPT_DIR/$p" ;;
    esac
    realpath -m -- "$p"
}

# Lädt setup.conf über die Standardwerte.
# $1 = "optional": fehlende setup.conf ist kein Fehler (für cleanup.sh)
load_config() {
    set_defaults
    if [ -f "$CONF_FILE" ]; then
        # shellcheck source=setup.conf
        . "$CONF_FILE"
    elif [ "${1:-}" = "optional" ]; then
        warn "setup.conf nicht gefunden, es gelten die Standardwerte"
    else
        die "setup.conf nicht gefunden: $CONF_FILE"
    fi
    MODELS_DIR="$(resolve_path "$MODELS_DIR")"
    WEBUI_DATA_DIR="$(resolve_path "$WEBUI_DATA_DIR")"
    HF_ENDPOINT="${HF_ENDPOINT%/}"
}

# Wert eines Schlüssels aus der erzeugten .env (leer, falls nicht vorhanden)
env_value() {
    if [ -f "$ENV_FILE" ]; then
        sed -n "s/^$1=//p" "$ENV_FILE" | tail -n 1
    fi
}

# Aktive Dienste laut setup.conf
enabled_services() {
    if [ "$AUTOCOMPLETE" = "1" ]; then
        echo "chat webui fim"
    else
        echo "chat webui"
    fi
}

webui_url() {
    local host="$BIND_ADDRESS"
    [ "$host" = "0.0.0.0" ] && host=127.0.0.1
    echo "http://$host:$WEBUI_PORT"
}

fim_url() {
    local host="$BIND_ADDRESS"
    [ "$host" = "0.0.0.0" ] && host=127.0.0.1
    echo "http://$host:$FIM_PORT"
}

# ---------------------------------------------------------------------------
# Hilfsfunktionen
# ---------------------------------------------------------------------------

is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }

# Bytes in GB mit einer Nachkommastelle
fmt_gb() { awk -v b="$1" 'BEGIN { printf "%.1f", b / 1024 / 1024 / 1024 }'; }

# Freier Platz in Bytes für einen Pfad (oder den nächsten existierenden Elternpfad)
free_bytes() {
    local d="$1"
    while [ ! -e "$d" ]; do d="$(dirname "$d")"; done
    df -Pk "$d" | awk 'NR == 2 { printf "%.0f", $4 * 1024 }'
}

# Nächster existierender Pfad (für Schreibrechte-Prüfungen)
existing_parent() {
    local d="$1"
    while [ ! -e "$d" ]; do d="$(dirname "$d")"; done
    echo "$d"
}

# Anzahl physischer CPU-Kerne
physical_cores() {
    local n=""
    if command -v lscpu >/dev/null 2>&1; then
        n="$(lscpu -p=Core,Socket 2>/dev/null | grep -v '^#' | sort -u | wc -l || true)"
    fi
    if ! is_uint "$n" || [ "$n" -lt 1 ]; then
        n="$(nproc 2>/dev/null || echo 4)"
    fi
    echo "$n"
}

effective_chat_threads() {
    if [ "$CHAT_THREADS" = "auto" ]; then
        physical_cores
    else
        echo "$CHAT_THREADS"
    fi
}

# Boolesche Werte für Open WebUI
to_bool() { if [ "$1" = "1" ]; then echo True; else echo False; fi; }

# ---------------------------------------------------------------------------
# Podman und Compose
# ---------------------------------------------------------------------------

COMPOSE=()
COMPOSE_DESC=""

# Ermittelt den Compose-Provider.
# Rückgabe: 0 = gefunden, 1 = keiner, 2 = nur veraltetes docker-compose 1.x
detect_compose() {
    local v
    if command -v podman-compose >/dev/null 2>&1; then
        COMPOSE=(podman-compose)
        v="$(podman-compose version 2>/dev/null | grep -m1 -oE '[0-9]+\.[0-9]+\.[0-9]+' || true)"
        COMPOSE_DESC="podman-compose ${v:-unbekannte Version}"
        return 0
    fi
    if command -v podman >/dev/null 2>&1 && v="$(podman compose version 2>/dev/null)"; then
        if printf '%s\n' "$v" | grep -q 'docker-compose version 1\.'; then
            COMPOSE_DESC="docker-compose 1.x"
            return 2
        fi
        COMPOSE=(podman compose)
        COMPOSE_DESC="podman compose ($(printf '%s\n' "$v" | head -n 1))"
        return 0
    fi
    return 1
}

# Compose im Projektverzeichnis mit festem Projektnamen aufrufen
compose() {
    (cd "$SCRIPT_DIR" && "${COMPOSE[@]}" -p "$PROJECT_NAME" -f "$SCRIPT_DIR/compose.yaml" "$@")
}

# Befehl mit Ausgabe in .local-coder.log ausführen, bei Fehler die letzten
# Zeilen anzeigen
run_logged() {
    echo "=== $(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG_FILE"
    if "$@" >> "$LOG_FILE" 2>&1; then
        return 0
    fi
    err "fehlgeschlagen: $*"
    ehint "letzte Zeilen aus $LOG_FILE:"
    tail -n 15 "$LOG_FILE" | sed 's/^/       /' >&2
    return 1
}

compose_logged() { run_logged compose "$@"; }

container_exists() { podman container exists "$1" </dev/null >/dev/null 2>&1; }

container_status() {
    podman container inspect --format '{{.State.Status}}' "$1" </dev/null 2>/dev/null || echo "nicht vorhanden"
}

container_running() { [ "$(container_status "$1")" = "running" ]; }

image_exists() { podman image exists "$1" </dev/null >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# Bereitschaft der Dienste
# ---------------------------------------------------------------------------

chat_ready() {
    podman exec local-coder-chat curl -fsS --max-time 5 http://127.0.0.1:8080/health >/dev/null 2>&1
}

fim_ready() {
    podman exec local-coder-fim curl -fsS --max-time 5 http://127.0.0.1:8012/health >/dev/null 2>&1
}

webui_ready() {
    curl -fsS --max-time 5 "$(webui_url)/health" >/dev/null 2>&1
}

# Wartet, bis ein Dienst bereit ist.
# $1 = Dienst (chat|webui|fim), $2 = Timeout in Sekunden
wait_ready() {
    local svc="$1" timeout="$2" waited=0 down=0 status
    printf 'INFO:  warte auf %s ' "$svc"
    while ! "${svc}_ready"; do
        status="$(container_status "local-coder-$svc")"
        if [ "$status" != "running" ]; then
            down=$((down + 1))
        else
            down=0
        fi
        if [ "$waited" -ge "$timeout" ] || [ "$down" -ge 3 ]; then
            printf ' nicht bereit (Status: %s)\n' "$status"
            return 1
        fi
        sleep 5
        waited=$((waited + 5))
        printf '.'
    done
    printf ' bereit\n'
    return 0
}
