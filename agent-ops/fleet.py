#!/usr/bin/env python3
"""fleet.py — AI Agent Fleet dispatcher (Day 36)
3 endpoints → 3 skill files via Claude Code subprocess.

Usage:
  export DISCORD_WEBHOOK_URL='...'
  export REPO_ROOT='/path/to/proops2026-taskmanager'
  python3 agent-ops/fleet.py
"""

import hashlib
import http.server
import json
import os
import subprocess
import threading
import time

PORT      = 9999
DISCORD   = os.environ.get("DISCORD_WEBHOOK_URL", "")
REPO_ROOT = os.environ.get(
    "REPO_ROOT",
    os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
)
LOG_FILE   = os.path.join(os.path.dirname(__file__), "fleet.log")
WATCH_FILE = os.path.join(os.path.dirname(__file__), "state", "watch.jsonl")

ROUTES = {
    "/alert":           "triage-runtime-alert",
    "/ci-failed":       "triage-ci-failure",
    "/iac-plan-review": "review-iac-plan",
}

# Noise gate: {sha256_hash: [monotonic_timestamps]}
_gate_hits: dict = {}
_gate_lock = threading.Lock()
NOISE_WINDOW = 600  # 10 min rolling window
NOISE_LIMIT  = 3    # 3+ identical payloads → silence


def _is_noisy(raw: bytes) -> bool:
    key = hashlib.sha256(raw).hexdigest()
    now = time.monotonic()
    with _gate_lock:
        hits = [t for t in _gate_hits.get(key, []) if now - t < NOISE_WINDOW]
        hits.append(now)
        _gate_hits[key] = hits
        if len(hits) >= NOISE_LIMIT:
            _log(f"[noise-gated] hash={key[:12]} hits={len(hits)}")
            return True
    return False


def get_recent_watches(within_minutes: int = 30) -> list:
    cutoff = time.time() - (within_minutes * 60)
    if not os.path.exists(WATCH_FILE):
        return []
    entries = []
    with open(WATCH_FILE) as f:
        for line in f:
            try:
                entry = json.loads(line.strip())
                if entry.get("ts", 0) > cutoff:
                    entries.append(entry)
            except json.JSONDecodeError:
                pass
    return entries


def dispatch(skill: str, payload: dict):
    ph     = hashlib.sha256(json.dumps(payload).encode()).hexdigest()[:12]
    skill_path = os.path.join(REPO_ROOT, ".claude", "skills", f"{skill}.md")
    prompt = (
        f"Read the skill file at `{skill_path}` and follow its instructions exactly.\n\n"
        f"PAYLOAD (referred to as PAYLOAD in the skill):\n{json.dumps(payload, indent=2)}\n\n"
        "Execute every step in the skill file. Do not use the Skill tool — read the file directly."
    )
    proc = subprocess.Popen(
        ["claude", "-p", prompt, "--dangerously-skip-permissions"],
        cwd=REPO_ROOT,
        stdout=open(LOG_FILE, "a"),
        stderr=subprocess.STDOUT,
        env={**os.environ},
    )
    _log(f"[dispatch] skill={skill} hash={ph} pid={proc.pid}")


def _enrich_alert(payload: dict) -> dict:
    """Add DISCORD_WEBHOOK_URL + RUNBOOK_PATH into the Grafana payload before dispatch."""
    payload["DISCORD_WEBHOOK_URL"] = DISCORD
    for alert in payload.get("alerts", [payload]):
        url = alert.get("annotations", {}).get("runbook_url", "")
        if "/runbooks/" in url:
            fname = url.split("/runbooks/", 1)[1]
            alert["RUNBOOK_PATH"] = os.path.join(REPO_ROOT, "runbooks", fname)
    return payload


class FleetHandler(http.server.BaseHTTPRequestHandler):

    def log_message(self, fmt, *args): pass  # suppress default HTTP log

    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length", "0")))

        if self.path == "/watch":
            try:
                payload = json.loads(raw.decode("utf-8", errors="replace"))
                entry = {
                    "sha":       payload.get("sha", ""),
                    "reason":    payload.get("reason", ""),
                    "posted_by": payload.get("posted_by", ""),
                    "ts":        time.time(),
                }
                os.makedirs(os.path.dirname(WATCH_FILE), exist_ok=True)
                with open(WATCH_FILE, "a") as f:
                    f.write(json.dumps(entry) + "\n")
                _log(f"[watch] sha={entry['sha'][:8]} posted_by={entry['posted_by']}")
            except Exception as e:
                _log(f"[watch-error] {e}")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"ok": true}')
            return

        self.send_response(200)   # always ack — prevents GHA/Grafana retry loops
        self.end_headers()

        skill = ROUTES.get(self.path)
        if not skill:
            _log(f"[skip] unknown path: {self.path}")
            return
        if _is_noisy(raw):
            return

        try:
            payload = json.loads(raw.decode("utf-8", errors="replace"))
        except json.JSONDecodeError:
            _log(f"[error] non-JSON from {self.path}: {raw[:80]}")
            return

        if self.path == "/alert":
            payload = _enrich_alert(payload)

        threading.Thread(target=dispatch, args=(skill, payload), daemon=True).start()


def _log(msg: str):
    print(msg, flush=True)


def main():
    _log(f"[start] fleet.py listening on :{PORT}")
    _log(f"[start] REPO_ROOT = {REPO_ROOT}")
    _log(f"[start] Discord   = {'set' if DISCORD else 'NOT SET'}")
    _log(f"[start] Routes    = {list(ROUTES.keys())}")
    http.server.HTTPServer(("0.0.0.0", PORT), FleetHandler).serve_forever()


if __name__ == "__main__":
    main()
