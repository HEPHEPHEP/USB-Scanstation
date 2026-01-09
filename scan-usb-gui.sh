#!/bin/bash
# ============================================================================
# USB-Virenscanner - GUI Version
# Grafische Oberfläche mit Zenity
# ============================================================================

# Pfad des Skripts ermitteln
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Konfiguration
LOG_DIR="$SCRIPT_DIR/Logs"
QUARANTINE_DIR="$SCRIPT_DIR/Quarantäne"
LOG_FILE="$LOG_DIR/scan_$(date +%Y%m%d_%H%M%S).log"

# Verzeichnisse erstellen
mkdir -p "$LOG_DIR" "$QUARANTINE_DIR"

# ============================================================================
# Funktionen
# ============================================================================

# USB-Geräte finden und als Liste formatieren
get_usb_list() {
    local devices=()
    
    # Über lsblk
    while IFS= read -r line; do
        local mountpoint=$(echo "$line" | awk '{print $3}')
        if [ -n "$mountpoint" ] && [ -d "$mountpoint" ]; then
            local size=$(df -h "$mountpoint" 2>/dev/null | tail -1 | awk '{print $2}')
            local label=$(basename "$mountpoint")
            devices+=("$mountpoint" "$label ($size)")
        fi
    done < <(lsblk -o NAME,TRAN,MOUNTPOINT,SIZE -p 2>/dev/null | grep -E "usb.*/")
    
    # In /media/ suchen
    local user=$(whoami)
    for dir in "/media/$user" "/run/media/$user"; do
        if [ -d "$dir" ]; then
            for device in "$dir"/*; do
                if [ -d "$device" ]; then
                    local already_added=false
                    for d in "${devices[@]}"; do
                        [ "$d" = "$device" ] && already_added=true
                    done
                    if [ "$already_added" = false ]; then
                        local size=$(df -h "$device" 2>/dev/null | tail -1 | awk '{print $2}')
                        local label=$(basename "$device")
                        devices+=("$device" "$label ($size)")
                    fi
                fi
            done
        fi
    done
    
    printf '%s\n' "${devices[@]}"
}

# Signatur-Datum ermitteln
get_signature_date() {
    local sig_date="unbekannt"
    if [ -f /var/lib/clamav/daily.cvd ]; then
        sig_date=$(sigtool --info /var/lib/clamav/daily.cvd 2>/dev/null | grep "Build time" | cut -d: -f2- | xargs)
    elif [ -f /var/lib/clamav/daily.cld ]; then
        sig_date=$(sigtool --info /var/lib/clamav/daily.cld 2>/dev/null | grep "Build time" | cut -d: -f2- | xargs)
    fi
    echo "$sig_date"
}

# Signaturen aktualisieren mit pkexec für grafische Passwort-Abfrage
update_signatures() {
    # Temporäres Update-Skript erstellen
    local update_script=$(mktemp)
    cat > "$update_script" << 'UPDATEEOF'
#!/bin/bash
systemctl stop clamav-freshclam 2>/dev/null || true
freshclam
systemctl start clamav-freshclam 2>/dev/null || true
UPDATEEOF
    chmod +x "$update_script"
    
    # Update mit pkexec ausführen (grafische Passwort-Abfrage)
    if pkexec bash "$update_script" 2>&1; then
        local new_date=$(get_signature_date)
        zenity --info \
            --title="Update abgeschlossen" \
            --text="✓ Virensignaturen erfolgreich aktualisiert.\n\nAktueller Stand: $new_date" \
            --width=400
    else
        zenity --error \
            --title="Update fehlgeschlagen" \
            --text="Das Update konnte nicht durchgeführt werden.\n\nMögliche Ursachen:\n• Passwort-Eingabe abgebrochen\n• Keine Internetverbindung\n• Signaturen bereits aktuell" \
            --width=400
    fi
    
    rm -f "$update_script"
}

# Hauptscan mit GUI - robuste Fortschrittsanzeige
perform_scan_gui() {
    local target="$1"
    local target_name=$(basename "$target")
    
    # Log initialisieren
    {
        echo "=========================================="
        echo "USB-Scan Log"
        echo "Ziel: $target"
        echo "Start: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "=========================================="
    } > "$LOG_FILE"
    
    # Dateien zählen für Fortschrittsberechnung (sichere Zahlenextraktion)
    local total_files=$(find "$target" -type f 2>/dev/null | wc -l | tr -cd '0-9')
    total_files=${total_files:-1}
    [ "$total_files" -eq 0 ] && total_files=1
    
    # Temporäre Dateien
    local temp_dir=$(mktemp -d)
    local temp_output="$temp_dir/output.txt"
    local temp_infected="$temp_dir/infected.txt"
    local scan_done="$temp_dir/done"
    
    touch "$temp_output"
    
    # Scan im Hintergrund starten
    (
        clamscan \
            --infected \
            --recursive \
            --move="$QUARANTINE_DIR" \
            "$target" > "$temp_output" 2>&1
        touch "$scan_done"
    ) &
    local scan_pid=$!
    
    # Fortschrittsfenster (pulsierend, da ClamAV keine Echtzeit-Ausgabe liefert)
    local start_time=$(date +%s)
    (
        while [ ! -f "$scan_done" ]; do
            elapsed=$(($(date +%s) - start_time))
            minutes=$((elapsed / 60))
            seconds=$((elapsed % 60))
            
            # Prüfe auf Bedrohungen in der bisherigen Ausgabe
            infected=$(grep -c "FOUND" "$temp_output" 2>/dev/null || echo 0)
            infected=$(echo "$infected" | tr -cd '0-9')
            infected=${infected:-0}
            
            if [ "$infected" -gt 0 ]; then
                echo "# ⚠️ $infected Bedrohung(en) gefunden! | Laufzeit: ${minutes}m ${seconds}s"
            else
                echo "# Scanne $total_files Dateien... | Laufzeit: ${minutes}m ${seconds}s"
            fi
            sleep 1
        done
        echo "# Scan abgeschlossen!"
    ) | zenity --progress \
        --title="🔍 Scanne: $target_name" \
        --text="Starte Scan..." \
        --pulsate \
        --auto-close \
        --no-cancel \
        --width=500 \
        --height=100
    
    # Auf Scan warten
    wait $scan_pid 2>/dev/null
    
    # Ergebnisse auswerten (sichere Zahlenextraktion)
    local scanned_files=$(grep -oP "Scanned files: \K\d+" "$temp_output" 2>/dev/null | tr -cd '0-9')
    local infected_count=$(grep -c "FOUND" "$temp_output" 2>/dev/null | tr -cd '0-9')
    local scan_time=$(grep -oP "Time: \K[0-9.]+ sec" "$temp_output" 2>/dev/null || echo "unbekannt")
    local data_scanned=$(grep -oP "Data scanned: \K[0-9.]+ MB" "$temp_output" 2>/dev/null || echo "unbekannt")
    
    # Standardwerte
    scanned_files=${scanned_files:-0}
    infected_count=${infected_count:-0}
    
    # Infizierte Dateien extrahieren
    grep "FOUND" "$temp_output" > "$temp_infected" 2>/dev/null || true
    
    # Log vervollständigen
    cat "$temp_output" >> "$LOG_FILE"
    
    # Ergebnisfenster
    if [ "$infected_count" -gt 0 ]; then
        local infected_details=""
        while IFS= read -r line; do
            local filename=$(echo "$line" | cut -d: -f1 | xargs basename 2>/dev/null)
            local virus=$(echo "$line" | grep -oP "[A-Za-z0-9._-]+(?= FOUND)" 2>/dev/null)
            infected_details="${infected_details}• ${filename}\n   Virus: ${virus}\n\n"
        done < "$temp_infected"
        
        zenity --error \
            --title="⚠️ BEDROHUNGEN GEFUNDEN" \
            --text="<span font='18' color='#cc0000'><b>⚠️ $infected_count Bedrohung(en) gefunden!</b></span>\n\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n<b>Scan-Statistik:</b>\nGescannte Dateien: $scanned_files\nDatenmenge: $data_scanned\nScan-Zeit: $scan_time\n\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n<b>Infizierte Dateien in Quarantäne:</b>\n<span font='9'>$QUARANTINE_DIR</span>\n\n<b>Gefundene Bedrohungen:</b>\n${infected_details}\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n<span color='#cc0000'><b>⛔ USB-STICK NICHT VERWENDEN!</b></span>" \
            --width=550
        
        notify-send -u critical "USB-Virenscanner" "⚠️ $infected_count Bedrohung(en) gefunden!" 2>/dev/null || true
        
        if zenity --question \
            --title="Quarantäne öffnen?" \
            --text="Möchtest du den Quarantäne-Ordner öffnen?" \
            --width=350; then
            xdg-open "$QUARANTINE_DIR" 2>/dev/null &
        fi
    else
        zenity --info \
            --title="✓ Scan abgeschlossen" \
            --text="<span font='18' color='#4e9a06'><b>✓ Keine Bedrohungen gefunden!</b></span>\n\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n<b>Scan-Statistik:</b>\nGescannte Dateien: $scanned_files\nDatenmenge: $data_scanned\nScan-Zeit: $scan_time\n\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n<span color='#4e9a06'><b>✓ USB-Stick kann sicher verwendet werden.</b></span>\n\n<span font='9' color='#555555'>Log: $LOG_FILE</span>" \
            --width=500
        
        notify-send -u normal "USB-Virenscanner" "✓ Keine Bedrohungen gefunden" 2>/dev/null || true
    fi
    
    # Aufräumen
    rm -rf "$temp_dir"
}

# Quarantäne-Dialog
show_quarantine() {
    local files=$(ls -1 "$QUARANTINE_DIR" 2>/dev/null)
    
    if [ -z "$files" ]; then
        zenity --info \
            --title="Quarantäne" \
            --text="Die Quarantäne ist leer.\n\nKeine isolierten Dateien vorhanden." \
            --width=350
        return
    fi
    
    local file_count=$(echo "$files" | wc -l)
    local choice=$(zenity --list \
        --title="Quarantäne - $file_count Datei(en)" \
        --text="Isolierte Dateien:" \
        --column="Dateiname" \
        $files \
        --width=550 \
        --height=450 \
        --extra-button="Ordner öffnen" \
        --extra-button="Alle löschen")
    
    if [ "$choice" = "Ordner öffnen" ]; then
        xdg-open "$QUARANTINE_DIR" 2>/dev/null &
    elif [ "$choice" = "Alle löschen" ]; then
        if zenity --question \
            --title="Quarantäne leeren" \
            --text="<b>Achtung!</b>\n\nAlle $file_count isolierten Dateien werden endgültig gelöscht.\n\nFortfahren?" \
            --width=400; then
            rm -rf "$QUARANTINE_DIR"/*
            zenity --info --title="Erledigt" --text="Quarantäne wurde geleert." --width=300
        fi
    fi
}

# Logs-Dialog
show_logs() {
    local logs=$(ls -1t "$LOG_DIR"/*.log 2>/dev/null | head -20)
    
    if [ -z "$logs" ]; then
        zenity --info \
            --title="Scan-Logs" \
            --text="Noch keine Logs vorhanden." \
            --width=300
        return
    fi
    
    local log_entries=""
    while IFS= read -r log; do
        local name=$(basename "$log")
        local date=$(echo "$name" | grep -oP '\d{8}_\d{6}' | sed 's/\([0-9]\{4\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)_\([0-9]\{2\}\)\([0-9]\{2\}\)/\1-\2-\3 \4:\5/')
        log_entries="$log_entries $log $date"
    done <<< "$logs"
    
    local selected=$(zenity --list \
        --title="Scan-Logs" \
        --text="Wähle ein Log zum Anzeigen:" \
        --column="Pfad" \
        --column="Datum" \
        $log_entries \
        --width=650 \
        --height=450 \
        --print-column=1 \
        --extra-button="Ordner öffnen")
    
    local exit_code=$?
    
    if [ $exit_code -eq 0 ] && [ -n "$selected" ] && [ -f "$selected" ]; then
        zenity --text-info \
            --title="Log: $(basename "$selected")" \
            --filename="$selected" \
            --width=750 \
            --height=550 \
            --font="monospace"
    elif [ "$selected" = "Ordner öffnen" ]; then
        xdg-open "$LOG_DIR" 2>/dev/null &
    fi
}

# ============================================================================
# Hauptmenü
# ============================================================================

main_menu() {
    local sig_date=$(get_signature_date)
    
    local choice=$(zenity --list \
        --title="USB-Virenscanner" \
        --text="<b><span font='14'>🛡️ USB-Virenscanner</span></b>\n\nVirensignaturen: $sig_date\n\nWas möchtest du tun?" \
        --column="" \
        --column="Aktion" \
        --hide-column=1 \
        "scan" "🔍  USB-Stick scannen" \
        "update" "🔄  Signaturen aktualisieren" \
        "quarantine" "🗂️   Quarantäne anzeigen" \
        "logs" "📋  Scan-Logs anzeigen" \
        --width=450 \
        --height=420 \
        --ok-label="Auswählen" \
        --cancel-label="Beenden")
    
    local exit_code=$?
    
    if [ $exit_code -ne 0 ] || [ -z "$choice" ]; then
        exit 0
    fi
    
    case $choice in
        scan)
            local usb_list=$(get_usb_list)
            
            if [ -z "$usb_list" ]; then
                zenity --warning \
                    --title="Kein USB-Gerät gefunden" \
                    --text="Es wurde kein USB-Stick gefunden.\n\n<b>Bitte stelle sicher, dass:</b>\n• Der USB-Stick eingesteckt ist\n• Der USB-Stick gemountet ist\n  (im Dateimanager anklicken)\n\nKlicke OK um einen Ordner manuell auszuwählen." \
                    --width=450
                
                local manual_path=$(zenity --file-selection \
                    --directory \
                    --title="Ordner zum Scannen auswählen")
                
                if [ -n "$manual_path" ] && [ -d "$manual_path" ]; then
                    perform_scan_gui "$manual_path"
                fi
            else
                local selected=$(zenity --list \
                    --title="USB-Stick auswählen" \
                    --text="Welchen USB-Stick möchtest du scannen?" \
                    --column="Pfad" \
                    --column="Beschreibung" \
                    $usb_list \
                    --width=550 \
                    --height=400 \
                    --print-column=1 \
                    --ok-label="Scannen" \
                    --cancel-label="Abbrechen" \
                    --extra-button="Anderen Ordner...")
                
                local sel_exit=$?
                
                if [ "$selected" = "Anderen Ordner..." ]; then
                    local manual_path=$(zenity --file-selection \
                        --directory \
                        --title="Ordner zum Scannen auswählen")
                    [ -n "$manual_path" ] && [ -d "$manual_path" ] && perform_scan_gui "$manual_path"
                elif [ $sel_exit -eq 0 ] && [ -n "$selected" ] && [ -d "$selected" ]; then
                    perform_scan_gui "$selected"
                fi
            fi
            ;;
        update)
            update_signatures
            ;;
        quarantine)
            show_quarantine
            ;;
        logs)
            show_logs
            ;;
    esac
    
    main_menu
}

# ============================================================================
# Start
# ============================================================================

# Kommandozeilenargumente
if [ "$1" = "--scan" ] && [ -n "$2" ]; then
    if [ -d "$2" ]; then
        perform_scan_gui "$2"
    else
        zenity --error \
            --title="Fehler" \
            --text="Pfad nicht gefunden: $2" \
            --width=350
    fi
    exit 0
fi

# Prüfungen
if ! command -v zenity &> /dev/null; then
    echo "Fehler: Zenity ist nicht installiert."
    exit 1
fi

if ! command -v clamscan &> /dev/null; then
    zenity --error \
        --title="ClamAV nicht gefunden" \
        --text="ClamAV ist nicht installiert.\n\nBitte führe zuerst das Setup aus:\nsudo bash setup.sh" \
        --width=400
    exit 1
fi

main_menu
