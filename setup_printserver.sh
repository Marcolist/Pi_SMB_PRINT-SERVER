#!/bin/bash
# =============================================================================
# PDF Print Server Setup - Raspberry Pi
# Windows NT 4.0 → Raspberry Pi (CUPS + Watchfolder) → Epson ET-2820
# =============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

SAMBA_SHARE_PATH="/srv/samba/druckauftraege"
LOG_FILE="/var/log/printserver.log"
INSTALL_DIR="/opt/printserver"
DASHBOARD_PORT=8080
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

log() { echo -e "${GREEN}[SETUP]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# Root check
if [ "$EUID" -ne 0 ]; then
    error "Bitte als root ausfuehren: sudo bash $0"
fi

log "PDF Print Server Setup wird gestartet..."

# ── 1. System aktualisieren & Pakete installieren ──────────────────────────
log "Pakete werden installiert..."
apt-get update -qq
apt-get install -y -qq \
    samba \
    cups \
    cups-pdf \
    printer-driver-escpr \
    inotify-tools \
    python3 \
    python3-pip \
    python3-venv \
    poppler-utils \
    ghostscript \
    > /dev/null 2>&1

log "Pakete erfolgreich installiert."

# ── 2. Verzeichnisstruktur anlegen ─────────────────────────────────────────
log "Verzeichnisse werden erstellt..."
mkdir -p "$SAMBA_SHARE_PATH"
mkdir -p "$SAMBA_SHARE_PATH/gedruckt"
mkdir -p "$SAMBA_SHARE_PATH/fehler"
mkdir -p "$INSTALL_DIR"
mkdir -p /var/log

chmod -R 777 "$SAMBA_SHARE_PATH"
chown -R nobody:nogroup "$SAMBA_SHARE_PATH"

touch "$LOG_FILE"
chmod 666 "$LOG_FILE"

log "Verzeichnisse erstellt: $SAMBA_SHARE_PATH"

# ── 3. Samba konfigurieren (NT 4.0 kompatibel) ─────────────────────────────
log "Samba wird konfiguriert..."

# Backup der originalen Konfiguration
if [ -f /etc/samba/smb.conf ]; then
    cp /etc/samba/smb.conf /etc/samba/smb.conf.backup.$(date +%Y%m%d%H%M%S)
fi

cat > /etc/samba/smb.conf << 'SAMBAEOF'
# =============================================================================
# Samba Konfiguration - NT 4.0 kompatibel
# PDF Print Server fuer Keysight VEE → Epson ET-2820
# =============================================================================

[global]
   workgroup = WORKGROUP
   server string = PDF Print Server
   netbios name = PRINTSERVER

   # ── NT 4.0 Kompatibilitaet ──────────────────────────────────────────────
   server min protocol = NT1
   client min protocol = NT1
   ntlm auth = yes
   lanman auth = yes
   client lanman auth = yes
   client ntlmv2 auth = no
   raw NTLMv2 auth = yes

   # Alte Passwoerter erlauben
   encrypt passwords = yes
   passdb backend = tdbsam

   # ── Netzwerk ────────────────────────────────────────────────────────────
   interfaces = eth0
   bind interfaces only = no
   name resolve order = bcast host lmhosts wins

   # NetBIOS/WINS
   wins support = yes
   local master = yes
   preferred master = yes
   os level = 65

   # ── Sicherheit ──────────────────────────────────────────────────────────
   security = user
   map to guest = Bad User
   guest account = nobody

   # ── Logging ─────────────────────────────────────────────────────────────
   log file = /var/log/samba/log.%m
   max log size = 1000
   log level = 1

   # ── Drucken deaktivieren (wir nutzen CUPS direkt) ──────────────────────
   load printers = no
   printing = bsd
   printcap name = /dev/null
   disable spoolss = yes

# =============================================================================
# Druckauftraege-Freigabe (Hauptfreigabe fuer PDF-Dateien)
# =============================================================================
[druckauftraege]
   path = /srv/samba/druckauftraege
   comment = PDF Druckauftraege
   browseable = yes
   writable = yes
   guest ok = yes
   public = yes
   force user = nobody
   force group = nogroup
   create mask = 0666
   directory mask = 0777

   # Alte Clients unterstuetzen
   veto files = /._*/.DS_Store/
   delete veto files = yes
SAMBAEOF

# Samba-Konfiguration testen
log "Samba-Konfiguration wird geprueft..."
testparm -s /etc/samba/smb.conf > /dev/null 2>&1 || warn "smb.conf hat Warnungen - bitte manuell pruefen"

# Samba neu starten
systemctl enable smbd nmbd
systemctl restart smbd nmbd

log "Samba konfiguriert und gestartet."
log "LAN-Freigabe: \\\\$(hostname -I | awk '{print $1}')\\druckauftraege"

# ── 4. CUPS konfigurieren ──────────────────────────────────────────────────
log "CUPS wird konfiguriert..."

# CUPS auf Netzwerk-Zugriff einstellen
if [ -f /etc/cups/cupsd.conf ]; then
    cp /etc/cups/cupsd.conf /etc/cups/cupsd.conf.backup.$(date +%Y%m%d%H%M%S)
fi

cat > /etc/cups/cupsd.conf << 'CUPSEOF'
LogLevel warn
MaxLogSize 0
Listen localhost:631
Listen /run/cups/cups.sock

# Zugriff aus dem lokalen Netz erlauben
Port 631
Browsing On
BrowseLocalProtocols dnssd
DefaultAuthType Basic
WebInterface Yes

<Location />
  Order allow,deny
  Allow @LOCAL
</Location>

<Location /admin>
  Order allow,deny
  Allow @LOCAL
</Location>

<Location /admin/conf>
  AuthType Default
  Require user @SYSTEM
  Order allow,deny
  Allow @LOCAL
</Location>

<Policy default>
  JobPrivateAccess default
  JobPrivateValues default
  SubscriptionPrivateAccess default
  SubscriptionPrivateValues default

  <Limit Create-Job Print-Job Print-URI Validate-Job>
    Order deny,allow
  </Limit>

  <Limit Send-Document Send-URI Hold-Job Release-Job Restart-Job Purge-Jobs Set-Job-Attributes Create-Job-Subscription Renew-Subscription Cancel-Subscription Get-Notifications Reprocess-Job Cancel-Current-Job Suspend-Current-Job Resume-Job Cancel-My-Jobs Close-Job CUPS-Move-Job CUPS-Get-Document>
    Order deny,allow
  </Limit>

  <Limit CUPS-Add-Modify-Printer CUPS-Delete-Printer CUPS-Add-Modify-Class CUPS-Delete-Class CUPS-Set-Default CUPS-Get-Devices>
    AuthType Default
    Require user @SYSTEM
    Order deny,allow
  </Limit>

  <Limit Pause-Printer Resume-Printer Enable-Printer Disable-Printer Pause-Printer-After-Current-Job Hold-New-Jobs Release-Held-New-Jobs Deactivate-Printer Activate-Printer Restart-Printer Shutdown-Printer Startup-Printer Promote-Job Schedule-Job-After Cancel-Jobs CUPS-Accept-Jobs CUPS-Reject-Jobs>
    AuthType Default
    Require user @SYSTEM
    Order deny,allow
  </Limit>

  <Limit Cancel-Job CUPS-Authenticate-Job>
    Order deny,allow
  </Limit>

  <Limit All>
    Order deny,allow
  </Limit>
</Policy>
CUPSEOF

# Pi-User zur lpadmin-Gruppe hinzufuegen
usermod -aG lpadmin pi 2>/dev/null || true

systemctl enable cups
systemctl restart cups

log "CUPS konfiguriert. Web-Interface: https://<PI-IP>:631"

# ── 4b. Epson ET-2820 Drucker automatisch einrichten ────────────────────────
PRINTER_NAME="EcoTank-ET2820"
log "Drucker '$PRINTER_NAME' wird gesucht und eingerichtet..."

# Warten bis CUPS bereit ist
sleep 3

PRINTER_URI=""

# Methode 1: USB-Drucker suchen
log "Suche USB-Drucker..."
USB_URIS=$(lpinfo -v 2>/dev/null | grep -i "usb://" | grep -i -E "epson|et.2820" || true)
if [ -n "$USB_URIS" ]; then
    PRINTER_URI=$(echo "$USB_URIS" | head -1 | awk '{print $2}')
    log "USB-Drucker gefunden: $PRINTER_URI"
fi

# Methode 2: Netzwerk-Drucker suchen (falls kein USB)
if [ -z "$PRINTER_URI" ]; then
    log "Kein USB-Drucker gefunden, suche im Netzwerk..."
    NET_URIS=$(lpinfo -v 2>/dev/null | grep -i -E "dnssd://|socket://|ipp://" | grep -i -E "epson|et.2820" || true)
    if [ -n "$NET_URIS" ]; then
        PRINTER_URI=$(echo "$NET_URIS" | head -1 | awk '{print $2}')
        log "Netzwerk-Drucker gefunden: $PRINTER_URI"
    fi
fi

# Methode 3: Alle verfuegbaren Drucker anzeigen und generische USB-URI versuchen
if [ -z "$PRINTER_URI" ]; then
    log "Suche nach beliebigem Epson-Drucker..."
    ALL_EPSON=$(lpinfo -v 2>/dev/null | grep -i "epson" || true)
    if [ -n "$ALL_EPSON" ]; then
        PRINTER_URI=$(echo "$ALL_EPSON" | head -1 | awk '{print $2}')
        log "Epson-Drucker gefunden: $PRINTER_URI"
    fi
fi

if [ -n "$PRINTER_URI" ]; then
    # PPD/Treiber suchen
    PRINTER_PPD=""
    PPD_SEARCH=$(lpinfo -m 2>/dev/null | grep -i -E "et.2820|epson.*eco" || true)
    if [ -n "$PPD_SEARCH" ]; then
        PRINTER_PPD=$(echo "$PPD_SEARCH" | head -1 | awk '{print $1}')
        log "Treiber gefunden: $PRINTER_PPD"
    fi

    # Falls kein spezifischer Treiber, generischen Epson-Treiber verwenden
    if [ -z "$PRINTER_PPD" ]; then
        PPD_SEARCH=$(lpinfo -m 2>/dev/null | grep -i "epson.*inkjet" | head -1 || true)
        if [ -n "$PPD_SEARCH" ]; then
            PRINTER_PPD=$(echo "$PPD_SEARCH" | awk '{print $1}')
            log "Generischer Epson-Treiber: $PRINTER_PPD"
        fi
    fi

    # Drucker in CUPS hinzufuegen
    if [ -n "$PRINTER_PPD" ]; then
        lpadmin -p "$PRINTER_NAME" \
            -v "$PRINTER_URI" \
            -m "$PRINTER_PPD" \
            -L "Raspberry Pi Print Server" \
            -D "Epson ET-2820 EcoTank" \
            -E 2>/dev/null
    else
        # Ohne PPD (driverless/IPP Everywhere)
        lpadmin -p "$PRINTER_NAME" \
            -v "$PRINTER_URI" \
            -m everywhere \
            -L "Raspberry Pi Print Server" \
            -D "Epson ET-2820 EcoTank" \
            -E 2>/dev/null || \
        # Fallback: raw queue
        lpadmin -p "$PRINTER_NAME" \
            -v "$PRINTER_URI" \
            -L "Raspberry Pi Print Server" \
            -D "Epson ET-2820 EcoTank" \
            -E 2>/dev/null
    fi

    # Drucker aktivieren und als Standard setzen
    cupsenable "$PRINTER_NAME" 2>/dev/null || true
    accept "$PRINTER_NAME" 2>/dev/null || true
    lpadmin -d "$PRINTER_NAME" 2>/dev/null || true

    # Standardoptionen setzen (A4, Farbe)
    lpoptions -p "$PRINTER_NAME" -o media=iso_a4_210x297mm 2>/dev/null || true
    lpoptions -p "$PRINTER_NAME" -o ColorModel=Color 2>/dev/null || true

    log "Drucker '$PRINTER_NAME' erfolgreich eingerichtet und als Standard gesetzt!"
else
    warn "Kein Epson-Drucker erkannt."
    warn "Verfuegbare Geraete:"
    lpinfo -v 2>/dev/null | head -20 || true
    warn ""
    warn "Bitte Drucker manuell hinzufuegen:"
    warn "  1. CUPS oeffnen: https://$(hostname -I | awk '{print $1}'):631"
    warn "  2. Verwaltung → Drucker hinzufuegen"
    warn "  3. Name: $PRINTER_NAME"
fi

# ── 5. Watchfolder-Skript installieren ──────────────────────────────────────
log "Watchfolder wird installiert..."

# Watchfolder-Skript kopieren (aus scripts/ oder inline erzeugen)
if [ -f "$SCRIPT_DIR/scripts/print-watchfolder.sh" ]; then
    cp "$SCRIPT_DIR/scripts/print-watchfolder.sh" "$INSTALL_DIR/print-watchfolder.sh"
else
    warn "scripts/print-watchfolder.sh nicht gefunden - bitte manuell nach $INSTALL_DIR kopieren"
fi
chmod +x "$INSTALL_DIR/print-watchfolder.sh"

# systemd Service inline erzeugen
cat > /etc/systemd/system/print-watchfolder.service << 'WFEOF'
[Unit]
Description=PDF Print Watchfolder Service
After=network.target smbd.service cups.service
Wants=smbd.service cups.service

[Service]
Type=simple
ExecStart=/opt/printserver/print-watchfolder.sh
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
Environment=PRINTER_NAME=EcoTank-ET2820

[Install]
WantedBy=multi-user.target
WFEOF

systemctl daemon-reload
systemctl enable print-watchfolder
systemctl start print-watchfolder

log "Watchfolder installiert und gestartet."

# ── 6. Web-Dashboard installieren ──────────────────────────────────────────
log "Web-Dashboard wird installiert..."

# Dashboard-Dateien kopieren
if [ -d "$SCRIPT_DIR/dashboard" ]; then
    cp -r "$SCRIPT_DIR/dashboard/"* "$INSTALL_DIR/"
    log "Dashboard-Dateien kopiert."
else
    warn "dashboard/ Verzeichnis nicht gefunden - bitte manuell nach $INSTALL_DIR kopieren"
fi

# Python Virtual Environment
python3 -m venv "$INSTALL_DIR/venv"
"$INSTALL_DIR/venv/bin/pip" install -q flask >> "$LOG_FILE" 2>&1

# systemd Service inline erzeugen
cat > /etc/systemd/system/printserver-dashboard.service << 'DASHEOF'
[Unit]
Description=PDF Print Server Web Dashboard
After=network.target

[Service]
Type=simple
ExecStart=/opt/printserver/venv/bin/python3 /opt/printserver/app.py
WorkingDirectory=/opt/printserver
Restart=always
RestartSec=5
Environment=FLASK_ENV=production
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
DASHEOF

systemctl daemon-reload
systemctl enable printserver-dashboard
systemctl start printserver-dashboard

log "Dashboard installiert: http://<PI-IP>:$DASHBOARD_PORT"

# ── 7. Zusammenfassung ─────────────────────────────────────────────────────
PI_IP=$(hostname -I | awk '{print $1}')

echo ""
echo "============================================================================="
echo -e "${GREEN} PDF Print Server erfolgreich installiert!${NC}"
echo "============================================================================="
echo ""
echo "  SMB-Freigabe:   \\\\${PI_IP}\\druckauftraege"
echo "  CUPS:           https://${PI_IP}:631"
echo "  Dashboard:      http://${PI_IP}:${DASHBOARD_PORT}"
echo "  Log-Datei:      ${LOG_FILE}"
echo ""
echo "  Drucker:        $PRINTER_NAME ($(lpstat -p $PRINTER_NAME 2>/dev/null | head -1 || echo 'Status pruefen'))"
echo ""
echo "  Naechste Schritte:"
echo "  1. Auf dem NT 4.0 PC: Netzlaufwerk Z: -> \\\\${PI_IP}\\druckauftraege"
echo "  2. PDF nach Z:\\ kopieren → wird automatisch gedruckt"
echo "  3. Falls Drucker nicht erkannt: CUPS oeffnen und manuell hinzufuegen"
echo ""
echo "============================================================================="
