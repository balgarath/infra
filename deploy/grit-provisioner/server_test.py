import json
import os
import sys
import tempfile
import unittest
from http.client import HTTPConnection
from threading import Thread

# Set env vars before importing server
os.environ["GRIT_API_URL"] = "http://localhost:19876"
os.environ["GRIT_API_KEY"] = "test-grit-key"
os.environ["WEBHOOK_SECRET"] = "test-secret"
os.environ["SLACK_WEBHOOK_URL"] = ""

# Create temp course-tool-map
_MAP_FILE = tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False)
json.dump({"3": {"grit_tool": "laser_cutter", "name": "Laser Cutter"}}, _MAP_FILE)
_MAP_FILE.flush()
os.environ["COURSE_TOOL_MAP_PATH"] = _MAP_FILE.name

sys.path.insert(0, os.path.dirname(__file__))
from server import create_server


class TestGritProvisioner(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = create_server(port=18765)
        cls.thread = Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def _request(self, method, path, body=None, headers=None):
        conn = HTTPConnection("localhost", 18765)
        hdrs = headers or {}
        if body is not None:
            hdrs["Content-Type"] = "application/json"
            body = json.dumps(body).encode()
        conn.request(method, path, body=body, headers=hdrs)
        resp = conn.getresponse()
        data = resp.read().decode()
        conn.close()
        return resp.status, data

    def test_health_returns_200(self):
        status, _ = self._request("GET", "/health")
        self.assertEqual(status, 200)

    def test_missing_secret_returns_403(self):
        status, _ = self._request("POST", "/webhook", body={"courseid": "3"})
        self.assertEqual(status, 403)

    def test_wrong_secret_returns_403(self):
        status, _ = self._request(
            "POST", "/webhook",
            body={"courseid": "3"},
            headers={"X-Webhook-Secret": "wrong"},
        )
        self.assertEqual(status, 403)

    def test_unmapped_course_returns_200(self):
        status, _ = self._request(
            "POST", "/webhook",
            body={"courseid": "999", "userid": "1", "useremail": "a@b.com"},
            headers={"X-Webhook-Secret": "test-secret"},
        )
        self.assertEqual(status, 200)

    def test_malformed_json_returns_400(self):
        conn = HTTPConnection("localhost", 18765)
        conn.request(
            "POST", "/webhook",
            body=b"not json",
            headers={"Content-Type": "application/json", "X-Webhook-Secret": "test-secret"},
        )
        resp = conn.getresponse()
        resp.read()
        conn.close()
        self.assertEqual(resp.status, 400)


if __name__ == "__main__":
    unittest.main()
