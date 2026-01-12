# USB-Virenscanner für Ubuntu Desktop

Offline-fähiger Virenscanner für USB-Sticks mit grafischer Oberfläche. Entwickelt für Scan-Stationen, die USB-Sticks vor der Nutzung im internen Netzwerk prüfen.

## Features

- **Grafische Oberfläche** - Einfache Bedienung per Mausklick
- **Automatische Erkennung** - Dialog erscheint beim Einstecken eines USB-Sticks
- **Pulsierender Fortschrittsbalken** - Mit Laufzeit-Anzeige und Abbrechen-Button
- **Quarantäne** - Infizierte Dateien werden automatisch isoliert
- **Offline-fähig** - Dateien verlassen den Rechner nicht
- **Tägliche Signatur-Updates** - Automatisch (Standard: 06:00 Uhr)
- **Automatische Systemupdates** - ClamAV und Sicherheitsupdates via unattended-upgrades
- **Alters-Warnung** - Warnung wenn Signaturen älter als 14 Tage sind
- **Passwortlose Updates** - Über sudoers-Konfiguration

## Installation

```bash
# Repository klonen oder Dateien herunterladen
git clone https://github.com/HEPHEPHEP/USB-Scanstation.git
cd USB-Scanstation

# Setup als root ausführen
sudo bash setup.sh
```

Das Setup installiert und konfiguriert automatisch:
- ClamAV (Virenscanner)
- Zenity (GUI-Dialoge)
- inotify-tools (USB-Erkennung)
- unattended-upgrades (automatische Systemupdates)
- Tägliches Signatur-Update um 06:00 Uhr
- Passwortlose Updates über sudoers

## Nutzung

### Manueller Scan
Doppelklick auf **USB-Scanner** auf dem Desktop.

### Automatischer Scan
Beim Einstecken eines USB-Sticks erscheint automatisch ein Dialog:
- **"Jetzt scannen"** → Scan mit Fortschrittsanzeige
- **"Überspringen"** → Kein Scan

### Signatur-Warnung
Wenn die Virensignaturen älter als 14 Tage sind, erscheint vor dem Scan eine Warnung.

### Scan abbrechen
Während des Scans kann über den **Abbrechen**-Button der Vorgang gestoppt werden.

## Nach der Installation

```
Schreibtisch/
├── USB-Scanner.desktop          ← Doppelklick zum Starten
└── USB-Virenscanner/
    ├── scan-usb-gui.sh          ← Haupt-Scanner (GUI)
    ├── scan-usb.sh              ← Terminal-Version (optional)
    ├── usb-watch-daemon.sh      ← Auto-Erkennung
    ├── Logs/                    ← Scan-Protokolle
    └── Quarantäne/              ← Isolierte Dateien
```

## Menü-Optionen

| Option | Beschreibung |
|--------|--------------|
| 🔍 USB-Stick scannen | USB-Stick auswählen und scannen |
| 🔄 Signaturen aktualisieren | Virensignaturen updaten (kein Passwort nötig) |
| 🗂️ Quarantäne anzeigen | Isolierte Dateien verwalten |
| 📋 Scan-Logs anzeigen | Vergangene Scans einsehen |

## Automatische Updates

Das Setup richtet zwei automatische Update-Mechanismen ein:

### 1. Virensignaturen (täglich 06:00 Uhr)
```bash
# Timer-Status prüfen
systemctl status clamav-update.timer

# Manuelles Update
sudo systemctl start clamav-update.service
```

### 2. Systemupdates (unattended-upgrades)
- Sicherheitsupdates werden automatisch installiert
- Inkl. ClamAV-Programmupdates
- Auto-Neustart um 03:00 Uhr falls nötig

```bash
# Status prüfen
sudo unattended-upgrade --dry-run

# Logs anzeigen
cat /var/log/unattended-upgrades/unattended-upgrades.log
```

## Auto-Scan verwalten

**Status prüfen:**
```bash
pgrep -f usb-watch-daemon && echo "Läuft" || echo "Gestoppt"
```

**Manuell starten:**
```bash
~/Schreibtisch/USB-Virenscanner/usb-watch-daemon.sh &
```

**Manuell stoppen:**
```bash
pkill -f usb-watch-daemon
```

**Dauerhaft deaktivieren:**
```bash
rm ~/.config/autostart/usb-scanner-watch.desktop
pkill -f usb-watch-daemon
```

## Fehlerbehebung

**"Defekte Desktop-Datei":**
```bash
chmod +x ~/Schreibtisch/USB-Scanner.desktop
gio set ~/Schreibtisch/USB-Scanner.desktop metadata::trusted true
```

**Auto-Scan erkennt USB-Stick nicht:**
```bash
# Daemon neu starten
pkill -f usb-watch-daemon
~/Schreibtisch/USB-Virenscanner/usb-watch-daemon.sh &

# Log prüfen
tail -f ~/Schreibtisch/USB-Virenscanner/Logs/daemon.log
```

**Signaturen-Update funktioniert nicht:**
```bash
# Manuell im Terminal
sudo freshclam

# Timer-Log prüfen
journalctl -u clamav-update.service
```

## Systemvoraussetzungen

- Ubuntu Desktop 20.04, 22.04, 24.04 oder neuer
- Internetverbindung für Signatur-Updates
- Ca. 500 MB Speicherplatz für ClamAV-Signaturen

## Vom Setup erstellte Systemdateien

| Datei | Beschreibung |
|-------|--------------|
| `/etc/sudoers.d/usb-scanner` | Erlaubt passwortloses freshclam |
| `/etc/systemd/system/clamav-update.service` | Update-Service |
| `/etc/systemd/system/clamav-update.timer` | Täglicher Timer (06:00 Uhr) |
| `/etc/apt/apt.conf.d/50unattended-upgrades` | Konfiguration Auto-Updates |
| `/etc/apt/apt.conf.d/20auto-upgrades` | Aktiviert Auto-Updates |

## Deinstallation

```bash
# Desktop-Dateien entfernen
rm -rf ~/Schreibtisch/USB-Virenscanner
rm ~/Schreibtisch/USB-Scanner.desktop
rm ~/.config/autostart/usb-scanner-watch.desktop

# Systemdateien entfernen (als root)
sudo rm /etc/sudoers.d/usb-scanner
sudo systemctl disable clamav-update.timer
sudo rm /etc/systemd/system/clamav-update.*
sudo systemctl daemon-reload

# Optional: Auto-Updates deaktivieren
sudo rm /etc/apt/apt.conf.d/50unattended-upgrades
sudo rm /etc/apt/apt.conf.d/20auto-upgrades

# Daemon stoppen
pkill -f usb-watch-daemon
```

## Enthaltene Dateien

| Datei | Beschreibung |
|-------|--------------|
| `setup.sh` | Installations-Skript |
| `scan-usb-gui.sh` | Scanner mit grafischer Oberfläche |
| `scan-usb.sh` | Scanner für Terminal (optional) |
| `usb-watch-daemon.sh` | Hintergrund-Dienst für Auto-Erkennung |
| `README.md` | Diese Dokumentation |

## Lizenz

Die Skripte sind frei verwendbar. ClamAV steht unter der GPL-Lizenz.
