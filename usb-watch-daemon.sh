#!/bin/bash
# ============================================================================
# USB Watch Daemon - Überwacht /media auf neue USB-Sticks
# Erkennt auch wenn USB-Sticks entfernt und wieder eingesteckt werden
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCANNER="$SCRIPT_DIR/scan-usb-gui.sh"
USER_MEDIA="/media/$(whoami)"

# Cleanup bei Beenden
cleanup() {
    echo "USB-Watch beendet."
    exit 0
}
trap cleanup EXIT INT TERM

# Warte bis /media/user existiert
while [ ! -d "$USER_MEDIA" ]; do
    mkdir -p "$USER_MEDIA" 2>/dev/null || true
    sleep 2
done

echo "USB-Watch gestartet. Überwache: $USER_MEDIA"

# Endlosschleife die auf neue Verzeichnisse wartet
while true; do
    # inotifywait wartet auf ein einzelnes Event und gibt es aus
    # Wenn ein USB-Stick eingesteckt wird, wird ein CREATE oder MOVED_TO Event ausgelöst
    EVENT=$(inotifywait -q -e create -e moved_to --format '%e %f' "$USER_MEDIA" 2>/dev/null)
    
    if [ -z "$EVENT" ]; then
        # inotifywait wurde unterbrochen, kurz warten und neu starten
        sleep 2
        continue
    fi
    
    # Event parsen
    EVENT_TYPE=$(echo "$EVENT" | awk '{print $1}')
    NEW_DIR=$(echo "$EVENT" | awk '{print $2}')
    MOUNT_POINT="$USER_MEDIA/$NEW_DIR"
    
    echo "Event erkannt: $EVENT_TYPE - $NEW_DIR"
    
    # Kurz warten bis vollständig gemountet
    sleep 3
    
    # Prüfen ob es ein gültiges Verzeichnis ist
    if [ -d "$MOUNT_POINT" ] && [ "$(ls -A "$MOUNT_POINT" 2>/dev/null)" ]; then
        echo "Neuer USB-Stick erkannt: $MOUNT_POINT"
        
        # Scan-Dialog anzeigen
        if zenity --question \
            --title="🔌 USB-Stick erkannt" \
            --text="Ein USB-Stick wurde eingesteckt:\n\n<b>$NEW_DIR</b>\n\nSoll dieser jetzt auf Viren gescannt werden?" \
            --width=420 \
            --ok-label="Jetzt scannen" \
            --cancel-label="Überspringen" 2>/dev/null; then
            
            echo "Starte Scan für: $MOUNT_POINT"
            "$SCANNER" --scan "$MOUNT_POINT"
        else
            echo "Scan übersprungen für: $MOUNT_POINT"
        fi
    fi
done
