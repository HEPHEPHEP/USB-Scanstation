#!/bin/bash
# ============================================================================
# USB-Virenscanner Setup-Skript für Ubuntu Desktop (GUI Version)
# ============================================================================

set -e

echo "=========================================="
echo "  USB-Scan-Station Setup (GUI)"
echo "=========================================="
echo ""

# Root-Rechte prüfen
if [[ $EUID -ne 0 ]]; then
   echo "Dieses Skript muss als root ausgeführt werden:"
   echo "  sudo bash setup.sh"
   exit 1
fi

# Ursprünglichen Benutzer ermitteln
if [ -n "$SUDO_USER" ]; then
    REAL_USER="$SUDO_USER"
else
    REAL_USER="$(logname 2>/dev/null || echo $USER)"
fi
REAL_HOME=$(eval echo ~$REAL_USER)
REAL_UID=$(id -u "$REAL_USER")

# Desktop-Verzeichnis finden
if [ -d "$REAL_HOME/Schreibtisch" ]; then
    DESKTOP_DIR="$REAL_HOME/Schreibtisch"
elif [ -d "$REAL_HOME/Desktop" ]; then
    DESKTOP_DIR="$REAL_HOME/Desktop"
else
    DESKTOP_DIR=$(sudo -u "$REAL_USER" xdg-user-dir DESKTOP 2>/dev/null || echo "$REAL_HOME/Desktop")
    mkdir -p "$DESKTOP_DIR"
fi

INSTALL_DIR="$DESKTOP_DIR/USB-Virenscanner"

echo "Benutzer:     $REAL_USER"
echo "Desktop:      $DESKTOP_DIR"
echo "Installation: $INSTALL_DIR"
echo ""

echo "[1/7] System aktualisieren..."
apt update && apt upgrade -y

echo ""
echo "[2/7] ClamAV installieren..."
apt install -y clamav clamav-daemon clamav-freshclam

echo ""
echo "[3/7] GUI-Tools installieren..."
apt install -y zenity libnotify-bin inotify-tools

echo ""
echo "[4/7] Zusätzliche Tools installieren..."
apt install -y udisks2 ntfs-3g exfat-fuse policykit-1 coreutils

echo ""
echo "[5/7] Virensignaturen aktualisieren..."
systemctl stop clamav-freshclam 2>/dev/null || true
freshclam || true
systemctl enable clamav-freshclam
systemctl start clamav-freshclam

echo ""
echo "[6/7] Scanner auf Desktop einrichten..."

# Alte Installation stoppen
pkill -f "usb-watch-daemon" 2>/dev/null || true

# Zielverzeichnis erstellen
mkdir -p "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR/Logs"
mkdir -p "$INSTALL_DIR/Quarantäne"

# Skripte kopieren
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cp "$SCRIPT_DIR/scan-usb-gui.sh" "$INSTALL_DIR/"
cp "$SCRIPT_DIR/usb-watch-daemon.sh" "$INSTALL_DIR/"
cp "$SCRIPT_DIR/scan-usb.sh" "$INSTALL_DIR/" 2>/dev/null || true
chmod +x "$INSTALL_DIR"/*.sh

# Desktop-Verknüpfung erstellen
cat > "$INSTALL_DIR/USB-Scanner.desktop" << EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=USB-Virenscanner
Comment=USB-Stick auf Viren prüfen
Exec=$INSTALL_DIR/scan-usb-gui.sh
Icon=security-high
Terminal=false
Categories=System;Security;
StartupNotify=true
EOF

# Verknüpfung auf Desktop
cp "$INSTALL_DIR/USB-Scanner.desktop" "$DESKTOP_DIR/"

# Berechtigungen setzen
chown -R "$REAL_USER:$REAL_USER" "$INSTALL_DIR"
chown "$REAL_USER:$REAL_USER" "$DESKTOP_DIR/USB-Scanner.desktop"
chmod +x "$DESKTOP_DIR/USB-Scanner.desktop"
chmod +x "$INSTALL_DIR/USB-Scanner.desktop"

# Desktop-Datei als vertrauenswürdig markieren
sudo -u "$REAL_USER" gio set "$DESKTOP_DIR/USB-Scanner.desktop" metadata::trusted true 2>/dev/null || true

echo ""
echo "[7/7] Auto-Scan-Service einrichten..."

# Autostart-Eintrag für den Daemon erstellen
mkdir -p "$REAL_HOME/.config/autostart"
cat > "$REAL_HOME/.config/autostart/usb-scanner-watch.desktop" << EOF
[Desktop Entry]
Type=Application
Name=USB-Scanner Überwachung
Comment=Überwacht USB-Sticks beim Einstecken
Exec=$INSTALL_DIR/usb-watch-daemon.sh
Hidden=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
EOF
chown "$REAL_USER:$REAL_USER" "$REAL_HOME/.config/autostart/usb-scanner-watch.desktop"

# Daemon jetzt starten (für aktuelle Session)
echo "Starte USB-Watch-Daemon..."
sudo -u "$REAL_USER" bash -c "
    export DISPLAY=:0
    export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$REAL_UID/bus
    nohup '$INSTALL_DIR/usb-watch-daemon.sh' > '$INSTALL_DIR/Logs/daemon.log' 2>&1 &
"

# Kurz warten und prüfen ob Daemon läuft
sleep 2
if pgrep -f "usb-watch-daemon" > /dev/null; then
    echo "✓ USB-Watch-Daemon läuft"
else
    echo "⚠ Daemon konnte nicht gestartet werden (wird bei nächstem Login starten)"
fi

echo ""
echo "=========================================="
echo "  Setup abgeschlossen!"
echo "=========================================="
echo ""
echo "Auf deinem Desktop findest du jetzt:"
echo ""
echo "  🛡️  USB-Scanner.desktop      ← Doppelklick zum Starten"
echo ""
echo "  📁 USB-Virenscanner/"
echo "     ├── scan-usb-gui.sh       (GUI-Scanner)"
echo "     ├── usb-watch-daemon.sh   (Auto-Erkennung)"
echo "     ├── Logs/                 (Scan-Protokolle)"
echo "     └── Quarantäne/           (Isolierte Dateien)"
echo ""
echo "AUTO-SCAN: Beim Einstecken eines USB-Sticks erscheint"
echo "           automatisch ein Scan-Dialog."
echo "           Funktioniert auch nach Entfernen und erneutem Einstecken."
echo ""
