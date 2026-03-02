# PDF Print Server: Windows NT 4.0 → Raspberry Pi → Epson ET-2820

```
┌──────────────┐     SMB/CIFS      ┌──────────────┐     USB/WLAN     ┌──────────────┐
│  NT 4.0 PC   │ ──── PDF ──────→  │ Raspberry Pi │ ─────────────→  │  ET-2820     │
│  (Keysight   │   Netzfreigabe    │  (CUPS +     │   Druckdaten    │  (EcoTank)   │
│   VEE)       │                   │   Watchfolder)│                 │              │
└──────────────┘                   └──────────────┘                 └──────────────┘
```

## Voraussetzungen

- Raspberry Pi (3B+ oder neuer) mit Raspberry Pi OS
- Netzwerkverbindung zwischen NT-Rechner und Pi (LAN, gleiches Subnetz)
- Epson ET-2820 am Pi angeschlossen (USB empfohlen)

## Installation

```bash
# 1. Repository auf den Pi klonen/kopieren
git clone <repo-url> /home/pi/printserver
cd /home/pi/printserver

# 2. Setup ausfuehren
sudo bash setup_printserver.sh

# 3. CUPS Web-Interface oeffnen (von einem anderen PC)
#    https://<PI-IP>:631
#    Drucker hinzufuegen → Name: EcoTank-ET2820

# 4. Testen: PDF in die Freigabe kopieren
cp test.pdf /srv/samba/druckauftraege/
```

## Komponenten

| Komponente | Beschreibung |
|---|---|
| `setup_printserver.sh` | Hauptinstallationsskript |
| `config/smb.conf` | Samba-Konfiguration (NT 4.0 kompatibel) |
| `scripts/print-watchfolder.sh` | Ueberwacht Ordner und druckt PDFs automatisch |
| `dashboard/app.py` | Web-Dashboard (Flask) |
| `systemd/*.service` | systemd Service-Dateien |

## Web-Dashboard

Erreichbar unter `http://<PI-IP>:8080`

**Funktionen:**
- Live-Status von Drucker und Services
- Druckwarteschlange anzeigen/verwalten
- Dateien verwalten (wartend / gedruckt / fehlgeschlagen)
- Fehlgeschlagene Drucke erneut versuchen
- Services neu starten
- Live-Log-Ansicht

**API-Endpunkte:**
- `GET /api/status` — Gesamtstatus als JSON
- `GET /api/logs?lines=50` — Log-Eintraege
- `POST /api/printer/resume` — Drucker fortsetzen
- `POST /api/printer/pause` — Drucker anhalten
- `POST /api/printer/cancel-all` — Alle Auftraege abbrechen
- `POST /api/service/<name>/restart` — Service neu starten
- `POST /api/files/retry/<filename>` — Datei erneut drucken
- `POST /api/files/delete/<folder>/<filename>` — Datei loeschen

## Einrichtung auf dem NT 4.0 Rechner

### Netzlaufwerk verbinden

1. Explorer oeffnen
2. Extras → Netzlaufwerk verbinden
3. Laufwerk: `Z:`
4. Pfad: `\\<PI-IP>\druckauftraege`
5. "Verbindung bei Anmeldung wiederherstellen" aktivieren

### Drucken aus Keysight VEE

**Option A: PDF Export + Kopieren**
1. Diagramm als PDF exportieren (File → Print → PDF)
2. PDF nach `Z:\` kopieren
3. Pi druckt automatisch

**Option B: Batch-Datei**
```batch
@echo off
copy %1 Z:\
echo Druckauftrag gesendet.
pause
```
PDFs per Drag & Drop auf die .bat ziehen.

## Ordnerstruktur

```
\\<PI-IP>\druckauftraege\
  ├── (hier PDFs reinlegen)
  ├── gedruckt\        ← erfolgreich gedruckte Dateien
  └── fehler\          ← fehlgeschlagene Dateien
```

## Dienste verwalten

```bash
# Watchfolder
sudo systemctl status print-watchfolder
sudo systemctl restart print-watchfolder

# Dashboard
sudo systemctl status printserver-dashboard
sudo systemctl restart printserver-dashboard

# Samba
sudo systemctl restart smbd

# CUPS
sudo systemctl restart cups
```

## Troubleshooting

| Problem | Loesung |
|---|---|
| SMB-Freigabe nicht sichtbar | `server min protocol = NT1` gesetzt? Pi per IP ansprechen: `\\192.168.x.x\druckauftraege` |
| Druck kommt nicht | `sudo systemctl status print-watchfolder` pruefen |
| Drucker offline in CUPS | CUPS Web-Interface → Drucker → Resume |
| Berechtigung verweigert | `chmod -R 777 /srv/samba/druckauftraege` |
| Log ansehen | `tail -f /var/log/printserver.log` oder Dashboard → Logs |
| Dashboard nicht erreichbar | `sudo systemctl status printserver-dashboard` |

## NT 4.0 SMB-Kompatibilitaet

Die Samba-Konfiguration enthaelt bereits alle noetigen NT 4.0-Kompatibilitaetseinstellungen:
- NTLMv1 / LanMan Auth aktiviert
- NT1 Protokoll als Minimum
- WINS Support aktiviert
- Guest-Zugang fuer einfache Nutzung

Pi und NT-Rechner muessen im selben Subnetz sein.
