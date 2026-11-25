import http.client
import json
import os
import pathlib
import sys
import tempfile
import threading
import unittest
from types import SimpleNamespace
from unittest import mock

REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
WEB_DIR = REPO_ROOT / "src" / "web"
if str(WEB_DIR) not in sys.path:
    sys.path.insert(0, str(WEB_DIR))

import app as dashboard


class LinuxWebDashboardTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = dashboard.ThreadingHTTPServer(("127.0.0.1", 0), dashboard.DashboardHandler)
        cls.server_thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.server_thread.start()
        cls.port = cls.server.server_address[1]

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.server_thread.join(timeout=2)

    def request(self, method, path, body=None, headers=None):
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=3)
        connection.request(method, path, body=body, headers=headers or {})
        response = connection.getresponse()
        payload = response.read()
        result = (response.status, response.getheaders(), payload)
        connection.close()
        return result

    def same_origin_headers(self, content_type=False):
        headers = {"Origin": f"http://127.0.0.1:{self.port}"}
        if content_type:
            headers["Content-Type"] = "application/json"
        return headers

    def test_state_uses_durable_queue_snapshot_and_sets_private_response_headers(self):
        queue = [{
            "id": "job-1",
            "status": "Waiting for network/provider",
            "file_name": "sample.txt",
            "destination_path": "folder/sample.txt",
            "account_id": "account-1",
            "provider": "gdrive",
            "operation": "Upload",
            "size_bytes": 2048,
            "bytes_transferred": 1024,
            "percentage": 50,
        }]
        with mock.patch.object(dashboard, "_read_system_state", return_value={"service": "active (enabled)", "mounts": []}), \
             mock.patch.object(dashboard, "load_settings", return_value={"Accounts": []}), \
             mock.patch.object(dashboard, "load_transfer_queue", return_value=queue), \
             mock.patch.object(dashboard.subprocess, "run", side_effect=AssertionError("dashboard state must not spawn a CLI")):
            status, headers, body = self.request("GET", "/api/state")

        data = json.loads(body)
        response_headers = {key.lower(): value for key, value in headers}
        self.assertEqual(status, 200)
        self.assertEqual(data["queue_summary"]["active"], 1)
        self.assertEqual(data["queue"][0]["destination_path"], "folder/sample.txt")
        self.assertEqual(response_headers["cache-control"], "no-store")
        self.assertEqual(response_headers["x-content-type-options"], "nosniff")
        self.assertNotIn("access-control-allow-origin", response_headers)

    def test_cross_site_get_without_origin_is_rejected(self):
        status, _, body = self.request("GET", "/api/state", headers={"Sec-Fetch-Site": "cross-site"})
        self.assertEqual(status, 403)
        self.assertIn(b"same-origin", body)

    def test_cross_origin_mutation_is_rejected_before_running_commands(self):
        body = json.dumps({"action": "mount_all"})
        with mock.patch.object(dashboard.subprocess, "run", side_effect=AssertionError("cross-origin command must not run")):
            status, _, _ = self.request(
                "POST",
                "/api/action",
                body=body,
                headers={"Origin": "http://attacker.invalid", "Content-Type": "application/json"},
            )
        self.assertEqual(status, 403)

    def test_asset_path_traversal_is_rejected(self):
        status, _, body = self.request("GET", "/assets/%2e%2e/%2e%2e/src/NSCloudDrive.ps1")
        self.assertEqual(status, 404)
        self.assertNotIn(b"Set-StrictMode", body)

    def test_manual_login_secrets_are_sent_outside_command_arguments(self):
        fake_result = SimpleNamespace(returncode=0, stdout="", stderr="")
        payload = json.dumps({
            "provider": "terabox",
            "name": "Test account",
            "cookie": "secret-cookie-value",
            "jstoken": "secret-token-value",
        })
        with mock.patch.object(dashboard.subprocess, "run", return_value=fake_result) as run_mock:
            status, _, response_body = self.request(
                "POST",
                "/api/login/manual",
                body=payload,
                headers=self.same_origin_headers(content_type=True),
            )

        self.assertEqual(status, 200)
        self.assertTrue(json.loads(response_body)["success"])
        login_call = next(call for call in run_mock.call_args_list if "--login-secrets-from-env" in call.args[0])
        self.assertNotIn("secret-cookie-value", " ".join(login_call.args[0]))
        self.assertNotIn("secret-token-value", " ".join(login_call.args[0]))
        self.assertEqual(login_call.kwargs["env"]["NS_CLOUD_DRIVE_LOGIN_COOKIE"], "secret-cookie-value")
        self.assertEqual(login_call.kwargs["env"]["NS_CLOUD_DRIVE_LOGIN_JSTOKEN"], "secret-token-value")
        self.assertNotIn("secret-cookie-value", response_body.decode("utf-8"))

    def test_transfer_queue_reader_uses_configured_data_root(self):
        with tempfile.TemporaryDirectory() as data_root:
            state_dir = pathlib.Path(data_root) / "state"
            state_dir.mkdir()
            (state_dir / "transfer-jobs.json").write_text(json.dumps({"Jobs": [{
                "QueueId": "queue-1",
                "Status": "Queued",
                "FileName": "x.bin",
                "DestinationFilePath": "x.bin",
                "FileSizeBytes": "not-a-number",
                "BytesTransferred": -1,
                "Percentage": 150,
            }]}), encoding="utf-8")
            with mock.patch.dict(os.environ, {"NS_CLOUD_DRIVE_DATA_DIR": data_root}, clear=False):
                queue = dashboard.load_transfer_queue()

        self.assertEqual(len(queue), 1)
        self.assertEqual(queue[0]["size_bytes"], 0)
        self.assertEqual(queue[0]["bytes_transferred"], 0)
        self.assertEqual(queue[0]["percentage"], 100)

    def test_transfer_queue_reader_falls_back_to_versioned_backup(self):
        with tempfile.TemporaryDirectory() as data_root:
            state_dir = pathlib.Path(data_root) / "state"
            state_dir.mkdir()
            (state_dir / "transfer-jobs.json").write_text("{broken", encoding="utf-8")
            (state_dir / "transfer-jobs.json.bak.20261125T120000Z").write_text(
                json.dumps({"Jobs": [{"QueueId": "recovered", "Status": "Queued"}]}),
                encoding="utf-8",
            )
            with mock.patch.dict(os.environ, {"NS_CLOUD_DRIVE_DATA_DIR": data_root}, clear=False):
                queue = dashboard.load_transfer_queue()
        self.assertEqual([job["id"] for job in queue], ["recovered"])

    def test_missing_snapshot_after_initialization_is_not_reported_as_empty(self):
        with tempfile.TemporaryDirectory() as data_root:
            state_dir = pathlib.Path(data_root) / "state"
            state_dir.mkdir()
            (state_dir / "transfer-jobs.json.initialized").write_text("initialized", encoding="utf-8")
            with mock.patch.dict(os.environ, {"NS_CLOUD_DRIVE_DATA_DIR": data_root}, clear=False):
                with self.assertRaises(ValueError):
                    dashboard.load_transfer_queue()

    def test_windows_paths_match_powershell_configuration_roots(self):
        with tempfile.TemporaryDirectory() as local_app_data:
            with mock.patch.object(dashboard.sys, "platform", "win32"), \
                 mock.patch.dict(os.environ, {"LOCALAPPDATA": local_app_data}, clear=False):
                self.assertEqual(
                    dashboard.get_settings_path(),
                    os.path.join(local_app_data, "NSCloudDrive", "config", "settings.json"),
                )


if __name__ == "__main__":
    unittest.main()
