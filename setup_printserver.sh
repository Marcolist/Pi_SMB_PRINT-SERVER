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

cp "$(dirname "$0")/config/smb.conf" /etc/samba/smb.conf

# Samba neu starten
systemctl enable smbd nmbd
systemctl restart smbd nmbd

log "Samba konfiguriert und gestartet."

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

# ── 5. Watchfolder-Skript installieren ──────────────────────────────────────
log "Watchfolder wird installiert..."

cp "$(dirname "$0")/scripts/print-watchfolder.sh" "$INSTALL_DIR/print-watchfolder.sh"
chmod +x "$INSTALL_DIR/print-watchfolder.sh"

# systemd Service installieren
cp "$(dirname "$0")/systemd/print-watchfolder.service" /etc/systemd/system/
systemctl daemon-reload
systemctl enable print-watchfolder
systemctl start print-watchfolder

log "Watchfolder installiert und gestartet."

# ── 6. Web-Dashboard installieren ──────────────────────────────────────────
log "Web-Dashboard wird installiert..."

cp -r "$(dirname "$0")/dashboard/"* "$INSTALL_DIR/"

# Python Virtual Environment
python3 -m venv "$INSTALL_DIR/venv"
"$INSTALL_DIR/venv/bin/pip" install -q flask >> "$LOG_FILE" 2>&1

# systemd Service installieren
cp "$(dirname "$0")/systemd/printserver-dashboard.service" /etc/systemd/system/
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
echo "  Naechste Schritte:"
echo "  1. CUPS oeffnen und Drucker 'EcoTank-ET2820' hinzufuegen"
echo "  2. Auf dem NT 4.0 PC: Netzlaufwerk Z: -> \\\\${PI_IP}\\druckauftraege"
echo "  3. PDF nach Z:\\ kopieren → wird automatisch gedruckt"
echo ""
echo "============================================================================="
