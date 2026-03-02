#!/usr/bin/env python3
"""
PDF Print Server - Web Dashboard
Steuert und ueberwacht den Druckserver per Browser.
"""

import os
import subprocess
import glob
import json
from datetime import datetime
from pathlib import Path

from flask import Flask, render_template, jsonify, request, redirect, url_for

app = Flask(__name__)

WATCH_DIR = "/srv/samba/druckauftraege"
DONE_DIR = os.path.join(WATCH_DIR, "gedruckt")
FAIL_DIR = os.path.join(WATCH_DIR, "fehler")
LOG_FILE = "/var/log/printserver.log"
PRINTER_NAME = os.environ.get("PRINTER_NAME", "EcoTank-ET2820")


def run_cmd(cmd, timeout=10):
    """Shell-Befehl ausfuehren und Ausgabe zurueckgeben."""
    try:
        result = subprocess.run(
            cmd, shell=True, capture_output=True, text=True, timeout=timeout
        )
        return result.stdout.strip()
    except (subprocess.TimeoutExpired, Exception):
        return ""


def get_printer_status():
    """CUPS Druckerstatus abfragen."""
    output = run_cmd(f"lpstat -p {PRINTER_NAME} 2>/dev/null")
    if not output:
        return {"name": PRINTER_NAME, "status": "Nicht gefunden", "ok": False}

    if "idle" in output.lower():
        return {"name": PRINTER_NAME, "status": "Bereit", "ok": True}
    elif "printing" in output.lower():
        return {"name": PRINTER_NAME, "status": "Druckt...", "ok": True}
    elif "disabled" in output.lower() or "stopped" in output.lower():
        return {"name": PRINTER_NAME, "status": "Angehalten", "ok": False}
    else:
        return {"name": PRINTER_NAME, "status": output, "ok": True}


def get_service_status(service_name):
    """systemd Service-Status abfragen."""
    output = run_cmd(f"systemctl is-active {service_name} 2>/dev/null")
    return output == "active"


def get_queue():
    """CUPS Druckwarteschlange abfragen."""
    output = run_cmd("lpstat -o 2>/dev/null")
    if not output:
        return []
    jobs = []
    for line in output.strip().split("\n"):
        if line.strip():
            jobs.append(line.strip())
    return jobs


def get_queue_detailed():
    """Detaillierte Druckwarteschlange mit Job-IDs."""
    output = run_cmd("lpstat -o -l 2>/dev/null")
    if not output:
        return []
    jobs = []
    current = {}
    for line in output.strip().split("\n"):
        line = line.strip()
        if not line:
            continue
        # Neue Job-Zeile: "EcoTank-ET2820-123 user 1024 ..."
        parts = line.split()
        if parts and "-" in parts[0] and not line.startswith(" "):
            if current:
                jobs.append(current)
            job_id = parts[0]
            current = {
                "id": job_id,
                "raw": line,
                "job_number": job_id.rsplit("-", 1)[-1] if "-" in job_id else job_id,
            }
        elif current:
            current["raw"] += " " + line
    if current:
        jobs.append(current)
    return jobs


def get_all_printers():
    """Alle in CUPS konfigurierten Drucker auflisten."""
    output = run_cmd("lpstat -p -d 2>/dev/null")
    if not output:
        return [], None
    printers = []
    default = None
    for line in output.strip().split("\n"):
        line = line.strip()
        if line.startswith("printer "):
            parts = line.split()
            name = parts[1] if len(parts) > 1 else "?"
            status = "Bereit" if "idle" in line.lower() else (
                "Druckt" if "printing" in line.lower() else (
                    "Angehalten" if "disabled" in line.lower() else "Unbekannt"
                )
            )
            ok = "disabled" not in line.lower() and "stopped" not in line.lower()
            printers.append({"name": name, "status": status, "ok": ok, "raw": line})
        elif line.startswith("system default destination:"):
            default = line.split(":")[-1].strip()
    return printers, default


def get_printer_details(name):
    """Detaillierte Druckerinfo via lpoptions."""
    info = {"name": name, "options": {}, "uri": "", "make": ""}

    # URI und Modell
    output = run_cmd(f"lpstat -v {name} 2>/dev/null")
    if output:
        info["uri"] = output.split(":", 1)[-1].strip() if ":" in output else output

    # Optionen
    output = run_cmd(f"lpoptions -p {name} -l 2>/dev/null")
    if output:
        for line in output.strip().split("\n"):
            if "/" in line and ":" in line:
                key_part, val_part = line.split(":", 1)
                opt_key = key_part.split("/")[0].strip()
                opt_label = key_part.split("/")[1].strip() if "/" in key_part else opt_key
                choices = val_part.strip().split()
                current = None
                options = []
                for c in choices:
                    if c.startswith("*"):
                        current = c[1:]
                        options.append(c[1:])
                    else:
                        options.append(c)
                info["options"][opt_key] = {
                    "label": opt_label,
                    "current": current,
                    "choices": options,
                }
    return info


def get_completed_jobs(limit=20):
    """Abgeschlossene CUPS-Jobs auflisten."""
    output = run_cmd(f"lpstat -W completed -o 2>/dev/null")
    if not output:
        return []
    jobs = []
    for line in output.strip().split("\n"):
        if line.strip():
            jobs.append(line.strip())
    return jobs[:limit]


def list_files(directory, limit=50):
    """Dateien in einem Verzeichnis auflisten."""
    files = []
    if not os.path.isdir(directory):
        return files
    for entry in sorted(
        Path(directory).iterdir(), key=lambda p: p.stat().st_mtime, reverse=True
    ):
        if entry.is_file() and not entry.name.startswith("."):
            stat = entry.stat()
            files.append({
                "name": entry.name,
                "size": stat.st_size,
                "size_human": format_size(stat.st_size),
                "modified": datetime.fromtimestamp(stat.st_mtime).strftime(
                    "%Y-%m-%d %H:%M:%S"
                ),
            })
            if len(files) >= limit:
                break
    return files


def format_size(size_bytes):
    """Bytes in lesbares Format umwandeln."""
    for unit in ["B", "KB", "MB", "GB"]:
        if size_bytes < 1024:
            return f"{size_bytes:.1f} {unit}"
        size_bytes /= 1024
    return f"{size_bytes:.1f} TB"


def read_log(lines=100):
    """Letzte Zeilen der Log-Datei lesen."""
    if not os.path.isfile(LOG_FILE):
        return []
    try:
        output = run_cmd(f"tail -n {lines} {LOG_FILE}")
        return output.split("\n") if output else []
    except Exception:
        return []


def get_stats():
    """Statistiken zusammenstellen."""
    pending = len(glob.glob(os.path.join(WATCH_DIR, "*.pdf")))
    pending += len(glob.glob(os.path.join(WATCH_DIR, "*.PDF")))
    done = len(list(Path(DONE_DIR).glob("*"))) if os.path.isdir(DONE_DIR) else 0
    failed = len(list(Path(FAIL_DIR).glob("*"))) if os.path.isdir(FAIL_DIR) else 0
    return {"pending": pending, "done": done, "failed": failed}


# ── Routes ──────────────────────────────────────────────────────────────────


@app.route("/")
def index():
    """Hauptseite / Dashboard."""
    printer = get_printer_status()
    stats = get_stats()
    queue = get_queue()
    services = {
        "watchfolder": get_service_status("print-watchfolder"),
        "dashboard": True,
        "samba": get_service_status("smbd"),
        "cups": get_service_status("cups"),
    }
    return render_template(
        "index.html",
        printer=printer,
        stats=stats,
        queue=queue,
        services=services,
    )


@app.route("/files")
def files():
    """Dateiuebersicht."""
    pending = list_files(WATCH_DIR)
    done = list_files(DONE_DIR)
    failed = list_files(FAIL_DIR)
    return render_template(
        "files.html", pending=pending, done=done, failed=failed
    )


@app.route("/cups")
def cups():
    """CUPS Verwaltungsseite."""
    printers, default_printer = get_all_printers()
    details = get_printer_details(PRINTER_NAME)
    queue = get_queue_detailed()
    completed = get_completed_jobs()
    return render_template(
        "cups.html",
        printers=printers,
        default_printer=default_printer,
        details=details,
        queue=queue,
        completed=completed,
        printer_name=PRINTER_NAME,
    )


@app.route("/logs")
def logs():
    """Log-Ansicht."""
    log_lines = read_log(200)
    return render_template("logs.html", log_lines=log_lines)


@app.route("/api/status")
def api_status():
    """JSON API: Gesamtstatus."""
    return jsonify({
        "printer": get_printer_status(),
        "stats": get_stats(),
        "queue": get_queue(),
        "services": {
            "watchfolder": get_service_status("print-watchfolder"),
            "samba": get_service_status("smbd"),
            "cups": get_service_status("cups"),
        },
    })


@app.route("/api/logs")
def api_logs():
    """JSON API: Logs."""
    lines = request.args.get("lines", 50, type=int)
    return jsonify({"logs": read_log(lines)})


@app.route("/api/printer/resume", methods=["POST"])
def printer_resume():
    """Drucker fortsetzen (CUPS enable)."""
    run_cmd(f"cupsenable {PRINTER_NAME}")
    run_cmd(f"accept {PRINTER_NAME}")
    return jsonify({"ok": True, "message": "Drucker fortgesetzt"})


@app.route("/api/printer/pause", methods=["POST"])
def printer_pause():
    """Drucker anhalten."""
    run_cmd(f"cupsdisable {PRINTER_NAME}")
    return jsonify({"ok": True, "message": "Drucker angehalten"})


@app.route("/api/printer/cancel-all", methods=["POST"])
def printer_cancel_all():
    """Alle Druckauftraege abbrechen."""
    run_cmd(f"cancel -a {PRINTER_NAME}")
    return jsonify({"ok": True, "message": "Alle Auftraege abgebrochen"})


@app.route("/api/printer/test", methods=["POST"])
def printer_test():
    """CUPS Testseite drucken."""
    output = run_cmd(f"lp -d {PRINTER_NAME} /usr/share/cups/data/testprint 2>&1")
    if not output:
        output = run_cmd(f"lp -d {PRINTER_NAME} /usr/share/doc/cups/images/cups-icon.png 2>&1")
    if "request id" in output.lower() or output:
        return jsonify({"ok": True, "message": f"Testdruck gesendet: {output}"})
    return jsonify({"ok": False, "message": "Testdruck fehlgeschlagen"})


@app.route("/api/printer/set-default/<name>", methods=["POST"])
def printer_set_default(name):
    """Drucker als Standard setzen."""
    safe_name = os.path.basename(name)
    run_cmd(f"lpadmin -d {safe_name}")
    return jsonify({"ok": True, "message": f"{safe_name} als Standard gesetzt"})


@app.route("/api/job/cancel/<job_id>", methods=["POST"])
def job_cancel(job_id):
    """Einzelnen Druckauftrag abbrechen."""
    safe_id = os.path.basename(job_id)
    run_cmd(f"cancel {safe_id}")
    return jsonify({"ok": True, "message": f"Auftrag {safe_id} abgebrochen"})


@app.route("/api/job/hold/<job_id>", methods=["POST"])
def job_hold(job_id):
    """Druckauftrag anhalten."""
    safe_id = os.path.basename(job_id)
    run_cmd(f"lp -i {safe_id} -H hold")
    return jsonify({"ok": True, "message": f"Auftrag {safe_id} angehalten"})


@app.route("/api/job/release/<job_id>", methods=["POST"])
def job_release(job_id):
    """Angehaltenen Druckauftrag fortsetzen."""
    safe_id = os.path.basename(job_id)
    run_cmd(f"lp -i {safe_id} -H resume")
    return jsonify({"ok": True, "message": f"Auftrag {safe_id} fortgesetzt"})


@app.route("/api/printer/option", methods=["POST"])
def printer_set_option():
    """Druckeroption setzen."""
    data = request.get_json()
    if not data or "key" not in data or "value" not in data:
        return jsonify({"ok": False, "message": "key und value erforderlich"}), 400
    key = data["key"].replace(" ", "").replace(";", "")
    value = data["value"].replace(" ", "").replace(";", "")
    run_cmd(f"lpoptions -p {PRINTER_NAME} -o {key}={value}")
    return jsonify({"ok": True, "message": f"{key}={value} gesetzt"})


@app.route("/api/service/<name>/restart", methods=["POST"])
def service_restart(name):
    """Service neu starten."""
    allowed = ["print-watchfolder", "smbd", "cups"]
    if name not in allowed:
        return jsonify({"ok": False, "message": "Service nicht erlaubt"}), 400
    run_cmd(f"systemctl restart {name}")
    return jsonify({"ok": True, "message": f"{name} neu gestartet"})


@app.route("/api/files/retry/<filename>", methods=["POST"])
def retry_file(filename):
    """Fehlgeschlagene Datei erneut versuchen."""
    safe_name = os.path.basename(filename)
    src = os.path.join(FAIL_DIR, safe_name)
    dst = os.path.join(WATCH_DIR, safe_name)
    if os.path.isfile(src):
        os.rename(src, dst)
        return jsonify({"ok": True, "message": f"{safe_name} erneut eingereiht"})
    return jsonify({"ok": False, "message": "Datei nicht gefunden"}), 404


@app.route("/api/files/delete/<folder>/<filename>", methods=["POST"])
def delete_file(folder, filename):
    """Datei loeschen."""
    folder_map = {"gedruckt": DONE_DIR, "fehler": FAIL_DIR}
    if folder not in folder_map:
        return jsonify({"ok": False, "message": "Ordner nicht erlaubt"}), 400
    safe_name = os.path.basename(filename)
    filepath = os.path.join(folder_map[folder], safe_name)
    if os.path.isfile(filepath):
        os.remove(filepath)
        return jsonify({"ok": True, "message": f"{safe_name} geloescht"})
    return jsonify({"ok": False, "message": "Datei nicht gefunden"}), 404


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080, debug=False)
