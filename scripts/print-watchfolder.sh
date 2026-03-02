#!/bin/bash
# =============================================================================
# Print Watchfolder - ueberwacht SMB-Freigabe und druckt PDFs automatisch
# =============================================================================

WATCH_DIR="/srv/samba/druckauftraege"
DONE_DIR="$WATCH_DIR/gedruckt"
FAIL_DIR="$WATCH_DIR/fehler"
LOG_FILE="/var/log/printserver.log"
PRINTER_NAME="${PRINTER_NAME:-EcoTank-ET2820}"
LOCK_DIR="/tmp/printserver-locks"

mkdir -p "$DONE_DIR" "$FAIL_DIR" "$LOCK_DIR"

log() {
    local msg="$(date '+%Y-%m-%d %H:%M:%S') [$1] $2"
    echo "$msg" >> "$LOG_FILE"
    echo "$msg"
}

print_pdf() {
    local filepath="$1"
    local filename="$(basename "$filepath")"
    local lockfile="$LOCK_DIR/$filename.lock"

    # Doppelte Verarbeitung verhindern
    if [ -f "$lockfile" ]; then
        return
    fi
    touch "$lockfile"

    # Warten bis die Datei vollstaendig geschrieben ist (NT 4.0 kopiert langsam)
    local prev_size=0
    local curr_size=1
    local wait_count=0
    while [ "$prev_size" != "$curr_size" ] && [ "$wait_count" -lt 60 ]; do
        prev_size="$curr_size"
        sleep 2
        curr_size=$(stat -c%s "$filepath" 2>/dev/null || echo "0")
        wait_count=$((wait_count + 1))
    done

    # Pruefen ob Datei noch existiert
    if [ ! -f "$filepath" ]; then
        log "WARN" "Datei verschwunden: $filename"
        rm -f "$lockfile"
        return
    fi

    # Pruefen ob es ein gueltiges PDF ist
    if ! head -c 5 "$filepath" | grep -q '%PDF'; then
        log "FEHLER" "Keine gueltige PDF-Datei: $filename"
        mv "$filepath" "$FAIL_DIR/" 2>/dev/null
        rm -f "$lockfile"
        return
    fi

    log "INFO" "Drucke: $filename ($curr_size Bytes)"

    # An CUPS senden
    if lp -d "$PRINTER_NAME" "$filepath" 2>> "$LOG_FILE"; then
        log "OK" "Erfolgreich gesendet: $filename"
        mv "$filepath" "$DONE_DIR/" 2>/dev/null
    else
        log "FEHLER" "Druck fehlgeschlagen: $filename"
        mv "$filepath" "$FAIL_DIR/" 2>/dev/null
    fi

    rm -f "$lockfile"
}

# Bestehende PDFs beim Start verarbeiten
process_existing() {
    for pdf in "$WATCH_DIR"/*.pdf "$WATCH_DIR"/*.PDF; do
        if [ -f "$pdf" ]; then
            log "INFO" "Bestehende Datei gefunden: $(basename "$pdf")"
            print_pdf "$pdf"
        fi
    done
}

# ── Hauptprogramm ──────────────────────────────────────────────────────────

log "INFO" "=========================================="
log "INFO" "Print Watchfolder gestartet"
log "INFO" "Ueberwache: $WATCH_DIR"
log "INFO" "Drucker: $PRINTER_NAME"
log "INFO" "=========================================="

# Bestehende Dateien zuerst verarbeiten
process_existing

# Verzeichnis ueberwachen mit inotifywait
inotifywait -m -e close_write -e moved_to --format '%f' "$WATCH_DIR" 2>/dev/null | while read filename; do
    # Nur PDF-Dateien verarbeiten
    case "$filename" in
        *.pdf|*.PDF)
            filepath="$WATCH_DIR/$filename"
            if [ -f "$filepath" ]; then
                # Kurz warten damit die Datei vollstaendig ist
                sleep 1
                print_pdf "$filepath" &
            fi
            ;;
        *)
            log "INFO" "Ignoriert (kein PDF): $filename"
            ;;
    esac
done
