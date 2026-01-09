# USB-Virenscanner für Ubuntu Desktop

Offline-fähiger Virenscanner für USB-Sticks mit grafischer Oberfläche. Entwickelt für Scan-Stationen, die USB-Sticks vor der Nutzung im internen Netzwerk prüfen.

## Features

- **Grafische Oberfläche** - Einfache Bedienung per Mausklick
- **Automatische Erkennung** - Dialog erscheint beim Einstecken eines USB-Sticks
- **Fortschrittsanzeige** - Pulsierender Balken mit Laufzeit-Anzeige
- **Quarantäne** - Infizierte Dateien werden automatisch isoliert
- **Offline-fähig** - Dateien verlassen den Rechner nicht
- **Signatur-Updates** - Grafische Passwort-Abfrage für Updates

## Installation

```bash
# Dateien in einen Ordner entpacken
cd ~/Downloads/usb-scanner-gui

# Setup als root ausführen
sudo bash setup.sh
```

Das Setup installiert automatisch:
- ClamAV (Virenscanner)
- Zenity (GUI-Dialoge)
- inotify-tools (USB-Erkennung)
- Weitere Abhängigkeiten

## Nutzung

### Manueller Scan
Doppelklick auf **USB-Scanner** auf dem Desktop.

### Automatischer Scan
Beim Einstecken eines USB-Sticks erscheint automatisch ein Dialog:
- **"Jetzt scannen"** → Scan mit Fortschrittsanzeige
- **"Überspringen"** → Kein Scan

Funktioniert auch nach Entfernen und erneutem Einstecken.

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
| 🔄 Signaturen aktualisieren | Virensignaturen updaten (Passwort erforderlich) |
| 🗂️ Quarantäne anzeigen | Isolierte Dateien verwalten |
| 📋 Scan-Logs anzeigen | Vergangene Scans einsehen |

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
```

## Systemvoraussetzungen

- Ubuntu Desktop 20.04, 22.04, 24.04 oder neuer
- Internetverbindung für Signatur-Updates
- Ca. 500 MB Speicherplatz für ClamAV-Signaturen

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
