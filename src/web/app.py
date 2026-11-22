#!/usr/bin/env python3
"""
NS Cloud Drive - Web UI Dashboard & Local Management Server
Serves the Windows-parity management dashboard on http://127.0.0.1:8899.
Handles REST API actions, account inspection, and triggers the CDP automated browser
session capture for TeraBox on Linux.
"""

import os
import sys
import json
import shutil
import argparse
import subprocess
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs

# Import CDP interceptor
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
if SCRIPT_DIR not in sys.path:
    sys.path.insert(0, SCRIPT_DIR)

from cdp_interceptor import login_session


def get_settings_path():
    config_home = os.environ.get("XDG_CONFIG_HOME", os.path.expanduser("~/.config"))
    return os.path.join(config_home, "nsclouddrive", "settings.json")


def load_settings():
    path = get_settings_path()
    if os.path.isfile(path):
        try:
            with open(path, "r", encoding="utf-8") as f:
                return json.load(f)
        except Exception:
            return {}
    return {}


def save_settings_dict(settings):
    path = get_settings_path()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(settings, f, indent=2)


class DashboardHandler(BaseHTTPRequestHandler):

    def log_message(self, format, *args):
        # Silence routine access logs
        pass

    def send_json(self, data, status=200):
        body = json.dumps(data).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def send_html(self, content, status=200):
        body = content.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self):
        self.send_response(200)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path

        if path in ("/", "/index.html"):
            index_path = os.path.join(SCRIPT_DIR, "index.html")
            if os.path.isfile(index_path):
                with open(index_path, "r", encoding="utf-8") as f:
                    self.send_html(f.read())
            else:
                self.send_html("<h1>NS Cloud Drive UI</h1><p>index.html not found</p>", 404)

        elif path == "/api/state":
            # 1. Daemon service state
            svc_str = "unknown"
            try:
                svc = subprocess.run(["systemctl", "--user", "is-active", "nsclouddrive.service"], capture_output=True, text=True, timeout=3).stdout.strip()
                svc_en = subprocess.run(["systemctl", "--user", "is-enabled", "nsclouddrive.service"], capture_output=True, text=True, timeout=3).stdout.strip()
                svc_str = svc + (" (enabled)" if svc_en == "enabled" else "")
            except Exception:
                pass

            # 2. Configured accounts from settings.json
            settings = load_settings()
            raw_accounts = settings.get("Accounts", [])
            accounts = []
            for acc in raw_accounts:
                acc_id = acc.get("Id", "")
                prov = acc.get("ProviderId", "")
                name = acc.get("DisplayName", acc_id)
                mount_point = acc.get("MountPoint", "")
                if not mount_point:
                    mount_point = os.path.expanduser(f"~/CloudDrives/{acc_id}")
                accounts.append({
                    "id": acc_id,
                    "provider": prov,
                    "name": name,
                    "email": acc.get("AccountEmail", ""),
                    "mount_path": mount_point,
                    "auto_mount": acc.get("AutoMount", True)
                })

            # 3. Active FUSE mounts
            mounts = []
            try:
                res = subprocess.run(["findmnt", "-t", "fuse.rclone", "-n", "-o", "TARGET"], capture_output=True, text=True, timeout=3)
                for line in res.stdout.strip().split("\n"):
                    line = line.strip()
                    if line:
                        mounts.append(line)
            except Exception:
                pass

            # 4. Transfer queue
            queue_items = []
            try:
                q_res = subprocess.run(["nsclouddrive", "queue"], capture_output=True, text=True, timeout=5)
                for line in q_res.stdout.strip().split("\n"):
                    line = line.strip()
                    if line and not line.startswith("===") and not line.startswith("Total:"):
                        queue_items.append(line)
            except Exception:
                pass

            data = {
                "service": svc_str,
                "accounts": accounts,
                "mounts": mounts,
                "queue": queue_items,
                "cache_directory": settings.get("CacheDirectory", "/run/user/1001/nsclouddrive/cache")
            }
            self.send_json(data)

        elif path == "/api/login/browser/status":
            self.send_json(login_session.get_status())

        else:
            self.send_json({"error": "Not Found"}, 404)

    def do_POST(self):
        parsed = urlparse(self.path)
        path = parsed.path

        content_len = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_len).decode("utf-8") if content_len > 0 else "{}"
        try:
            payload = json.loads(body)
        except Exception:
            payload = {}

        if path == "/api/action":
            action = payload.get("action")
            target = payload.get("target", "")

            if action == "mount_all":
                cmd = ["nsclouddrive", "mount", "all"]
            elif action == "unmount_all":
                cmd = ["nsclouddrive", "unmount", "all"]
            elif action == "mount_account":
                cmd = ["nsclouddrive", "mount", target]
            elif action == "unmount_account":
                cmd = ["nsclouddrive", "unmount", target]
            elif action == "clear_queue":
                cmd = ["nsclouddrive", "clear-queue"]
            elif action == "open_folder":
                folder_path = os.path.expanduser(f"~/CloudDrives/{target}")
                env = os.environ.copy()
                env["DISPLAY"] = env.get("DISPLAY", ":1")
                subprocess.Popen(["xdg-open", folder_path], env=env)
                self.send_json({"success": True, "message": f"Opened {folder_path}"})
                return
            elif action == "remove_account":
                settings = load_settings()
                accs = settings.get("Accounts", [])
                settings["Accounts"] = [a for a in accs if a.get("Id") != target]
                save_settings_dict(settings)
                # Unmount if mounted
                subprocess.run(["nsclouddrive", "unmount", target], capture_output=True, text=True, timeout=10)
                self.send_json({"success": True, "message": f"Removed account {target}"})
                return
            else:
                self.send_json({"error": f"Unknown action: {action}"}, 400)
                return

            try:
                res = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
                self.send_json({
                    "success": res.returncode == 0,
                    "stdout": res.stdout,
                    "stderr": res.stderr
                })
            except Exception as ex:
                self.send_json({"error": str(ex)}, 500)

        elif path == "/api/login/browser/start":
            success, msg = login_session.start()
            self.send_json({"success": success, "message": msg})

        elif path == "/api/login/browser/cancel":
            login_session.cancel()
            self.send_json({"success": True, "message": "Cancelled"})

        elif path == "/api/login/manual":
            provider = payload.get("provider", "terabox")
            name = payload.get("name", "My TeraBox")
            cookie = payload.get("cookie", "")
            jstoken = payload.get("jstoken", "")

            if not cookie:
                self.send_json({"error": "Session cookie is required"}, 400)
                return

            cmd = ["nsclouddrive", "login", provider, "--cookie", cookie, "--name", name, "--automount"]
            if jstoken:
                cmd.extend(["--jstoken", jstoken])

            try:
                res = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
                if res.returncode == 0:
                    subprocess.run(["nsclouddrive", "mount", "all"], capture_output=True, text=True, timeout=20)
                    self.send_json({"success": True, "message": "Account connected successfully"})
                else:
                    self.send_json({"success": False, "error": res.stderr.strip() or res.stdout.strip()})
            except Exception as ex:
                self.send_json({"error": str(ex)}, 500)

        elif path == "/api/settings/save":
            settings = load_settings()
            if "cache_dir" in payload:
                settings["CacheDirectory"] = payload["cache_dir"]
            if "auto_mount" in payload:
                settings["AutoMount"] = bool(payload["auto_mount"])
            save_settings_dict(settings)
            self.send_json({"success": True})

        else:
            self.send_json({"error": "Not Found"}, 404)


def run_server(host="127.0.0.1", port=8899):
    server = ThreadingHTTPServer((host, port), DashboardHandler)
    print(f"=== NS Cloud Drive Web UI listening on http://{host}:{port} ===")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down NS Cloud Drive Web UI...")
    finally:
        server.server_close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="NS Cloud Drive Web UI Server")
    parser.add_argument("--host", default="127.0.0.1", help="Host to bind (default: 127.0.0.1)")
    parser.add_argument("--port", type=int, default=8899, help="Port to bind (default: 8899)")
    args = parser.parse_args()
    run_server(args.host, args.port)
