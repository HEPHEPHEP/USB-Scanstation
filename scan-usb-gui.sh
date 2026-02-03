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

# Signatur-Alter in Tagen ermitteln
get_signature_age_days() {
    local sig_file=""
    if [ -f /var/lib/clamav/daily.cvd ]; then
        sig_file="/var/lib/clamav/daily.cvd"
    elif [ -f /var/lib/clamav/daily.cld ]; then
        sig_file="/var/lib/clamav/daily.cld"
    else
        echo "999"
        return
    fi
    
    # Datei-Änderungsdatum verwenden
    local file_date=$(stat -c %Y "$sig_file" 2>/dev/null || echo 0)
    local now=$(date +%s)
    local age_seconds=$((now - file_date))
    local age_days=$((age_seconds / 86400))
    echo "$age_days"
}

# Warnung anzeigen wenn Signaturen zu alt sind
check_signature_age() {
    local age_days=$(get_signature_age_days)
    local max_age=14
    
    if [ "$age_days" -ge "$max_age" ]; then
        zenity --warning \
            --title="⚠️ Veraltete Virensignaturen" \
            --text="<span font='14' color='#cc0000'><b>⚠️ Virensignaturen sind $age_days Tage alt!</b></span>\n\nDie Signaturen sollten maximal $max_age Tage alt sein.\n\nBitte aktualisiere die Signaturen vor dem Scan,\num optimalen Schutz zu gewährleisten.\n\n<b>Möchtest du trotzdem fortfahren?</b>" \
            --width=450 \
            --ok-label="Trotzdem scannen"
        
        return $?
    fi
    return 0
}

# Signaturen aktualisieren (ohne Passwort dank sudoers-Eintrag)
update_signatures() {
    (
        echo "10"
        echo "# Stoppe Freshclam-Dienst..."
        sudo systemctl stop clamav-freshclam 2>/dev/null
        
        echo "30"
        echo "# Lade Virensignaturen herunter..."
        sleep 1
        
        echo "50"
        sudo freshclam 2>&1
        
        echo "90"
        echo "# Starte Freshclam-Dienst..."
        sudo systemctl start clamav-freshclam 2>/dev/null
        
        echo "100"
        echo "# Fertig!"
    ) | zenity --progress \
        --title="Signaturen aktualisieren" \
        --text="Initialisiere..." \
        --percentage=0 \
        --auto-close \
        --no-cancel \
        --width=450
    
    local new_date=$(get_signature_date)
    zenity --info \
        --title="Update abgeschlossen" \
        --text="✓ Virensignaturen aktualisiert.\n\nAktueller Stand: $new_date" \
        --width=400
}

# Hauptscan mit GUI - pulsierender Fortschrittsbalken mit Abbruch-Option
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
    
    # Dateien zählen und Gesamtgröße ermitteln
    local total_files=$(find "$target" -type f 2>/dev/null | wc -l | tr -cd '0-9')
    total_files=${total_files:-1}
    [ "$total_files" -eq 0 ] && total_files=1
    local total_size_raw=$(du -sh "$target" 2>/dev/null | cut -f1)
    total_size_raw=${total_size_raw:-"unbekannt"}
    # Einheit formatieren: "139M" → "139 MB", "1,2G" → "1,2 GB"
    local total_size=$(echo "$total_size_raw" | sed 's/K$/ KB/;s/M$/ MB/;s/G$/ GB/;s/T$/ TB/')
    
    # Temporäre Dateien
    local temp_dir=$(mktemp -d)
    local temp_output="$temp_dir/output.txt"
    local temp_infected="$temp_dir/infected.txt"
    local scan_done="$temp_dir/done"
    local abort_scan="$temp_dir/abort"
    
    touch "$temp_output"

    # Scanner ermitteln und ins Log schreiben
    local scanner_used=""
    if clamdscan --ping 2>/dev/null; then
        scanner_used="clamdscan --multiscan (Multicore)"
    else
        scanner_used="clamscan (Single-Core)"
    fi
    echo "Scanner: $scanner_used" >> "$LOG_FILE"

    # Scan im Hintergrund starten
    # clamdscan --multiscan nutzt alle CPU-Kerne über den clamd-Daemon
    # Fallback auf single-threaded clamscan wenn clamd nicht läuft
    (
        if clamdscan --ping 2>/dev/null; then
            echo "Scanner: clamdscan --multiscan (Multicore)" > "$temp_output"
            clamdscan \
                --multiscan \
                --fdpass \
                --infected \
                --move="$QUARANTINE_DIR" \
                "$target" >> "$temp_output" 2>&1
        else
            echo "Scanner: clamscan (Single-Core)" > "$temp_output"
            clamscan \
                --infected \
                --recursive \
                --move="$QUARANTINE_DIR" \
                "$target" >> "$temp_output" 2>&1
        fi
        touch "$scan_done"
    ) &
    local scan_pid=$!
    
    # Fortschrittsfenster (pulsierend, mit Abbrechen-Button)
    local start_time=$(date +%s)
    (
        while [ ! -f "$scan_done" ]; do
            # Prüfe ob abgebrochen wurde
            if [ -f "$abort_scan" ]; then
                exit 1
            fi
            
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
                echo "# Scanne $total_files Dateien ($total_size)... | Laufzeit: ${minutes}m ${seconds}s"
            fi
            sleep 1
        done
        echo "# ✅ Scan abgeschlossen!"
    ) | zenity --progress \
        --title="🔍 Scanne: $target_name" \
        --text="Starte Scan..." \
        --pulsate \
        --auto-close \
        --width=500 \
        --height=100 \
        --cancel-label="Abbrechen"
    
    local zenity_exit=$?
    
    # Abbruch behandeln (zenity gibt 1 zurück bei Abbruch)
    if [ $zenity_exit -ne 0 ] && [ ! -f "$scan_done" ]; then
        touch "$abort_scan"
        kill $scan_pid 2>/dev/null
        wait $scan_pid 2>/dev/null
        
        zenity --warning \
            --title="Scan abgebrochen" \
            --text="Der Scan wurde abgebrochen.\n\nDer USB-Stick wurde nicht vollständig geprüft!" \
            --width=400
        
        rm -rf "$temp_dir"
        return
    fi
    
    # Auf Scan warten
    wait $scan_pid 2>/dev/null

    # Filesystem-Puffer auf USB synchronisieren (verhindert Korruption unter Windows)
    sync

    # Ergebnisse auswerten (sichere Zahlenextraktion)
    local scanned_files=$(grep -oP "Scanned files: \K\d+" "$temp_output" 2>/dev/null | tr -cd '0-9')
    local infected_count=$(grep -c "FOUND" "$temp_output" 2>/dev/null | tr -cd '0-9')
    local scan_time=$(grep -oP "Time: \K[0-9.]+ sec" "$temp_output" 2>/dev/null || echo "unbekannt")
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
            --text="<span font='18' color='#cc0000'><b>⚠️ $infected_count Bedrohung(en) gefunden!</b></span>\n\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n<b>Scan-Statistik:</b>\nGescannte Dateien: $scanned_files\nDatenmenge: $total_size\nScan-Zeit: $scan_time\n\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n<b>Infizierte Dateien in Quarantäne:</b>\n<span font='9'>$QUARANTINE_DIR</span>\n\n<b>Gefundene Bedrohungen:</b>\n${infected_details}\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n<span color='#cc0000'><b>⛔ USB-STICK NICHT VERWENDEN!</b></span>" \
            --width=550
        
        if zenity --question \
            --title="Quarantäne öffnen?" \
            --text="Möchtest du den Quarantäne-Ordner öffnen?" \
            --width=350; then
            xdg-open "$QUARANTINE_DIR" 2>/dev/null &
        fi
    else
        zenity --info \
            --title="✓ Scan abgeschlossen" \
            --text="<span font='18' color='#4e9a06'><b>✓ Keine Bedrohungen gefunden!</b></span>\n\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n<b>Scan-Statistik:</b>\nGescannte Dateien: $scanned_files\nDatenmenge: $total_size\nScan-Zeit: $scan_time\n\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n<span color='#4e9a06'><b>✓ USB-Stick kann sicher verwendet werden.</b></span>\n\n<span font='9' color='#555555'>Log: $LOG_FILE</span>" \
            --width=500
    fi
    
    # Sicheres Auswerfen anbieten
    offer_safe_eject "$target"

    # Aufräumen
    rm -rf "$temp_dir"
}

# USB-Stick sicher auswerfen
safe_eject() {
    local mountpoint="$1"
    sync
    # Block-Device für diesen Mountpoint ermitteln
    local block_device=$(findmnt -n -o SOURCE "$mountpoint" 2>/dev/null)
    if [ -n "$block_device" ]; then
        # udisksctl bevorzugen (Desktop-Integration)
        if command -v udisksctl &> /dev/null; then
            udisksctl unmount -b "$block_device" 2>/dev/null && \
            udisksctl power-off -b "$(lsblk -no PKNAME "$block_device" 2>/dev/null | head -1 | sed 's|^|/dev/|')" 2>/dev/null
        else
            umount "$mountpoint" 2>/dev/null
        fi
    fi
}

# Sicheres Auswerfen anbieten (nach Scan)
offer_safe_eject() {
    local mountpoint="$1"
    if [ -d "$mountpoint" ] && mountpoint -q "$mountpoint" 2>/dev/null; then
        if zenity --question \
            --title="USB-Stick auswerfen?" \
            --text="<b>Möchtest du den USB-Stick jetzt sicher auswerfen?</b>\n\nDas verhindert Dateisystem-Fehler unter Windows.\n\nMountpoint: $mountpoint" \
            --ok-label="Sicher auswerfen" \
            --cancel-label="Eingesteckt lassen" \
            --width=450; then
            if safe_eject "$mountpoint"; then
                zenity --info \
                    --title="USB-Stick ausgeworfen" \
                    --text="✓ Der USB-Stick wurde sicher ausgeworfen.\n\nDu kannst ihn jetzt abziehen." \
                    --width=350
            else
                zenity --warning \
                    --title="Auswerfen fehlgeschlagen" \
                    --text="Der USB-Stick konnte nicht ausgeworfen werden.\n\nBitte wirf ihn über den Dateimanager aus,\nbevor du ihn abziehst." \
                    --width=400
            fi
        fi
    fi
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
    local sig_age=$(get_signature_age_days)
    
    # Warnung wenn Signaturen zu alt
    local age_text="$sig_age Tage alt"
    if [ "$sig_age" -ge 14 ]; then
        age_text="<span color='#cc0000'><b>$sig_age Tage alt - Bitte aktualisieren!</b></span>"
    elif [ "$sig_age" -ge 7 ]; then
        age_text="<span color='#cc6600'>$sig_age Tage alt</span>"
    fi
    
    local choice=$(zenity --list \
        --title="USB-Virenscanner" \
        --text="<b><span font='14'>🛡️ USB-Virenscanner</span></b>\n\nVirensignaturen: $sig_date\nAlter: $age_text\n\nWas möchtest du tun?" \
        --column="" \
        --column="Aktion" \
        --hide-column=1 \
        "scan" "🔍  USB-Stick scannen" \
        "update" "🔄  Signaturen aktualisieren" \
        "quarantine" "🗂️   Quarantäne anzeigen" \
        "logs" "📋  Scan-Logs anzeigen" \
        --width=450 \
        --height=450 \
        --ok-label="Auswählen" \
        --cancel-label="Beenden")
    
    local exit_code=$?
    
    if [ $exit_code -ne 0 ] || [ -z "$choice" ]; then
        exit 0
    fi
    
    case $choice in
        scan)
            # Erst Signatur-Alter prüfen
            if ! check_signature_age; then
                # Benutzer hat abgebrochen
                main_menu
                return
            fi
            
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
        # Signatur-Alter prüfen
        if check_signature_age; then
            perform_scan_gui "$2"
        fi
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

if ! command -v clamscan &> /dev/null && ! command -v clamdscan &> /dev/null; then
    zenity --error \
        --title="ClamAV nicht gefunden" \
        --text="ClamAV ist nicht installiert.\n\nBitte führe zuerst das Setup aus:\nsudo bash setup.sh" \
        --width=400
    exit 1
fi

main_menu
