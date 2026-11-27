#!/usr/bin/env python3
"""
Serveur HTTP local léger (127.0.0.1:8888) pour l'écran de démarrage du Photo Stand.

Affiche en temps réel :
- L'avancement des services systemd (photostand-sync-repos, photostand-compose, docker)
- L'état de chaque conteneur Docker (postgres, rabbitmq, minio, job-svc, ingest-svc, frontend, print-vm...)
- Les dernières lignes de logs de build / démarrage
- Ne redirige Firefox vers le frontend qu'une fois que :
    1) le frontend répond HTTP 200
    2) job-svc répond HTTP 200 sur /health ET /photos?limit=1 (garantit Postgres + RabbitMQ + S3 + bucket prêts, zéro écran gris!)
"""

import http.server
import json
import os
import subprocess
import urllib.error
import urllib.request
from urllib.parse import urlparse

BIND_HOST = os.environ.get("BOOT_STATUS_HOST", "127.0.0.1")
BIND_PORT = int(os.environ.get("BOOT_STATUS_PORT", "8888"))
DEFAULT_FRONTEND_URL = os.environ.get("FRONTEND_URL", "http://127.0.0.1")
DEFAULT_API_URL = os.environ.get("API_URL", "http://127.0.0.1:8080")


def resolve_urls():
    frontend_url = DEFAULT_FRONTEND_URL
    api_url = DEFAULT_API_URL
    try:
        with open("/proc/cmdline", "r", encoding="utf-8") as f:
            tokens = f.read().split()
        profiles = ""
        primary_ip = ""
        for token in tokens:
            if token.startswith("stand.profiles="):
                profiles = token.split("=", 1)[1]
            elif token.startswith("stand.primary_ip="):
                primary_ip = token.split("=", 1)[1]
        if profiles and "primary" not in profiles.split(",") and primary_ip:
            frontend_url = f"http://{primary_ip}"
            api_url = f"http://{primary_ip}:8080"
    except OSError:
        pass
    return frontend_url.rstrip("/"), api_url.rstrip("/")


def http_check(url: str, timeout: float = 1.5) -> tuple[bool, str]:
    try:
        req = urllib.request.Request(url, method="GET")
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            ok = 200 <= resp.status < 400
            return ok, f"HTTP {resp.status}"
    except urllib.error.HTTPError as err:
        return False, f"HTTP {err.code}"
    except Exception as exc:
        return False, str(exc.__class__.__name__)


def systemd_state(unit: str) -> dict:
    try:
        out = subprocess.check_output(
            [
                "systemctl",
                "show",
                unit,
                "--property=ActiveState,SubState,Result",
            ],
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=2,
        )
        props = {}
        for line in out.splitlines():
            if "=" in line:
                k, v = line.split("=", 1)
                props[k] = v
        active = props.get("ActiveState", "unknown")
        sub = props.get("SubState", "")
        result = props.get("Result", "")
        return {"active": active, "sub": sub, "result": result}
    except Exception:
        return {"active": "unknown", "sub": "", "result": ""}


def docker_containers() -> list[dict]:
    try:
        out = subprocess.check_output(
            ["docker", "ps", "-a", "--format", "{{json .}}"],
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=2,
        )
        items = []
        for line in out.splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                data = json.loads(line)
                items.append(
                    {
                        "name": data.get("Names", ""),
                        "state": data.get("State", ""),
                        "status": data.get("Status", ""),
                    }
                )
            except json.JSONDecodeError:
                continue
        items.sort(key=lambda c: c["name"])
        return items
    except Exception:
        return []


def recent_logs(units: list[str], lines: int = 8) -> list[str]:
    cmd = ["journalctl", "-b", "--no-pager", "-n", str(lines), "-o", "cat"]
    for u in units:
        cmd.extend(["-u", u])
    try:
        out = subprocess.check_output(cmd, stderr=subprocess.DEVNULL, text=True, timeout=2)
        return [ln for ln in out.splitlines() if ln.strip()][-lines:]
    except Exception:
        return []


def collect_status() -> dict:
    frontend_url, api_url = resolve_urls()

    sync_svc = systemd_state("photostand-sync-repos.service")
    docker_svc = systemd_state("docker.service")
    compose_svc = systemd_state("photostand-compose.service")

    fe_ok, fe_detail = http_check(f"{frontend_url}/")
    api_health_ok, api_health_detail = http_check(f"{api_url}/health")
    api_photos_ok, api_photos_detail = (
        http_check(f"{api_url}/photos?limit=1") if api_health_ok else (False, "en attente")
    )

    containers = docker_containers()
    logs = recent_logs(
        ["photostand-sync-repos.service", "photostand-compose.service"], lines=8
    )

    # Le frontend React ne peut charger sans erreur (écran gris) que lorsque :
    # - Nginx sert le frontend (HTTP 200)
    # - job-svc répond 200 sur /health ET /photos?limit=1 (Postgres + RabbitMQ + S3 + bucket OK)
    ready = fe_ok and api_health_ok and api_photos_ok

    # Résumé lisible de l'étape en cours
    if ready:
        current_step = "Tous les services sont prêts ! Ouverture du Photo Stand..."
    elif sync_svc["active"] == "activating":
        current_step = "Synchronisation des dépôts Git (stand-infra, frontend, services)..."
    elif sync_svc["active"] == "failed":
        current_step = "Erreur lors de la synchronisation Git (photostand-sync-repos)"
    elif docker_svc["active"] != "active":
        current_step = "Démarrage du daemon Docker..."
    elif compose_svc["active"] == "activating":
        current_step = "Construction et démarrage des conteneurs Docker Compose..."
    elif compose_svc["active"] == "failed":
        current_step = "Erreur lors du démarrage Docker Compose (photostand-compose)"
    elif not fe_ok:
        current_step = "Attente du serveur web Frontend..."
    elif not api_health_ok:
        current_step = "Démarrage de job-svc (migrations PostgreSQL & RabbitMQ)..."
    elif not api_photos_ok:
        current_step = "Initialisation du stockage S3 (bucket photostand)..."
    else:
        current_step = "Démarrage des services en cours..."

    steps = [
        {
            "label": "Synchronisation des dépôts Git",
            "state": (
                "done"
                if sync_svc["active"] == "active"
                else "error"
                if sync_svc["active"] == "failed"
                else "running"
                if sync_svc["active"] == "activating"
                else "waiting"
            ),
            "detail": sync_svc["active"],
        },
        {
            "label": "Daemon Docker",
            "state": "done" if docker_svc["active"] == "active" else "running",
            "detail": docker_svc["active"],
        },
        {
            "label": "Build & lancement Docker Compose",
            "state": (
                "done"
                if compose_svc["active"] == "active"
                else "error"
                if compose_svc["active"] == "failed"
                else "running"
                if compose_svc["active"] == "activating"
                else "waiting"
            ),
            "detail": compose_svc["active"],
        },
        {
            "label": f"Frontend ({frontend_url})",
            "state": "done" if fe_ok else "waiting",
            "detail": fe_detail,
        },
        {
            "label": f"API job-svc + Base & S3 ({api_url}/photos)",
            "state": "done" if (api_health_ok and api_photos_ok) else ("running" if api_health_ok else "waiting"),
            "detail": api_photos_detail if api_health_ok else api_health_detail,
        },
    ]

    return {
        "ready": ready,
        "targetUrl": frontend_url,
        "currentStep": current_step,
        "steps": steps,
        "containers": containers,
        "logs": logs,
    }


HTML_PAGE = """<!doctype html>
<html lang="fr">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>Photo Stand — Démarrage</title>
    <style>
      :root {
        --bg: #0f1117;
        --card: #181b24;
        --border: #272b38;
        --text: #f4f4f5;
        --muted: #a1a1aa;
        --green: #22c55e;
        --blue: #3b82f6;
        --red: #ef4444;
        --amber: #f59e0b;
      }
      * { box-sizing: border-box; }
      body {
        margin: 0;
        min-height: 100vh;
        background: var(--bg);
        color: var(--text);
        font-family: system-ui, -apple-system, "Segoe UI", sans-serif;
        display: flex;
        align-items: center;
        justify-content: center;
        padding: 24px;
      }
      .wrap {
        width: 100%;
        max-width: 820px;
        display: flex;
        flex-direction: column;
        gap: 16px;
      }
      .header {
        display: flex;
        align-items: center;
        gap: 16px;
      }
      .spinner {
        width: 34px;
        height: 34px;
        border: 3px solid var(--border);
        border-top-color: var(--blue);
        border-radius: 50%;
        animation: spin 0.9s linear infinite;
        flex-shrink: 0;
      }
      .spinner.ready {
        border-color: var(--green);
        animation: none;
      }
      @keyframes spin { to { transform: rotate(360deg); } }
      h1 { margin: 0; font-size: 22px; }
      .subtitle { margin: 4px 0 0; color: var(--muted); font-size: 14px; }
      .card {
        background: var(--card);
        border: 1px solid var(--border);
        border-radius: 12px;
        padding: 16px 18px;
      }
      .card h2 {
        margin: 0 0 12px;
        font-size: 13px;
        text-transform: uppercase;
        letter-spacing: 0.06em;
        color: var(--muted);
      }
      .list { display: flex; flex-direction: column; gap: 8px; }
      .row {
        display: flex;
        align-items: center;
        justify-content: space-between;
        gap: 12px;
        font-size: 14px;
      }
      .left { display: flex; align-items: center; gap: 10px; }
      .dot {
        width: 10px;
        height: 10px;
        border-radius: 50%;
        background: #52525b;
        flex-shrink: 0;
      }
      .dot.done { background: var(--green); }
      .dot.running { background: var(--blue); box-shadow: 0 0 8px var(--blue); }
      .dot.error { background: var(--red); }
      .dot.waiting { background: #52525b; }
      .badge {
        font-size: 12px;
        color: var(--muted);
        font-family: ui-monospace, "JetBrains Mono", monospace;
      }
      .grid {
        display: grid;
        grid-template-columns: repeat(auto-fill, minmax(230px, 1fr));
        gap: 8px;
      }
      .chip {
        background: #12151d;
        border: 1px solid var(--border);
        border-radius: 8px;
        padding: 8px 10px;
        display: flex;
        flex-direction: column;
        gap: 3px;
      }
      .chip-head {
        display: flex;
        align-items: center;
        gap: 8px;
        font-weight: 600;
        font-size: 13px;
      }
      .chip-sub {
        font-size: 11px;
        color: var(--muted);
        font-family: ui-monospace, "JetBrains Mono", monospace;
        white-space: nowrap;
        overflow: hidden;
        text-overflow: ellipsis;
      }
      .logs {
        margin: 0;
        background: #0b0d12;
        border: 1px solid var(--border);
        border-radius: 8px;
        padding: 10px 12px;
        font-family: ui-monospace, "JetBrains Mono", monospace;
        font-size: 12px;
        line-height: 1.45;
        color: #d4d4d8;
        max-height: 170px;
        overflow-y: auto;
        white-space: pre-wrap;
        word-break: break-word;
      }
      .footer {
        display: flex;
        justify-content: space-between;
        align-items: center;
        color: var(--muted);
        font-size: 12px;
      }
      a.btn {
        color: var(--text);
        background: var(--border);
        padding: 6px 12px;
        border-radius: 6px;
        text-decoration: none;
        font-size: 12px;
      }
    </style>
  </head>
  <body>
    <div class="wrap">
      <div class="header">
        <div id="spinner" class="spinner"></div>
        <div>
          <h1>Photo Stand</h1>
          <p id="current-step" class="subtitle">Vérification des services en cours...</p>
        </div>
      </div>

      <div class="card">
        <h2>Étapes de démarrage</h2>
        <div id="steps" class="list"></div>
      </div>

      <div class="card">
        <h2>Conteneurs Docker</h2>
        <div id="containers" class="grid">
          <div class="badge">En attente de Docker Compose...</div>
        </div>
      </div>

      <div class="card">
        <h2>Activité récente</h2>
        <pre id="logs" class="logs">Chargement des logs...</pre>
      </div>

      <div class="footer">
        <span>i3 : Super+F (plein écran / i3status) · Super+Entrée (Alacritty) · Super+P (Aperçu Canon)</span>
        <a id="open-now" class="btn" href="http://127.0.0.1">Ouvrir maintenant</a>
      </div>
    </div>

    <script>
      function esc(s) {
        return String(s).replace(/[&<>"']/g, c => ({
          "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;"
        }[c]));
      }

      function containerDot(c) {
        const st = (c.status || "").toLowerCase();
        if (st.includes("(healthy)") || (c.state === "exited" && st.includes("exited (0)"))) return "done";
        if (c.state === "running" && !st.includes("unhealthy") && !st.includes("starting")) return "done";
        if (st.includes("unhealthy") || (c.state === "exited" && !st.includes("exited (0)"))) return "error";
        if (c.state === "running" || c.state === "created" || c.state === "restarting") return "running";
        return "waiting";
      }

      async function poll() {
        try {
          const resp = await fetch("/api/status", { cache: "no-store" });
          const data = await resp.json();

          document.getElementById("current-step").textContent = data.currentStep;
          document.getElementById("open-now").href = data.targetUrl;

          const stepsEl = document.getElementById("steps");
          stepsEl.innerHTML = (data.steps || []).map(s => `
            <div class="row">
              <div class="left">
                <span class="dot ${esc(s.state)}"></span>
                <span>${esc(s.label)}</span>
              </div>
              <span class="badge">${esc(s.detail)}</span>
            </div>
          `).join("");

          const contEl = document.getElementById("containers");
          if (data.containers && data.containers.length > 0) {
            contEl.innerHTML = data.containers.map(c => `
              <div class="chip">
                <div class="chip-head">
                  <span class="dot ${containerDot(c)}"></span>
                  <span>${esc(c.name)}</span>
                </div>
                <div class="chip-sub">${esc(c.status || c.state)}</div>
              </div>
            `).join("");
          } else {
            contEl.innerHTML = '<div class="badge">Aucun conteneur démarré pour le moment...</div>';
          }

          const logsEl = document.getElementById("logs");
          logsEl.textContent = (data.logs && data.logs.length > 0)
            ? data.logs.join("\\n")
            : "En attente des premiers logs...";

          if (data.ready) {
            document.getElementById("spinner").classList.add("ready");
            setTimeout(() => window.location.replace(data.targetUrl), 600);
            return;
          }
        } catch (err) {
          document.getElementById("current-step").textContent = "Connexion au moniteur local...";
        }
        setTimeout(poll, 1500);
      }

      poll();
    </script>
  </body>
</html>
"""


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        return  # Évite le spam journald toutes les 1.5s

    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/api/status":
            body = json.dumps(collect_status()).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            body = HTML_PAGE.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)


def main():
    server = http.server.ThreadingHTTPServer((BIND_HOST, BIND_PORT), Handler)
    server.serve_forever()


if __name__ == "__main__":
    main()
