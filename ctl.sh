#!/usr/bin/env bash
# Steuerung von local-coder im Alltag.
#
#   ./ctl.sh start           Container starten, z.B. nach einem Neustart des Rechners
#   ./ctl.sh stop            Container anhalten, der Arbeitsspeicher wird frei
#   ./ctl.sh restart         anhalten und wieder starten
#   ./ctl.sh status          Zustand, Bereitschaft und Speicherverbrauch
#   ./ctl.sh logs [dienst]   Log fortlaufend anzeigen (chat|webui|fim, Standard: chat)
#
# Es gelten die Werte der letzten Einrichtung. Änderungen an setup.conf
# übernimmt nur ./setup.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

usage() {
    cat <<EOF
Aufruf: $0 start|stop|restart|status|logs [chat|webui|fim]
EOF
}

require_setup() {
    if ! command -v podman >/dev/null 2>&1; then
        die "podman nicht gefunden"
    fi
    if [ ! -f "$ENV_FILE" ]; then
        die ".env fehlt, zuerst ./setup.sh ausführen"
    fi
    if [ "$CONF_FILE" -nt "$ENV_FILE" ]; then
        warn "setup.conf wurde nach der letzten Einrichtung geändert"
        hint "Die Änderungen werden erst mit ./setup.sh übernommen"
    fi
}

# Werte der letzten Einrichtung aus .env statt aus setup.conf
load_env_state() {
    local key val
    for key in AUTOCOMPLETE WEBUI_PORT FIM_PORT BIND_ADDRESS LLM_IMAGE WEBUI_IMAGE; do
        val="$(env_value "$key")"
        if [ -n "$val" ]; then
            printf -v "$key" '%s' "$val"
        fi
    done
}

wait_services() {
    local services svc failed=0
    read -r -a services <<< "$(enabled_services)"
    for svc in "${services[@]}"; do
        if [ "$svc" = "chat" ]; then
            wait_ready "$svc" 600 || failed=1
        else
            wait_ready "$svc" 300 || failed=1
        fi
    done
    if [ "$failed" = "1" ]; then
        err "nicht alle Dienste sind bereit"
        ehint "Logs: ./ctl.sh logs chat|webui|fim"
        return 1
    fi
    echo
    echo "  Oberfläche:    $(webui_url)"
    if [ "$AUTOCOMPLETE" = "1" ]; then
        echo "  Autocomplete:  $(fim_url)"
    fi
}

cmd_start() {
    local services svc missing=()
    read -r -a services <<< "$(enabled_services)"

    for svc in "${services[@]}"; do
        if ! container_exists "local-coder-$svc"; then
            missing+=("$svc")
        fi
    done

    # Fehlende Container über Compose anlegen
    if [ "${#missing[@]}" -gt 0 ]; then
        if ! detect_compose; then
            die "kein nutzbarer Compose-Provider gefunden, Prüfung: ./setup.sh --check"
        fi
        if ! image_exists "$LLM_IMAGE" || ! image_exists "$WEBUI_IMAGE"; then
            die "Images fehlen, zuerst ./setup.sh ausführen"
        fi
        info "lege fehlende Container an: ${missing[*]}"
        if ! compose_logged up -d "${missing[@]}"; then
            exit 1
        fi
    fi

    # Vorhandene Container in fester Reihenfolge starten
    for svc in "${services[@]}"; do
        if container_running "local-coder-$svc"; then
            skip "local-coder-$svc läuft bereits"
        elif ! podman start "local-coder-$svc" >/dev/null; then
            die "local-coder-$svc konnte nicht gestartet werden"
        else
            ok "local-coder-$svc gestartet"
        fi
    done

    # Deaktivierte Autovervollständigung nicht mitlaufen lassen
    if [ "$AUTOCOMPLETE" != "1" ] && container_running local-coder-fim; then
        podman stop -t 10 local-coder-fim >/dev/null
        info "local-coder-fim angehalten (AUTOCOMPLETE=0)"
    fi

    wait_services
}

cmd_stop() {
    local c any=0
    for c in local-coder-webui local-coder-fim local-coder-chat; do
        if container_running "$c"; then
            podman stop -t 15 "$c" >/dev/null
            ok "$c angehalten"
            any=1
        fi
    done
    if [ "$any" = "0" ]; then
        info "keine laufenden Container"
    fi
}

cmd_status() {
    local svc c status ready running=()
    printf '%-20s %-16s %s\n' "CONTAINER" "STATUS" "BEREIT"
    for svc in chat webui fim; do
        c="local-coder-$svc"
        status="$(container_status "$c")"
        ready="-"
        if [ "$svc" = "fim" ] && [ "$AUTOCOMPLETE" != "1" ] && ! container_exists "$c"; then
            status="deaktiviert"
        elif [ "$status" = "running" ]; then
            running+=("$c")
            if "${svc}_ready"; then
                ready="ja"
            else
                ready="nein (startet noch oder Fehler)"
            fi
        fi
        printf '%-20s %-16s %s\n' "$c" "$status" "$ready"
    done

    if [ "${#running[@]}" -gt 0 ]; then
        echo
        printf '%-20s %s\n' "CONTAINER" "RAM / CPU"
        if ! podman stats --no-stream --format '{{.Name}} {{.MemUsage}} {{.CPUPerc}}' "${running[@]}" 2>/dev/null \
             | awk '{ name = $1; $1 = ""; printf "%-20s%s\n", name, $0 }'; then
            info "Speicherverbrauch nicht verfügbar (podman stats)"
        fi
    fi

    echo
    echo "Oberfläche:   $(webui_url)"
    if [ "$AUTOCOMPLETE" = "1" ]; then
        echo "Autocomplete: $(fim_url)"
    fi
}

cmd_logs() {
    local svc="${1:-chat}"
    case "$svc" in
        chat|webui|fim) ;;
        *) die "unbekannter Dienst '$svc' (chat|webui|fim)" ;;
    esac
    if ! container_exists "local-coder-$svc"; then
        die "Container local-coder-$svc ist nicht vorhanden"
    fi
    # podman logs schreibt die Ausgabe des Containers auch auf stderr
    exec podman logs -f --tail 200 "local-coder-$svc" 2>&1
}

main() {
    local cmd="${1:-}"
    if [ "$#" -gt 0 ]; then
        shift
    fi
    case "$cmd" in
        -h|--help|"") usage; exit 0 ;;
    esac

    cd "$SCRIPT_DIR"
    load_config
    require_setup
    load_env_state

    case "$cmd" in
        start)   cmd_start ;;
        stop)    cmd_stop ;;
        restart) cmd_stop; cmd_start ;;
        status)  cmd_status ;;
        logs)    cmd_logs "$@" ;;
        *)       usage >&2; exit 1 ;;
    esac
}

main "$@"
