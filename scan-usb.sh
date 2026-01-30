#!/bin/bash
# ============================================================================
# USB-Virenscanner
# Scannt eingesteckte USB-Geräte mit ClamAV
# ============================================================================

# Pfad des Skripts ermitteln (für relative Verzeichnisse)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Konfiguration - alles relativ zum Skript-Verzeichnis
LOG_DIR="$SCRIPT_DIR/Logs"
QUARANTINE_DIR="$SCRIPT_DIR/Quarantäne"
LOG_FILE="$LOG_DIR/scan_$(date +%Y%m%d_%H%M%S).log"

# Verzeichnisse erstellen falls nicht vorhanden
mkdir -p "$LOG_DIR" "$QUARANTINE_DIR"

# Farben für Terminal-Ausgabe
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# ============================================================================
# Funktionen
# ============================================================================

print_header() {
    clear
    echo -e "${BLUE}"
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║                     USB-VIRENSCANNER                           ║"
    echo "║                        ClamAV-basiert                          ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

print_status() {
    echo -e "${CYAN}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNUNG]${NC} $1"
}

print_error() {
    echo -e "${RED}[FEHLER]${NC} $1"
}

print_threat() {
    echo -e "${RED}${BOLD}[VIRUS]${NC} $1"
}

# USB-Geräte finden - sucht in allen üblichen Mount-Punkten
find_usb_devices() {
    # Alle Unterordner in /media/ durchsuchen (für alle Benutzer)
    if [ -d "/media" ]; then
        for userdir in /media/*; do
            if [ -d "$userdir" ]; then
                for dev in "$userdir"/*; do
                    [ -d "$dev" ] && [ "$dev" != "$userdir/*" ] && echo "$dev"
                done
            fi
        done
    fi
    
    # /run/media/ (Fedora, Arch, etc.)
    if [ -d "/run/media" ]; then
        for userdir in /run/media/*; do
            if [ -d "$userdir" ]; then
                for dev in "$userdir"/*; do
                    [ -d "$dev" ] && [ "$dev" != "$userdir/*" ] && echo "$dev"
                done
            fi
        done
    fi
    
    # /mnt/ (manuell gemountete Geräte)
    for dir in /mnt/*; do
        [ -d "$dir" ] && [ "$dir" != "/mnt/*" ] && mountpoint -q "$dir" 2>/dev/null && echo "$dir"
    done
}

# Signatur-Status prüfen
check_signatures() {
    if [ -f /var/lib/clamav/daily.cvd ] || [ -f /var/lib/clamav/daily.cld ]; then
        local sig_date=$(sigtool --info /var/lib/clamav/daily.cvd 2>/dev/null | grep "Build time" | cut -d: -f2- || echo "unbekannt")
        if [ -z "$sig_date" ]; then
            sig_date=$(sigtool --info /var/lib/clamav/daily.cld 2>/dev/null | grep "Build time" | cut -d: -f2- || echo "unbekannt")
        fi
        echo "$sig_date"
    else
        echo "nicht gefunden"
    fi
}

# Signaturen aktualisieren
update_signatures() {
    print_status "Aktualisiere Virensignaturen..."
    echo "Dies erfordert Administrator-Rechte."
    sudo systemctl stop clamav-freshclam 2>/dev/null || true
    if sudo freshclam 2>&1 | tee -a "$LOG_FILE"; then
        print_success "Signaturen aktualisiert"
    else
        print_warning "Signatur-Update fehlgeschlagen (evtl. bereits aktuell)"
    fi
    sudo systemctl start clamav-freshclam 2>/dev/null || true
}

# Scan durchführen
perform_scan() {
    local target="$1"
    local start_time=$(date +%s)
    
    echo ""
    echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}"
    print_status "Scanne: ${BOLD}$target${NC}"
    print_status "Gestartet: $(date '+%Y-%m-%d %H:%M:%S')"
    echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}"

    # Dateien zählen und Gesamtgröße ermitteln
    local total_files=$(find "$target" -type f 2>/dev/null | wc -l | tr -cd '0-9')
    total_files=${total_files:-0}
    local total_size=$(du -sh "$target" 2>/dev/null | cut -f1)
    total_size=${total_size:-"unbekannt"}
    print_status "Dateien: $total_files ($total_size)"
    echo ""

    # Log-Header
    {
        echo "=========================================="
        echo "USB-Scan Log"
        echo "Ziel: $target"
        echo "Start: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "=========================================="
    } >> "$LOG_FILE"
    
    # Temporäre Datei für Ergebnisse
    local temp_result=$(mktemp)
    
    # ClamAV Scan
    # --infected: Nur infizierte Dateien anzeigen
    # --recursive: Unterverzeichnisse durchsuchen
    # --move: Infizierte Dateien in Quarantäne verschieben
    clamscan \
        --infected \
        --recursive \
        --move="$QUARANTINE_DIR" \
        --log="$LOG_FILE" \
        "$target" 2>&1 | tee "$temp_result"
    
    local scan_exit_code=${PIPESTATUS[0]}
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    echo ""
    echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}"
    
    # Ergebnisse auswerten
    local scanned=$(grep -oP "Scanned files: \K\d+" "$temp_result" 2>/dev/null || echo "0")
    local infected=$(grep -oP "Infected files: \K\d+" "$temp_result" 2>/dev/null || echo "0")
    local data_scanned=$(grep -oP "Data scanned: \K[0-9.]+ MB" "$temp_result" 2>/dev/null || echo "unbekannt")

    echo ""
    echo -e "${BOLD}SCAN-ERGEBNIS${NC}"
    echo "─────────────────────────────────────"
    echo -e "Gescannte Dateien:  ${CYAN}$scanned${NC}"
    echo -e "Datenmenge:         ${CYAN}$data_scanned${NC}"
    echo -e "Scan-Dauer:         ${CYAN}$((duration / 60))m $((duration % 60))s${NC}"
    echo ""
    
    if [ "$infected" -gt 0 ] || [ $scan_exit_code -eq 1 ]; then
        echo -e "${RED}${BOLD}╔════════════════════════════════════════╗${NC}"
        echo -e "${RED}${BOLD}║  ⚠  BEDROHUNGEN GEFUNDEN: $infected              ║${NC}"
        echo -e "${RED}${BOLD}╚════════════════════════════════════════╝${NC}"
        echo ""
        print_warning "Infizierte Dateien wurden in Quarantäne verschoben:"
        print_warning "$QUARANTINE_DIR"
        echo ""
        print_error "USB-STICK NICHT VERWENDEN!"
        
        # Infizierte Dateien anzeigen
        echo ""
        echo -e "${BOLD}Gefundene Bedrohungen:${NC}"
        grep "FOUND" "$temp_result" | while read line; do
            print_threat "$line"
        done
        
        # Desktop-Benachrichtigung (falls verfügbar)
        notify-send -u critical "USB-Virenscanner" "⚠️ BEDROHUNG GEFUNDEN!\n$infected infizierte Datei(en)" 2>/dev/null || true
    else
        echo -e "${GREEN}${BOLD}╔════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}${BOLD}║  ✓  KEINE BEDROHUNGEN GEFUNDEN         ║${NC}"
        echo -e "${GREEN}${BOLD}╚════════════════════════════════════════╝${NC}"
        echo ""
        print_success "USB-Stick kann verwendet werden."
        
        # Desktop-Benachrichtigung
        notify-send -u normal "USB-Virenscanner" "✓ Scan abgeschlossen - keine Bedrohungen" 2>/dev/null || true
    fi
    
    echo ""
    echo -e "Log gespeichert: ${CYAN}$LOG_FILE${NC}"
    echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}"
    
    rm -f "$temp_result"
    
    return $scan_exit_code
}

# Interaktives Menü für USB-Auswahl
select_usb() {
    local usb_devices=()
    
    print_status "Suche USB-Geräte..." >&2
    
    # USB-Geräte sammeln
    while IFS= read -r device; do
        [ -n "$device" ] && usb_devices+=("$device")
    done < <(find_usb_devices)
    
    if [ ${#usb_devices[@]} -eq 0 ]; then
        print_warning "Keine USB-Geräte gefunden!" >&2
        echo "" >&2
        echo "Geprüfte Verzeichnisse:" >&2
        echo "  /media/*/" >&2
        ls -la /media/ >&2 2>/dev/null
        echo "" >&2
        echo "Bitte stellen Sie sicher, dass:" >&2
        echo "  1. Der USB-Stick eingesteckt ist" >&2
        echo "  2. Der USB-Stick gemountet ist" >&2
        echo "     (Im Dateimanager auf den USB-Stick klicken)" >&2
        echo "" >&2
        read -p "Pfad manuell eingeben (oder 'q' für zurück): " manual_path
        if [ -n "$manual_path" ] && [ "$manual_path" != "q" ] && [ -d "$manual_path" ]; then
            echo "$manual_path"
        fi
        return
    fi
    
    echo -e "${BOLD}Gefundene USB-Geräte:${NC}" >&2
    echo "" >&2
    
    local i=1
    for device in "${usb_devices[@]}"; do
        local size=$(df -h "$device" 2>/dev/null | tail -1 | awk '{print $2}')
        local used=$(df -h "$device" 2>/dev/null | tail -1 | awk '{print $5}')
        local label=$(basename "$device")
        echo -e "  ${CYAN}[$i]${NC} $label" >&2
        echo -e "      $device" >&2
        echo -e "      Größe: ${size}, Belegt: ${used}" >&2
        echo "" >&2
        ((i++))
    done
    
    if [ ${#usb_devices[@]} -gt 1 ]; then
        echo -e "  ${CYAN}[a]${NC} Alle USB-Geräte scannen" >&2
    fi
    echo -e "  ${CYAN}[m]${NC} Pfad manuell eingeben" >&2
    echo -e "  ${CYAN}[q]${NC} Zurück zum Hauptmenü" >&2
    echo "" >&2
    
    read -p "Auswahl: " choice
    
    # Leere Eingabe = zurück
    if [ -z "$choice" ]; then
        return
    fi
    
    case $choice in
        [1-9])
            if [ $choice -le ${#usb_devices[@]} ]; then
                echo "${usb_devices[$((choice-1))]}"
            else
                print_error "Ungültige Nummer" >&2
            fi
            ;;
        a|A)
            if [ ${#usb_devices[@]} -gt 1 ]; then
                printf '%s\n' "${usb_devices[@]}"
            fi
            ;;
        m|M)
            read -p "Pfad eingeben: " manual_path
            if [ -d "$manual_path" ]; then
                echo "$manual_path"
            else
                print_error "Pfad existiert nicht!" >&2
            fi
            ;;
        q|Q)
            return
            ;;
        *)
            print_error "Ungültige Auswahl" >&2
            ;;
    esac
}

# Quarantäne verwalten
manage_quarantine() {
    echo ""
    print_status "Quarantäne-Verzeichnis:"
    echo -e "${CYAN}$QUARANTINE_DIR${NC}"
    echo ""
    
    if [ "$(ls -A "$QUARANTINE_DIR" 2>/dev/null)" ]; then
        echo -e "${BOLD}Isolierte Dateien:${NC}"
        echo ""
        ls -lah "$QUARANTINE_DIR"
        echo ""
        echo -e "  ${CYAN}[1]${NC} Quarantäne leeren (Dateien löschen)"
        echo -e "  ${CYAN}[2]${NC} Ordner im Dateimanager öffnen"
        echo -e "  ${CYAN}[q]${NC} Zurück"
        echo ""
        read -p "Auswahl: " q_choice
        
        case $q_choice in
            1)
                echo ""
                print_warning "ACHTUNG: Alle isolierten Dateien werden gelöscht!"
                read -p "Wirklich löschen? (j/N): " confirm
                if [ "$confirm" = "j" ] || [ "$confirm" = "J" ]; then
                    rm -rf "$QUARANTINE_DIR"/*
                    print_success "Quarantäne geleert"
                else
                    print_status "Abgebrochen"
                fi
                ;;
            2)
                xdg-open "$QUARANTINE_DIR" 2>/dev/null || nautilus "$QUARANTINE_DIR" 2>/dev/null || true
                ;;
        esac
    else
        print_success "Quarantäne ist leer - keine isolierten Dateien"
    fi
}

# Logs anzeigen
show_logs() {
    echo ""
    print_status "Log-Verzeichnis:"
    echo -e "${CYAN}$LOG_DIR${NC}"
    echo ""
    
    local log_count=$(ls -1 "$LOG_DIR"/*.log 2>/dev/null | wc -l)
    
    if [ "$log_count" -gt 0 ]; then
        echo -e "${BOLD}Letzte Scans:${NC}"
        echo ""
        ls -lt "$LOG_DIR"/*.log 2>/dev/null | head -10 | while read line; do
            echo "  $line"
        done
        echo ""
        echo -e "  ${CYAN}[1]${NC} Letztes Log anzeigen"
        echo -e "  ${CYAN}[2]${NC} Ordner im Dateimanager öffnen"
        echo -e "  ${CYAN}[3]${NC} Alle Logs löschen"
        echo -e "  ${CYAN}[q]${NC} Zurück"
        echo ""
        read -p "Auswahl: " l_choice
        
        case $l_choice in
            1)
                local latest=$(ls -t "$LOG_DIR"/*.log 2>/dev/null | head -1)
                if [ -n "$latest" ]; then
                    echo ""
                    less "$latest"
                fi
                ;;
            2)
                xdg-open "$LOG_DIR" 2>/dev/null || nautilus "$LOG_DIR" 2>/dev/null || true
                ;;
            3)
                read -p "Alle Logs löschen? (j/N): " confirm
                if [ "$confirm" = "j" ] || [ "$confirm" = "J" ]; then
                    rm -f "$LOG_DIR"/*.log
                    print_success "Logs gelöscht"
                fi
                ;;
        esac
    else
        print_status "Noch keine Logs vorhanden"
    fi
}

# ============================================================================
# Hauptprogramm
# ============================================================================

main() {
    print_header
    
    # Signatur-Datum anzeigen
    local sig_date=$(check_signatures)
    print_status "Virensignaturen vom: $sig_date"
    echo ""
    
    # Menü
    echo -e "${BOLD}Was möchtest du tun?${NC}"
    echo ""
    echo -e "  ${CYAN}[1]${NC} 🔍  USB-Stick scannen"
    echo -e "  ${CYAN}[2]${NC} 🔄  Signaturen aktualisieren"
    echo -e "  ${CYAN}[3]${NC} 🗂️   Quarantäne verwalten"
    echo -e "  ${CYAN}[4]${NC} 📋  Scan-Logs anzeigen"
    echo -e "  ${CYAN}[q]${NC} 🚪  Beenden"
    echo ""
    
    read -p "Auswahl: " main_choice
    
    case $main_choice in
        1)
            echo ""
            local targets=$(select_usb)
            if [ -n "$targets" ]; then
                while IFS= read -r target; do
                    [ -n "$target" ] && perform_scan "$target"
                done <<< "$targets"
                echo ""
                read -p "Enter drücken zum Fortfahren..."
            fi
            main
            ;;
        2)
            echo ""
            update_signatures
            echo ""
            read -p "Enter drücken zum Fortfahren..."
            main
            ;;
        3)
            manage_quarantine
            echo ""
            read -p "Enter drücken zum Fortfahren..."
            main
            ;;
        4)
            show_logs
            echo ""
            read -p "Enter drücken zum Fortfahren..."
            main
            ;;
        q|Q)
            echo ""
            print_status "Auf Wiedersehen!"
            echo ""
            exit 0
            ;;
        *)
            print_error "Ungültige Auswahl"
            sleep 1
            main
            ;;
    esac
}

# Skript starten
main
