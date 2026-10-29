#!/usr/bin/env bash
# Entfernt local-coder vollständig:
#   - Container, Pod und Netzwerk
#   - Images (llama-server inkl. Build-Reste, llama.cpp-Basis-Image, Open WebUI)
#   - Modelle (MODELS_DIR)
#   - Daten von Open WebUI (Konten, Chats, Projekte, Wissen, Uploads)
#   - erzeugte Dateien (.env, .env.old, .webui_secret, .local-coder.log)
# Die Projektdateien (Skripte, setup.conf, README.txt, README_de.txt) bleiben erhalten.
#
# Laufen noch Container, werden sie angezeigt und es folgt eine Abfrage (y/n).
#
#   ./cleanup.sh                alles entfernen
#   ./cleanup.sh --keep-models  Modelle behalten (spart den erneuten Download)
#   ./cleanup.sh --keep-data    Daten von Open WebUI behalten
#   ./cleanup.sh -y             keine Abfrage, laufende Container werden beendet

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

KEEP_MODELS=0
KEEP_DATA=0
ASSUME_YES=0
FAILED=0
HAVE_PODMAN=0

usage() {
    cat <<EOF
Aufruf: $0 [--keep-models] [--keep-data] [-y]

  --keep-models  Modelle nicht löschen
  --keep-data    Daten von Open WebUI nicht löschen
  -y, --yes      ohne Abfrage, auch wenn noch Container laufen
EOF
}

section() { printf '\n== %s ==\n' "$1"; }

fail() {
    err "$1"
    FAILED=1
}

# Werte aus setup.conf und aus der letzten Einrichtung (.env) sammeln,
# falls setup.conf seitdem geändert wurde. Doppelte Einträge entfallen.
unique() { printf '%s\n' "$@" | awk 'NF && !seen[$0]++'; }

collect_values() {
    local key="$1" current="$2" from_env
    from_env="$(env_value "$key")"
    unique "$current" "$from_env"
}

# Verzeichnis löschen mit Schutz vor gefährlichen Pfaden. Dateien mit
# Subuid-Besitzer (aus Containern) werden über "podman unshare" entfernt.
safe_rm_dir() {
    local dir size slashes
    dir="$(realpath -m -- "$1")"
    slashes="$(printf '%s' "$dir" | tr -cd '/' | wc -c)"
    case "$dir" in
        ""|"/"|"$HOME"|"$SCRIPT_DIR")
            fail "Pfad wird aus Sicherheitsgründen nicht gelöscht: '$dir'"
            return 0
            ;;
    esac
    if [ "$slashes" -lt 2 ]; then
        fail "Pfad wird aus Sicherheitsgründen nicht gelöscht: '$dir'"
        return 0
    fi
    case "$SCRIPT_DIR/" in
        "$dir"/*)
            fail "Pfad enthält das Projektverzeichnis und wird nicht gelöscht: '$dir'"
            return 0
            ;;
    esac
    if [ ! -e "$dir" ]; then
        skip "$dir nicht vorhanden"
        return 0
    fi

    size="$(du -sh "$dir" </dev/null 2>/dev/null | cut -f1 || true)"
    if [ "$HAVE_PODMAN" = "1" ]; then
        podman unshare rm -rf -- "$dir" </dev/null 2>/dev/null || true
    fi
    if [ -e "$dir" ]; then
        rm -rf -- "$dir" 2>/dev/null || true
    fi
    if [ -e "$dir" ]; then
        fail "$dir konnte nicht vollständig gelöscht werden"
    else
        ok "$dir entfernt (${size:-?})"
    fi
}

is_inside_project() {
    case "$1/" in
        "$SCRIPT_DIR"/*) return 0 ;;
        *)               return 1 ;;
    esac
}

# ---------------------------------------------------------------------------

check_running() {
    if [ "$HAVE_PODMAN" != "1" ]; then
        return 0
    fi

    local c running=() label_list
    for c in "${CONTAINERS[@]}" "$SEED_CONTAINER"; do
        if container_running "$c"; then
            running+=("$c")
        fi
    done
    # Container mit Compose-Label des Projekts, falls umbenannt
    label_list="$(
        {
            podman ps --filter "label=com.docker.compose.project=$PROJECT_NAME" --format '{{.Names}}'
            podman ps --filter "label=io.podman.compose.project=$PROJECT_NAME" --format '{{.Names}}'
        } 2>/dev/null || true
    )"
    while read -r c; do
        if [ -n "$c" ] && ! printf '%s\n' "${running[@]:-}" | grep -qxF "$c"; then
            running+=("$c")
        fi
    done <<< "$label_list"

    if [ "${#running[@]}" -eq 0 ]; then
        info "keine laufenden Instanzen"
        return 0
    fi

    warn "laufende Instanzen gefunden:"
    for c in "${running[@]}"; do
        hint "$c ($(podman ps --filter "name=^${c}\$" --format '{{.Status}}' 2>/dev/null || true))"
    done
    if [ "$ASSUME_YES" = "1" ]; then
        info "-y gesetzt, die Instanzen werden beendet"
        return 0
    fi
    if ! ask_yes_no "Instanzen beenden und alles entfernen?"; then
        info "Abbruch, es wurde nichts verändert"
        exit 0
    fi
}

remove_containers() {
    section "Container, Pod, Netzwerk"
    if [ "$HAVE_PODMAN" != "1" ]; then
        skip "podman nicht gefunden"
        return 0
    fi

    local c ids
    for c in "${CONTAINERS[@]}" "$SEED_CONTAINER"; do
        if container_exists "$c"; then
            if podman rm -f "$c" >/dev/null 2>&1; then
                ok "Container $c entfernt"
            else
                fail "Container $c konnte nicht entfernt werden"
            fi
        fi
    done

    ids="$(
        {
            podman ps -aq --filter "label=com.docker.compose.project=$PROJECT_NAME"
            podman ps -aq --filter "label=io.podman.compose.project=$PROJECT_NAME"
        } 2>/dev/null | sort -u || true
    )"
    if [ -n "$ids" ]; then
        # shellcheck disable=SC2086
        if podman rm -f $ids >/dev/null 2>&1; then
            ok "weitere Container des Projekts entfernt"
        else
            fail "weitere Container des Projekts konnten nicht entfernt werden"
        fi
    fi

    if podman pod exists "$POD_NAME" 2>/dev/null; then
        if podman pod rm -f "$POD_NAME" >/dev/null 2>&1; then
            ok "Pod $POD_NAME entfernt"
        else
            fail "Pod $POD_NAME konnte nicht entfernt werden"
        fi
    fi

    if podman network exists "$NETWORK_NAME" 2>/dev/null; then
        if podman network rm "$NETWORK_NAME" >/dev/null 2>&1; then
            ok "Netzwerk $NETWORK_NAME entfernt"
        else
            fail "Netzwerk $NETWORK_NAME konnte nicht entfernt werden"
        fi
    fi
}

remove_images() {
    section "Images"
    if [ "$HAVE_PODMAN" != "1" ]; then
        skip "podman nicht gefunden"
        return 0
    fi

    local img ids images
    # Eigene Images inkl. Build-Reste anhand des Labels aus dem Dockerfile
    ids="$(podman images -q --filter "label=$IMAGE_LABEL" 2>/dev/null | sort -u || true)"
    if [ -n "$ids" ]; then
        # shellcheck disable=SC2086
        if podman rmi -f $ids >/dev/null 2>&1; then
            ok "llama-server-Images entfernt"
        else
            fail "llama-server-Images konnten nicht vollständig entfernt werden"
        fi
    fi

    images="$(unique \
        "$(collect_values LLM_IMAGE "$LLM_IMAGE")" \
        "$(collect_values WEBUI_IMAGE "$WEBUI_IMAGE")" \
        "$LLAMA_CPP_IMAGE")"
    while read -r img; do
        if [ -z "$img" ] || ! image_exists "$img"; then
            continue
        fi
        # Ohne -f: von fremden Containern genutzte Images bleiben erhalten
        if podman rmi "$img" </dev/null >/dev/null 2>&1; then
            ok "Image $img entfernt"
        else
            warn "Image $img nicht entfernt (wird von anderen Containern verwendet)"
        fi
    done <<< "$images"
}

remove_models() {
    section "Modelle"
    if [ "$KEEP_MODELS" = "1" ]; then
        skip "Modelle bleiben erhalten (--keep-models)"
        return 0
    fi

    local dir files f
    files="$(unique \
        "$(collect_values CHAT_MODEL_FILE "$CHAT_MODEL_FILE")" \
        "$(collect_values FIM_MODEL_FILE "$FIM_MODEL_FILE")")"

    while read -r dir; do
        if [ -z "$dir" ]; then
            continue
        fi
        if is_inside_project "$dir"; then
            safe_rm_dir "$dir"
            continue
        fi
        # Außerhalb des Projekts nur die eigenen Modelldateien löschen,
        # das Verzeichnis kann weitere Dateien enthalten
        if [ ! -d "$dir" ]; then
            skip "$dir nicht vorhanden"
            continue
        fi
        while read -r f; do
            if [ -n "$f" ] && { [ -e "$dir/$f" ] || [ -e "$dir/$f.part" ]; }; then
                rm -f -- "$dir/$f" "$dir/$f.part"
                ok "$dir/$f entfernt"
            fi
        done <<< "$files"
        if rmdir -- "$dir" 2>/dev/null; then
            ok "leeres Verzeichnis $dir entfernt"
        else
            info "$dir enthält weitere Dateien und bleibt bestehen"
        fi
    done <<< "$(collect_values MODELS_DIR "$MODELS_DIR")"
}

remove_data() {
    section "Daten von Open WebUI"
    if [ "$KEEP_DATA" = "1" ]; then
        skip "Daten bleiben erhalten (--keep-data)"
        return 0
    fi

    local dir parent
    while read -r dir; do
        if [ -z "$dir" ]; then
            continue
        fi
        safe_rm_dir "$dir"
        # Leeres Elternverzeichnis im Projekt (Standard: ./data) mit entfernen
        parent="$(dirname "$dir")"
        if [ "$parent" != "$SCRIPT_DIR" ] && is_inside_project "$parent"; then
            if rmdir -- "$parent" 2>/dev/null; then
                ok "leeres Verzeichnis $parent entfernt"
            fi
        fi
    done <<< "$(collect_values WEBUI_DATA_DIR "$WEBUI_DATA_DIR")"
}

remove_files() {
    section "Erzeugte Dateien"
    local f
    for f in "$ENV_FILE" "$ENV_FILE.old" "$ENV_FILE.tmp" "$LOG_FILE" "$SECRET_FILE"; do
        if [ "$KEEP_DATA" = "1" ] && [ "$f" = "$SECRET_FILE" ]; then
            # Der Schlüssel gehört zu den Sitzungen der behaltenen Daten
            skip "$f bleibt erhalten (--keep-data)"
            continue
        fi
        if [ -e "$f" ]; then
            rm -f -- "$f"
            ok "$f entfernt"
        fi
    done
}

main() {
    local arg
    for arg in "$@"; do
        case "$arg" in
            --keep-models) KEEP_MODELS=1 ;;
            --keep-data)   KEEP_DATA=1 ;;
            -y|--yes)      ASSUME_YES=1 ;;
            -h|--help)     usage; exit 0 ;;
            *)             usage >&2; exit 1 ;;
        esac
    done

    cd "$SCRIPT_DIR"
    load_config optional
    if command -v podman >/dev/null 2>&1; then
        HAVE_PODMAN=1
    else
        warn "podman nicht gefunden, Container und Images werden übersprungen"
    fi

    echo "local-coder: vollständiges Entfernen in $SCRIPT_DIR"
    check_running

    remove_containers
    remove_images
    remove_models
    remove_data
    remove_files

    section "Ergebnis"
    if [ "$FAILED" = "1" ]; then
        err "nicht alles konnte entfernt werden, Details siehe oben"
        exit 1
    fi
    ok "local-coder entfernt"
    hint "Die Projektdateien liegen weiterhin in $SCRIPT_DIR."
    hint "Vollständig löschen: rm -rf $SCRIPT_DIR"
}

main "$@"
