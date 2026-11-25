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
import glob
import subprocess
import threading
import ipaddress
import socket
import time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from urllib.parse import unquote, urlparse, urlsplit

# Import CDP interceptor
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(os.path.dirname(SCRIPT_DIR))
if SCRIPT_DIR not in sys.path:
    sys.path.insert(0, SCRIPT_DIR)

from cdp_interceptor import login_session

MAX_REQUEST_BYTES = 1024 * 1024
MAX_VISIBLE_QUEUE_ITEMS = 300
STATE_CACHE_TTL_SECONDS = 1.5
_state_cache_lock = threading.Lock()
_state_cache = {"expires_at": 0.0, "system": None}


def get_settings_path():
    override = os.environ.get("NS_CLOUD_DRIVE_CONFIG_DIR")
    if override and os.path.isdir(override):
        return os.path.join(override, "settings.json")
    if sys.platform == "win32":
        return os.path.join(get_data_root(), "config", "settings.json")
    config_home = os.environ.get("XDG_CONFIG_HOME", os.path.join(os.path.expanduser("~"), ".config"))
    return os.path.join(config_home, "nsclouddrive", "settings.json")


def load_settings():
    path = get_settings_path()
    candidates = [path]
    legacy_path = os.path.join(get_data_root(), "settings.json")
    if legacy_path != path:
        candidates.append(legacy_path)
    for candidate in candidates:
        try:
            if not os.path.isfile(candidate):
                continue
            with open(candidate, "r", encoding="utf-8") as f:
                settings = json.load(f)
            return settings if isinstance(settings, dict) else {}
        except (OSError, ValueError, TypeError):
            continue
    return {}


def save_settings_dict(settings):
    path = get_settings_path()
    directory = os.path.dirname(path)
    os.makedirs(directory, mode=0o700, exist_ok=True)
    temp_path = path + ".tmp"
    fd = os.open(temp_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(settings, f, indent=2)
            f.flush()
            os.fsync(f.fileno())
        os.replace(temp_path, path)
    except Exception:
        try:
            os.unlink(temp_path)
        except OSError:
            pass
        raise


def get_data_root():
    override = os.environ.get("NS_CLOUD_DRIVE_DATA_DIR")
    if override and os.path.isdir(override):
        return override
    if sys.platform == "win32":
        local_app_data = os.environ.get("LOCALAPPDATA") or os.path.join(os.path.expanduser("~"), "AppData", "Local")
        return os.path.join(local_app_data, "NSCloudDrive")
    data_home = os.environ.get("XDG_DATA_HOME")
    if data_home:
        return os.path.join(data_home, "nsclouddrive")
    return os.path.join(os.path.expanduser("~"), ".local", "share", "nsclouddrive")


def load_transfer_queue():
    """Read the durable queue snapshot without starting a PowerShell process."""
    queue_path = os.path.join(get_data_root(), "state", "transfer-jobs.json")
    candidates = [path for path in (queue_path, queue_path + ".bak") if os.path.isfile(path)]
    versioned_backups = []
    for backup_path in glob.glob(queue_path + ".bak.*"):
        try:
            versioned_backups.append((os.path.getmtime(backup_path), backup_path))
        except OSError:
            # Queue rotation can remove a backup after glob returns it.
            continue
    versioned_backups = [path for _, path in sorted(versioned_backups, reverse=True)]
    candidates.extend(versioned_backups)
    if not candidates:
        if os.path.isfile(queue_path + ".initialized"):
            raise ValueError("Durable transfer state is missing")
        return []
    for candidate in candidates:
        try:
            with open(candidate, "r", encoding="utf-8-sig") as f:
                payload = json.load(f)
            jobs = payload.get("Jobs", []) if isinstance(payload, dict) else []
            if not isinstance(jobs, list):
                continue
            result = []
            for job in jobs:
                if not isinstance(job, dict):
                    continue
                account = job.get("DestinationAccount") or {}
                if not isinstance(account, dict):
                    account = {}
                result.append({
                    "id": str(job.get("QueueId") or job.get("JobId") or ""),
                    "status": str(job.get("Status") or "Unknown"),
                    "file_name": str(job.get("FileName") or ""),
                    "destination_path": str(job.get("DestinationFilePath") or job.get("DestinationPath") or ""),
                    "account_id": str(job.get("DestinationAccountId") or account.get("Id") or ""),
                    "provider": str(job.get("DestinationProvider") or account.get("ProviderId") or ""),
                    "operation": str(job.get("OperationType") or ""),
                    "size_bytes": max(0, _safe_int(job.get("FileSizeBytes"))),
                    "bytes_transferred": max(0, _safe_int(job.get("BytesTransferred"))),
                    "percentage": max(0.0, min(100.0, _safe_float(job.get("Percentage")))),
                })
            return result
        except (OSError, ValueError, TypeError):
            continue
    raise ValueError("Durable transfer state could not be read")


def _safe_int(value):
    try:
        return int(value or 0)
    except (ValueError, TypeError, OverflowError):
        return 0


def _safe_float(value):
    try:
        number = float(value or 0)
        return number if number == number and abs(number) != float("inf") else 0.0
    except (ValueError, TypeError, OverflowError):
        return 0.0


def _is_loopback_host(host_header):
    if not host_header:
        return False
    try:
        hostname = urlsplit("//" + host_header).hostname
        return hostname == "localhost" or ipaddress.ip_address(hostname).is_loopback
    except (ValueError, TypeError):
        return False


def _request_is_same_origin(handler, require_origin=False):
    host = handler.headers.get("Host", "")
    if not _is_loopback_host(host):
        return False
    fetch_site = handler.headers.get("Sec-Fetch-Site", "")
    if fetch_site not in ("", "same-origin", "none"):
        return False
    origin = handler.headers.get("Origin")
    if not origin:
        return not require_origin
    parsed = urlsplit(origin)
    if parsed.scheme != "http" or not parsed.netloc or parsed.netloc.lower() != host.lower():
        return False
    return True


def _read_system_state():
    current = time.monotonic()
    with _state_cache_lock:
        cached = _state_cache.get("system")
        if cached is not None and current < _state_cache["expires_at"]:
            return cached

        service = "unknown"
        try:
            svc = subprocess.run(
                ["systemctl", "--user", "show", "nsclouddrive.service", "--property=ActiveState,UnitFileState", "--value"],
                capture_output=True, text=True, timeout=1.5
            ).stdout.strip().splitlines()
            if svc:
                service = svc[0] + (" (enabled)" if len(svc) > 1 and svc[1] == "enabled" else "")
        except Exception:
            pass

        mounts = []
        try:
            result = subprocess.run(
                ["findmnt", "-t", "fuse.rclone", "-n", "-o", "TARGET"],
                capture_output=True, text=True, timeout=1.5
            )
            mounts = [line.strip() for line in result.stdout.splitlines() if line.strip()]
        except Exception:
            pass
        system = {"service": service, "mounts": mounts}
        _state_cache["system"] = system
        _state_cache["expires_at"] = current + STATE_CACHE_TTL_SECONDS
        return system


class DashboardHandler(BaseHTTPRequestHandler):

    def log_message(self, format, *args):
        # Silence routine access logs
        pass

    def send_json(self, data, status=200):
        body = json.dumps(data).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
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
        self.send_error(405, "Cross-origin requests are not supported")

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path

        if not _request_is_same_origin(self):
            self.send_json({"error": "Local same-origin access required"}, 403)
            return

        if path in ("/", "/index.html"):
            index_path = os.path.join(SCRIPT_DIR, "index.html")
            if os.path.isfile(index_path):
                with open(index_path, "r", encoding="utf-8") as f:
                    self.send_html(f.read())
            else:
                self.send_html("<h1>NS Cloud Drive UI</h1><p>index.html not found</p>", 404)

        elif path.startswith("/assets/"):
            assets_root = os.path.realpath(os.path.join(REPO_ROOT, "assets"))
            decoded_path = unquote(path)
            rel_path = decoded_path[len("/assets/"):].replace("/", os.sep)
            full_asset_path = os.path.realpath(os.path.join(assets_root, rel_path))
            try:
                contained = os.path.commonpath([assets_root, full_asset_path]) == assets_root
            except ValueError:
                contained = False
            if contained and os.path.isfile(full_asset_path) and os.path.splitext(full_asset_path)[1].lower() in (".png", ".svg", ".ico"):
                ext = os.path.splitext(full_asset_path)[1].lower()
                mime = "image/png" if ext == ".png" else "image/svg+xml" if ext == ".svg" else "image/x-icon" if ext == ".ico" else "application/octet-stream"
                with open(full_asset_path, "rb") as f:
                    data = f.read()
                self.send_response(200)
                self.send_header("Content-Type", mime)
                self.send_header("Content-Length", str(len(data)))
                self.send_header("Cache-Control", "public, max-age=86400")
                self.end_headers()
                self.wfile.write(data)
                return
            else:
                self.send_json({"error": "Asset not found"}, 404)
                return

        elif path == "/api/state":
            system = _read_system_state()
            svc_str = system["service"]

            # 2. Configured accounts from settings.json
            settings = load_settings()
            raw_accounts = settings.get("Accounts", [])
            if not isinstance(raw_accounts, list):
                raw_accounts = []
            accounts = []
            for acc in raw_accounts:
                if not isinstance(acc, dict):
                    continue
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

            # Read the queue snapshot directly. Starting PowerShell for every UI
            # refresh caused cold-start latency and overlapping CLI processes.
            mounts = system["mounts"]
            queue_error = ""
            try:
                queue_items = load_transfer_queue()
                queue_available = True
            except (OSError, ValueError, TypeError):
                queue_items = []
                queue_available = False
                queue_error = "Saved transfer state could not be read; the queue count is unavailable."
            active_statuses = {"Queued", "Staging", "Staged", "Uploading", "Waiting for network/provider", "Upload pending remote confirmation", "Awaiting remote confirmation", "Verifying remote file"}
            completed_statuses = {"Completed and remotely confirmed", "Completed"}
            active_count = sum(1 for item in queue_items if item["status"] in active_statuses)
            completed_count = sum(1 for item in queue_items if item["status"] in completed_statuses)
            queue_items.sort(key=lambda item: item["status"] in active_statuses, reverse=True)
            visible_queue = queue_items[:MAX_VISIBLE_QUEUE_ITEMS]
            if settings.get("CacheDirectory"):
                cache_directory = settings["CacheDirectory"]
            elif sys.platform == "win32":
                cache_directory = r"D:\CloudCache"
            else:
                cache_directory = os.path.join(os.path.expanduser("~"), "CloudCache")

            data = {
                "service": svc_str,
                "accounts": accounts,
                "mounts": mounts,
                "queue": visible_queue,
                "queue_summary": {
                    "available": queue_available,
                    "total": len(queue_items),
                    "visible": len(visible_queue),
                    "truncated": len(queue_items) > len(visible_queue),
                    "active": active_count if queue_available else None,
                    "completed": completed_count,
                },
                "queue_error": queue_error,
                "cache_directory": cache_directory,
                "auto_mount": settings.get("AutoMountDrives", settings.get("AutoMount", True)),
            }
            self.send_json(data)

        elif path == "/api/login/browser/status":
            self.send_json(login_session.get_status())

        else:
            self.send_json({"error": "Not Found"}, 404)

    def do_POST(self):
        if not _request_is_same_origin(self, require_origin=True):
            self.send_json({"error": "Local same-origin access required"}, 403)
            return

        parsed = urlparse(self.path)
        path = parsed.path

        try:
            content_len = int(self.headers.get("Content-Length", 0))
        except ValueError:
            self.send_json({"error": "Invalid Content-Length"}, 400)
            return
        if content_len < 0 or content_len > MAX_REQUEST_BYTES:
            self.send_json({"error": "Request body too large"}, 413)
            return
        try:
            body = self.rfile.read(content_len).decode("utf-8") if content_len > 0 else "{}"
        except UnicodeDecodeError:
            self.send_json({"error": "Request body must be UTF-8"}, 400)
            return
        try:
            payload = json.loads(body)
        except Exception:
            self.send_json({"error": "Request body must be valid JSON"}, 400)
            return
        if not isinstance(payload, dict):
            self.send_json({"error": "Request body must be a JSON object"}, 400)
            return

        if path == "/api/action":
            action = payload.get("action")
            target = payload.get("target", "")
            if not isinstance(target, str):
                self.send_json({"error": "Invalid account identifier"}, 400)
                return

            settings = load_settings()
            configured_accounts = settings.get("Accounts", [])
            if not isinstance(configured_accounts, list):
                configured_accounts = []
            account = next((entry for entry in configured_accounts if isinstance(entry, dict) and entry.get("Id") == target), None)
            if action in ("mount_account", "unmount_account", "remove_account", "open_folder") and account is None:
                self.send_json({"error": "Unknown account"}, 404)
                return

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
                folder_path = account.get("MountPoint") or os.path.join(os.path.expanduser("~"), "CloudDrives", target)
                env = os.environ.copy()
                env["DISPLAY"] = env.get("DISPLAY", ":1")
                subprocess.Popen(["xdg-open", folder_path], env=env)
                self.send_json({"success": True, "message": f"Opened {folder_path}"})
                return
            elif action == "remove_account":
                settings["Accounts"] = [a for a in configured_accounts if a.get("Id") != target]
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
                    "message": "Action completed." if res.returncode == 0 else "Action failed. Check the local application logs."
                })
            except Exception:
                self.send_json({"error": "Action could not be completed."}, 500)

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

            if not isinstance(cookie, str) or not isinstance(jstoken, str) or not isinstance(name, str) or not isinstance(provider, str):
                self.send_json({"error": "Invalid login request"}, 400)
                return
            if provider not in ("terabox", "gdrive", "vps", "proton") or not name.strip() or name.lstrip().startswith(("-", "/")) or any(ord(ch) < 32 for ch in name) or len(name) > 128 or len(cookie) > 65536 or len(jstoken) > 65536:
                self.send_json({"error": "Invalid login request"}, 400)
                return

            if not cookie:
                self.send_json({"error": "Session cookie is required"}, 400)
                return

            # Keep authentication material out of process command-line arguments.
            env = os.environ.copy()
            env["NS_CLOUD_DRIVE_LOGIN_COOKIE"] = cookie
            env["NS_CLOUD_DRIVE_LOGIN_JSTOKEN"] = jstoken
            cmd = ["nsclouddrive", "login", provider, "--name", name, "--automount", "--login-secrets-from-env"]

            try:
                res = subprocess.run(cmd, capture_output=True, text=True, timeout=30, env=env)
                if res.returncode == 0:
                    subprocess.run(["nsclouddrive", "mount", "all"], capture_output=True, text=True, timeout=20)
                    self.send_json({"success": True, "message": "Account connected successfully"})
                else:
                    # Provider diagnostics can echo credential material. Keep the
                    # browser response generic instead of returning child output.
                    self.send_json({"success": False, "error": "Could not validate the session. Check the credentials and try again."})
            except Exception as ex:
                self.send_json({"error": str(ex)}, 500)

        elif path == "/api/settings/save":
            settings = load_settings()
            if "cache_dir" in payload:
                cache_dir = payload["cache_dir"]
                if not isinstance(cache_dir, str) or len(cache_dir) > 4096 or "\x00" in cache_dir:
                    self.send_json({"error": "Invalid cache directory"}, 400)
                    return
                settings["CacheDirectory"] = os.path.expanduser(cache_dir.strip())
            if "auto_mount" in payload:
                if not isinstance(payload["auto_mount"], bool):
                    self.send_json({"error": "Invalid auto-mount setting"}, 400)
                    return
                settings["AutoMountDrives"] = payload["auto_mount"]
            save_settings_dict(settings)
            self.send_json({"success": True})

        else:
            self.send_json({"error": "Not Found"}, 404)


def run_server(host="127.0.0.1", port=8899):
    try:
        if host != "localhost" and not ipaddress.ip_address(host).is_loopback:
            raise ValueError("The management UI may only bind to a loopback address.")
    except ValueError as exc:
        if host != "localhost":
            raise ValueError("The management UI may only bind to localhost, 127.0.0.1, or ::1.") from exc
    server_type = type(
        "LoopbackThreadingHTTPServer",
        (ThreadingHTTPServer,),
        {
            "address_family": socket.AF_INET6 if ":" in host else socket.AF_INET,
            "allow_reuse_address": True,
            "daemon_threads": True,
        },
    )
    server = server_type((host, port), DashboardHandler)
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
