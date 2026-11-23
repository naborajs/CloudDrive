#!/usr/bin/env python3
"""
NS Cloud Drive - Chromium DevTools Protocol (CDP) Cookie & Token Interceptor
Provides automated browser sign-in and session capture for TeraBox on Linux.
Launches Chromium on DISPLAY=:1 in application window mode, attaches to CDP
over pure-Python RFC 6455 WebSockets, captures 'ndus' session cookie and jsToken,
validates the session, and saves the account via nsclouddrive CLI.
"""

import os
import sys
import time
import json
import base64
import socket
import struct
import shutil
import urllib.request
import urllib.parse
import subprocess
import threading
from typing import Optional, Dict, Any, Tuple


class PureWebSocketClient:
    """Lightweight RFC 6455 compliant WebSocket client using Python standard library."""

    def __init__(self, ws_url: str, timeout: float = 5.0):
        self.ws_url = ws_url
        self.timeout = timeout
        parsed = urllib.parse.urlparse(ws_url)
        self.host = parsed.hostname or '127.0.0.1'
        self.port = parsed.port or 80
        self.path = parsed.path
        if parsed.query:
            self.path += '?' + parsed.query
        self.sock: Optional[socket.socket] = None
        self._msg_id = 0

    def connect(self) -> None:
        self.sock = socket.create_connection((self.host, self.port), timeout=self.timeout)
        self.sock.settimeout(self.timeout)
        key = base64.b64encode(os.urandom(16)).decode('ascii')
        handshake = (
            f"GET {self.path} HTTP/1.1\r\n"
            f"Host: {self.host}:{self.port}\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\n"
            "Sec-WebSocket-Version: 13\r\n\r\n"
        )
        self.sock.sendall(handshake.encode('utf-8'))
        response = b""
        while b"\r\n\r\n" not in response:
            chunk = self.sock.recv(1024)
            if not chunk:
                break
            response += chunk
        resp_text = response.decode('utf-8', errors='ignore')
        if "101" not in resp_text:
            raise ConnectionError(f"WebSocket upgrade rejected: {resp_text[:120]}")

    def send_cmd(self, method: str, params: Optional[Dict[str, Any]] = None) -> int:
        if not self.sock:
            raise ConnectionError("WebSocket is not connected")
        self._msg_id += 1
        cmd_id = self._msg_id
        payload = {"id": cmd_id, "method": method}
        if params is not None:
            payload["params"] = params
        data = json.dumps(payload).encode('utf-8')
        length = len(data)
        mask = os.urandom(4)

        header = bytearray([0x81])  # text opcode, FIN=1
        if length < 126:
            header.append(0x80 | length)
        elif length < 65536:
            header.append(0x80 | 126)
            header.extend(struct.pack(">H", length))
        else:
            header.append(0x80 | 127)
            header.extend(struct.pack(">Q", length))
        header.extend(mask)
        masked = bytearray(b ^ mask[i % 4] for i, b in enumerate(data))
        header.extend(masked)
        self.sock.sendall(header)
        return cmd_id

    def recv_message(self, target_id: Optional[int] = None, max_attempts: int = 10) -> Optional[Dict[str, Any]]:
        if not self.sock:
            return None
        attempts = 0
        while attempts < max_attempts:
            attempts += 1
            try:
                hdr = self._read_bytes(2)
                if not hdr or len(hdr) < 2:
                    return None
                b1, b2 = hdr[0], hdr[1]
                opcode = b1 & 0x0F
                if opcode == 0x8:  # Close frame
                    return None
                masked = (b2 & 0x80) != 0
                length = b2 & 0x7F
                if length == 126:
                    length = struct.unpack(">H", self._read_bytes(2))[0]
                elif length == 127:
                    length = struct.unpack(">Q", self._read_bytes(8))[0]
                mask = self._read_bytes(4) if masked else None
                body = self._read_bytes(length)
                if masked and mask:
                    body = bytearray(b ^ mask[i % 4] for i, b in enumerate(body))
                msg = json.loads(body.decode('utf-8', errors='replace'))
                if target_id is None or msg.get("id") == target_id:
                    return msg
            except (socket.timeout, socket.error):
                return None
        return None

    def _read_bytes(self, count: int) -> bytearray:
        buf = bytearray()
        while len(buf) < count:
            chunk = self.sock.recv(count - len(buf))
            if not chunk:
                break
            buf.extend(chunk)
        return buf

    def close(self) -> None:
        if self.sock:
            try:
                self.sock.close()
            except Exception:
                pass
            self.sock = None


class TeraBoxBrowserLoginSession:
    """Manages an automated TeraBox browser sign-in session on Linux via CDP."""

    def __init__(self, port: int = 9224, display: str = ":1"):
        self.port = port
        self.display = display
        self.proc: Optional[subprocess.Popen] = None
        self.state = "idle"  # idle | launching | waiting | detected | validating | success | error | cancelled
        self.message = "Initialized"
        self.account_info: Optional[Dict[str, Any]] = None
        self.error: Optional[str] = None
        self.thread: Optional[threading.Thread] = None
        self.stop_event = threading.Event()
        snap_dir = os.path.expanduser("~/snap/chromium")
        if os.path.isdir(snap_dir):
            self.profile_dir = os.path.expanduser("~/snap/chromium/common/nsclouddrive/browser-login")
        else:
            self.profile_dir = os.path.expanduser("~/.config/nsclouddrive/browser-login")

    def start(self) -> Tuple[bool, str]:
        if self.state in ("launching", "waiting", "detected", "validating"):
            return False, "Login session is already active"

        self.stop_event.clear()
        self.state = "launching"
        self.message = "Launching browser for TeraBox sign-in..."
        self.error = None
        self.account_info = None

        self.thread = threading.Thread(target=self._run_session, daemon=True)
        self.thread.start()
        return True, "Login session started"

    def cancel(self) -> None:
        self.stop_event.set()
        self.state = "cancelled"
        self.message = "Login session cancelled by user"
        self._terminate_browser()

    def get_status(self) -> Dict[str, Any]:
        return {
            "state": self.state,
            "message": self.message,
            "account": self.account_info,
            "error": self.error
        }

    def _find_chromium_binary(self) -> str:
        candidates = [
            "/snap/bin/chromium",
            "/usr/bin/chromium-browser",
            "/usr/bin/chromium",
            "/usr/bin/google-chrome-stable",
            "/usr/bin/google-chrome",
            shutil.which("chromium") or "",
            shutil.which("chromium-browser") or "",
            shutil.which("google-chrome") or ""
        ]
        for c in candidates:
            if c and os.path.isfile(c) and os.access(c, os.X_OK):
                return c
        return "chromium"

    def _run_session(self) -> None:
        try:
            # 1. Clean previous profile locks or temp files
            os.makedirs(self.profile_dir, exist_ok=True)
            singleton_lock = os.path.join(self.profile_dir, "SingletonLock")
            if os.path.exists(singleton_lock):
                try:
                    os.remove(singleton_lock)
                except Exception:
                    pass

            chrome_bin = self._find_chromium_binary()
            env = os.environ.copy()
            env["DISPLAY"] = self.display if os.path.exists("/tmp/.X11-unix/X1") else env.get("DISPLAY", ":1")
            env["XDG_RUNTIME_DIR"] = f"/run/user/{os.getuid()}"
            env["DBUS_SESSION_BUS_ADDRESS"] = f"unix:path=/run/user/{os.getuid()}/bus"

            cmd = [
                chrome_bin,
                f"--app=https://www.terabox.com/",
                f"--user-data-dir={self.profile_dir}",
                f"--remote-debugging-port={self.port}",
                "--no-first-run",
                "--no-default-browser-check",
                "--window-size=1024,768",
                "--disable-background-networking",
                "--disable-default-apps"
            ]

            self.proc = subprocess.Popen(
                cmd,
                env=env,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL
            )

            # 2. Wait for CDP endpoint to respond
            cdp_ready = False
            start_wait = time.time()
            while time.time() - start_wait < 15 and not self.stop_event.is_set():
                if self.proc.poll() is not None:
                    raise RuntimeError("Chromium exited prematurely during launch")
                try:
                    req = urllib.request.Request(f"http://127.0.0.1:{self.port}/json/version")
                    with urllib.request.urlopen(req, timeout=1.0) as resp:
                        if resp.status == 200:
                            cdp_ready = True
                            break
                except Exception:
                    time.sleep(0.5)

            if not cdp_ready:
                raise TimeoutError("Timed out waiting for Chromium CDP port to open")

            self.state = "waiting"
            self.message = "Browser opened. Sign in to your TeraBox account in the window..."

            # 3. Poll for target page and capture cookies
            max_duration = 600  # 10 minutes timeout
            start_poll = time.time()
            ws_client: Optional[PureWebSocketClient] = None

            while time.time() - start_poll < max_duration and not self.stop_event.is_set():
                if self.proc.poll() is not None:
                    # User closed browser window
                    if self.state not in ("success", "validating"):
                        self.state = "cancelled"
                        self.message = "Browser window was closed before sign-in completed"
                    return

                try:
                    # Discover page target
                    list_req = urllib.request.Request(f"http://127.0.0.1:{self.port}/json/list")
                    with urllib.request.urlopen(list_req, timeout=2.0) as resp:
                        targets = json.loads(resp.read().decode('utf-8'))

                    page_targets = [t for t in targets if t.get("type") == "page"]
                    if not page_targets:
                        time.sleep(1.5)
                        continue

                    # Select active or main TeraBox target
                    target = page_targets[0]
                    for t in page_targets:
                        url = t.get("url", "")
                        if "terabox" in url:
                            target = t
                            break

                    ws_url = target.get("webSocketDebuggerUrl")
                    if not ws_url:
                        time.sleep(1.5)
                        continue

                    # Connect or reuse WebSocket
                    if ws_client is None or ws_client.ws_url != ws_url:
                        if ws_client:
                            ws_client.close()
                        ws_client = PureWebSocketClient(ws_url, timeout=3.0)
                        try:
                            ws_client.connect()
                        except Exception:
                            ws_client = None
                            time.sleep(1.5)
                            continue

                    # Query cookies via Network.getCookies
                    cookie_cmd_id = ws_client.send_cmd("Network.getCookies", {
                        "urls": [
                            "https://www.terabox.com",
                            "https://terabox.com",
                            "https://www.terabox.app",
                            "https://terabox.app"
                        ]
                    })
                    msg = ws_client.recv_message(target_id=cookie_cmd_id, max_attempts=5)
                    cookies = []
                    if msg and "result" in msg:
                        cookies = msg["result"].get("cookies", [])

                    # Look for ndus cookie
                    ndus_cookie = None
                    cookie_dict = {}
                    for c in cookies:
                        c_name = c.get("name")
                        c_val = c.get("value")
                        if c_name and c_val:
                            cookie_dict[c_name] = c_val
                            if c_name == "ndus":
                                ndus_cookie = c_val

                    if ndus_cookie:
                        self.state = "detected"
                        self.message = "Session cookie detected! Extracting authorization tokens..."

                        # Extract window.jsToken from DOM
                        eval_cmd_id = ws_client.send_cmd("Runtime.evaluate", {
                            "expression": "(typeof window.jsToken === 'string' && window.jsToken) ? window.jsToken : (typeof window._jsToken === 'string' ? window._jsToken : '')"
                        })
                        eval_msg = ws_client.recv_message(target_id=eval_cmd_id, max_attempts=5)
                        js_token = ""
                        if eval_msg and "result" in eval_msg:
                            js_token = eval_msg["result"].get("result", {}).get("value", "")

                        # Construct cookie header
                        cookie_str = "; ".join(f"{k}={v}" for k, v in cookie_dict.items())

                        # Validate with TeraBox backend
                        self.state = "validating"
                        self.message = "Validating authorization with TeraBox..."

                        user_info = self._validate_terabox_session(cookie_str, js_token)
                        if user_info and user_info.get("valid"):
                            # Session is authentic!
                            username = user_info.get("username") or "User"
                            account_id = f"terabox_{os.urandom(4).hex()}"
                            display_name = f"TeraBox ({username})"

                            # Save via nsclouddrive CLI
                            save_cmd = [
                                "nsclouddrive", "login", "terabox",
                                "--cookie", cookie_str,
                                "--name", display_name,
                                "--accountid", account_id,
                                "--automount"
                            ]
                            if js_token:
                                save_cmd.extend(["--jstoken", js_token])

                            sub_res = subprocess.run(save_cmd, capture_output=True, text=True, timeout=30)
                            if sub_res.returncode != 0:
                                raise RuntimeError(f"CLI login failed: {sub_res.stderr.strip() or sub_res.stdout.strip()}")

                            # Trigger mount
                            subprocess.run(["nsclouddrive", "mount", "all"], capture_output=True, text=True, timeout=20)

                            self.account_info = {
                                "id": account_id,
                                "name": display_name,
                                "provider": "terabox",
                                "username": username,
                                "mount_path": os.path.expanduser(f"~/CloudDrives/{account_id}")
                            }
                            self.state = "success"
                            self.message = f"Successfully connected and mounted TeraBox for {username}!"
                            self._terminate_browser()
                            return
                        else:
                            # Keep polling if ndus is fresh and session check hasn't finalized
                            pass

                except Exception as ex:
                    # Transient error during page reload or redirect
                    pass

                time.sleep(1.5)

            if not self.stop_event.is_set() and self.state != "success":
                self.state = "error"
                self.error = "Sign-in timed out. Please try again."
                self.message = "Sign-in timed out after 10 minutes"
                self._terminate_browser()

        except Exception as ex:
            self.state = "error"
            self.error = str(ex)
            self.message = f"Sign-in error: {str(ex)}"
            self._terminate_browser()

    def _validate_terabox_session(self, cookie_str: str, js_token: str) -> Optional[Dict[str, Any]]:
        """Validates the captured cookie against TeraBox check/login endpoint."""
        urls = [
            f"https://www.terabox.com/api/check/login?app_id=250528&channel=dubox&clienttype=0",
            f"https://www.terabox.app/api/check/login?app_id=250528&channel=dubox&clienttype=0"
        ]
        headers = {
            "Accept": "application/json, text/plain, */*",
            "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
            "Cookie": cookie_str,
            "Referer": "https://www.terabox.com/"
        }
        for u in urls:
            try:
                target_url = u + (f"&jsToken={urllib.parse.quote(js_token)}" if js_token else "")
                req = urllib.request.Request(target_url, headers=headers)
                with urllib.request.urlopen(req, timeout=5.0) as resp:
                    if resp.status == 200:
                        data = json.loads(resp.read().decode('utf-8'))
                        errno = data.get("errno")
                        if errno == 0:
                            uname = data.get("username") or data.get("user_name") or data.get("uname")
                            uk = data.get("uk")
                            if not uname and uk:
                                uname = f"user_{str(uk)[-4:]}"
                            return {"valid": True, "username": uname or "TeraBoxUser", "uk": uk}
            except Exception:
                continue
        return None

    def _terminate_browser(self) -> None:
        if self.proc:
            try:
                self.proc.terminate()
                self.proc.wait(timeout=2.0)
            except Exception:
                try:
                    self.proc.kill()
                except Exception:
                    pass
            self.proc = None


# Global singleton instance for the server
login_session = TeraBoxBrowserLoginSession()
