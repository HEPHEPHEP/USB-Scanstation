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

echo "[1/8] System aktualisieren..."
apt update && apt upgrade -y

echo ""
echo "[2/8] ClamAV installieren..."
apt install -y clamav clamav-daemon clamav-freshclam

echo ""
echo "[3/8] GUI-Tools installieren..."
apt install -y zenity inotify-tools

echo ""
echo "[4/9] Zusätzliche Tools installieren..."
apt install -y udisks2 ntfs-3g exfat-fuse coreutils

echo ""
echo "[5/9] Automatische Sicherheitsupdates einrichten..."
apt install -y unattended-upgrades

# Konfiguration für unattended-upgrades
cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}";
    "${distro_id}:${distro_codename}-security";
    "${distro_id}:${distro_codename}-updates";
};

// Automatisch ungenutzte Abhängigkeiten entfernen
Unattended-Upgrade::Remove-Unused-Dependencies "true";

// Automatisch neu starten wenn nötig (nachts um 3 Uhr)
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "03:00";
EOF

# Auto-Updates aktivieren
cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
EOF

echo "✓ Automatische Sicherheitsupdates aktiviert"

echo ""
echo "[6/9] Virensignaturen aktualisieren & ClamAV-Daemon einrichten..."
systemctl stop clamav-freshclam 2>/dev/null || true
freshclam || true
systemctl enable clamav-freshclam
systemctl start clamav-freshclam

# clamd-Daemon aktivieren (ermöglicht Multicore-Scanning mit clamdscan --multiscan)
echo "Aktiviere ClamAV-Daemon für Multicore-Scanning..."
systemctl stop clamav-daemon 2>/dev/null || true
systemctl enable clamav-daemon
systemctl start clamav-daemon

# Benutzer zur clamav-Gruppe hinzufügen (für Socket-Zugriff)
if ! groups "$REAL_USER" | grep -q '\bclamav\b'; then
    usermod -aG clamav "$REAL_USER"
    echo "✓ Benutzer '$REAL_USER' zur clamav-Gruppe hinzugefügt"
    echo "  (Neuanmeldung erforderlich für volle Multicore-Unterstützung)"
fi

# Warten bis clamd bereit ist (lädt Signaturen in den Speicher)
echo -n "Warte auf clamd..."
for i in $(seq 1 30); do
    if clamdscan --ping 1 2>/dev/null; then
        echo " bereit!"
        break
    fi
    echo -n "."
    sleep 2
done
echo ""
echo "✓ ClamAV-Daemon aktiviert (Multicore-Scanning verfügbar)"

echo ""
echo "[7/9] Scanner auf Desktop einrichten..."

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
echo "[8/9] Auto-Scan-Service einrichten..."

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
echo "[9/9] Tägliches Signatur-Update einrichten..."

# sudoers-Eintrag für passwortloses freshclam
SUDOERS_FILE="/etc/sudoers.d/usb-scanner"
cat > "$SUDOERS_FILE" << EOF
# USB-Virenscanner: Erlaubt freshclam und clamav-freshclam ohne Passwort
$REAL_USER ALL=(root) NOPASSWD: /usr/bin/freshclam
$REAL_USER ALL=(root) NOPASSWD: /usr/bin/systemctl stop clamav-freshclam
$REAL_USER ALL=(root) NOPASSWD: /usr/bin/systemctl start clamav-freshclam
EOF
chmod 440 "$SUDOERS_FILE"
echo "✓ sudoers-Eintrag erstellt: $SUDOERS_FILE"

# systemd-Timer für tägliches Update erstellen
cat > /etc/systemd/system/clamav-update.service << EOF
[Unit]
Description=ClamAV Signatur-Update
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStartPre=/usr/bin/systemctl stop clamav-freshclam
ExecStart=/usr/bin/freshclam --quiet
ExecStartPost=/usr/bin/systemctl start clamav-freshclam
EOF

cat > /etc/systemd/system/clamav-update.timer << EOF
[Unit]
Description=Tägliches ClamAV Signatur-Update

[Timer]
OnCalendar=*-*-* 06:00:00
RandomizedDelaySec=180
Persistent=true

[Install]
WantedBy=timers.target
EOF

# Timer aktivieren
systemctl daemon-reload
systemctl enable clamav-update.timer
systemctl start clamav-update.timer

echo "✓ Täglicher Update-Timer aktiviert (täglich um 06:00 Uhr)"

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
echo "AUTOMATISCHE UPDATES:"
echo "  • Virensignaturen: täglich um 06:00 Uhr"
echo "  • Systemupdates:   täglich (Sicherheitsupdates)"
echo "  • Auto-Neustart:   03:00 Uhr falls nötig"
echo ""
echo "AUTO-SCAN:"
echo "  • Dialog erscheint beim Einstecken eines USB-Sticks"
echo "  • Warnung wenn Signaturen älter als 14 Tage"
echo ""
