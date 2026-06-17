#!/usr/bin/env python3
"""
investigator.py — AI Investigator webhook receiver
Listens for Grafana Cloud alert webhooks → invokes claude to triage.

Usage:
  export DISCORD_WEBHOOK_URL='https://discord.com/api/webhooks/...'
  export REPO_ROOT='/path/to/proops2026-taskmanager'
  python3 agent-ops/investigator.py

Dry run test:
  curl -X POST -H "Content-Type: application/json" \
    -d @agent-ops/sample-firing-alert.json \
    http://localhost:9999/
"""

import http.server
import json
import os
import subprocess
import sys
import threading

PORT = 9999
DISCORD_WEBHOOK_URL = os.environ.get("DISCORD_WEBHOOK_URL", "")
REPO_ROOT = os.environ.get(
    "REPO_ROOT",
    os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
)
LOG_FILE = os.path.join(os.path.dirname(__file__), "triage.log")

# Map runbook_url (GitHub URL) → local runbook path
# Convention: .../blob/main/runbooks/X.md  →  runbooks/X.md
def _runbook_url_to_path(url: str) -> str:
    if "/runbooks/" in url:
        filename = url.split("/runbooks/", 1)[1]
        return os.path.join(REPO_ROOT, "runbooks", filename)
    return ""


class TriageHandler(http.server.BaseHTTPRequestHandler):

    def log_message(self, fmt, *args):
        # Suppress default HTTP access log — we write our own
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length).decode("utf-8", errors="replace")

        # Acknowledge immediately so Grafana Cloud doesn't retry
        self.send_response(200)
        self.end_headers()

        try:
            payload = json.loads(raw)
        except json.JSONDecodeError:
            _log(f"[error] non-JSON body: {raw[:200]}")
            return

        # Grafana Cloud sends {"alerts": [...]} — one envelope, N alert objects
        alerts = payload.get("alerts", [payload])
        for alert in alerts:
            status = alert.get("status", "unknown")
            if status != "firing":
                _log(f"[skip] status={status} (only act on firing alerts)")
                continue
            # Handle each firing alert in its own thread so we return fast
            threading.Thread(
                target=self._handle_alert,
                args=(alert,),
                daemon=True
            ).start()

    def _handle_alert(self, alert: dict):
        labels = alert.get("labels", {})
        annotations = alert.get("annotations", {})

        summary = annotations.get("summary", labels.get("alertname", "Unknown alert"))
        runbook_url = annotations.get("runbook_url", "")
        runbook_path = _runbook_url_to_path(runbook_url)

        _log(f"\n[invoke] alert   : {summary}")
        _log(f"[invoke] runbook  : {runbook_path or '(none)'}")
        _log(f"[invoke] labels   : {json.dumps(labels)}")

        prompt = (
            "Run the triage-alert skill.\n\n"
            f"ALERT_PAYLOAD:\n{json.dumps(alert, indent=2)}\n\n"
            f"DISCORD_WEBHOOK_URL: {DISCORD_WEBHOOK_URL}\n\n"
            f"RUNBOOK_PATH: {runbook_path}\n\n"
            "Proceed step by step as described in the skill. Be concise."
        )

        try:
            result = subprocess.run(
                ["claude", "-p", prompt, "--dangerously-skip-permissions"],
                cwd=REPO_ROOT,
                capture_output=True,
                text=True,
                timeout=300,
                env={**os.environ}
            )
            output = result.stdout[:3000]
            _log("[claude stdout]")
            _log(output)
            if result.returncode != 0:
                _log(f"[claude stderr] {result.stderr[:500]}")

            # Append to persistent log file for review
            with open(LOG_FILE, "a") as f:
                f.write(f"\n{'='*60}\n")
                f.write(f"ALERT: {summary}\n")
                f.write(f"RUNBOOK: {runbook_path}\n")
                f.write(output)
                f.write("\n")

        except subprocess.TimeoutExpired:
            _log("[error] claude timed out after 5 min")
        except FileNotFoundError:
            _log("[error] 'claude' binary not found — is Claude Code installed?")


def _log(msg: str):
    print(msg, flush=True)


def main():
    if not DISCORD_WEBHOOK_URL:
        print("[warn] DISCORD_WEBHOOK_URL not set — Discord posts will fail")
    print(f"[start] AI Investigator listening on :{PORT}")
    print(f"[start] REPO_ROOT       : {REPO_ROOT}")
    print(f"[start] Discord webhook : {'set' if DISCORD_WEBHOOK_URL else 'NOT SET'}")
    print(f"[start] Log file        : {LOG_FILE}")
    print(f"[start] Skill file      : {REPO_ROOT}/.claude/skills/triage-alert.md")
    print()

    server = http.server.HTTPServer(("0.0.0.0", PORT), TriageHandler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n[stop] Investigator shut down")


if __name__ == "__main__":
    main()
