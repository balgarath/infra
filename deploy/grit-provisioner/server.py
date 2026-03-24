#!/usr/bin/env python3
"""GRIT Provisioner — bridges Moodle course completion webhooks to GRIT API."""

import hmac
import json
import logging
import os
import urllib.request
import urllib.error
from http.server import HTTPServer, BaseHTTPRequestHandler

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("grit-provisioner")

GRIT_API_URL = os.environ.get("GRIT_API_URL", "")
GRIT_API_KEY = os.environ.get("GRIT_API_KEY", "")
WEBHOOK_SECRET = os.environ.get("WEBHOOK_SECRET", "")
SLACK_WEBHOOK_URL = os.environ.get("SLACK_WEBHOOK_URL", "")
COURSE_TOOL_MAP_PATH = os.environ.get("COURSE_TOOL_MAP_PATH", "/app/course-tool-map.json")


def load_course_map():
    try:
        with open(COURSE_TOOL_MAP_PATH) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError) as e:
        log.warning("Could not load course-tool-map: %s", e)
        return {}


def notify_slack(message):
    if not SLACK_WEBHOOK_URL:
        return
    try:
        data = json.dumps({"text": message}).encode()
        req = urllib.request.Request(
            SLACK_WEBHOOK_URL, data=data,
            headers={"Content-Type": "application/json"},
        )
        urllib.request.urlopen(req, timeout=10)
    except Exception as e:
        log.error("Slack notification failed: %s", e)


def provision_grit(tool_id, user_email, tool_name):
    if not GRIT_API_URL:
        log.warning("GRIT_API_URL not configured — skipping provisioning")
        return
    try:
        data = json.dumps({"tool": tool_id, "user_email": user_email}).encode()
        req = urllib.request.Request(
            f"{GRIT_API_URL}/provision",
            data=data,
            headers={
                "Content-Type": "application/json",
                "Authorization": f"Bearer {GRIT_API_KEY}",
            },
        )
        urllib.request.urlopen(req, timeout=30)
        log.info("Provisioned %s for %s", tool_name, user_email)
        notify_slack(f"Provisioned *{tool_name}* access for {user_email}")
    except Exception as e:
        log.error("GRIT provisioning failed for %s (%s): %s", user_email, tool_name, e)
        notify_slack(
            f"Failed to provision *{tool_name}* for {user_email}. "
            f"Error: {e}. Staff should provision manually."
        )


class Handler(BaseHTTPRequestHandler):
    course_map = {}

    def log_message(self, format, *args):
        log.info(format, *args)

    def _respond(self, status, body):
        payload = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def _drain_request_body(self):
        length = int(self.headers.get("Content-Length", 0))
        if length:
            self.rfile.read(length)

    def do_GET(self):
        if self.path == "/health":
            self._respond(200, {"status": "ok"})
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        if self.path != "/webhook":
            self._drain_request_body()
            self.send_response(404)
            self.end_headers()
            return

        # Validate webhook secret
        secret = self.headers.get("X-Webhook-Secret", "")
        if not hmac.compare_digest(secret, WEBHOOK_SECRET):
            self._drain_request_body()
            log.warning("Invalid webhook secret from %s", self.client_address[0])
            self._respond(403, {"error": "forbidden"})
            return

        # Parse body
        try:
            length = int(self.headers.get("Content-Length", 0))
            body = json.loads(self.rfile.read(length))
        except (json.JSONDecodeError, ValueError):
            self._respond(400, {"error": "invalid json"})
            return

        course_id = str(body.get("courseid", ""))
        user_email = body.get("useremail", "unknown")

        # Look up tool mapping
        mapping = self.course_map.get(course_id)
        if not mapping:
            log.info("Course %s not in tool map — ignoring", course_id)
            self._respond(200, {"status": "ignored", "reason": "unmapped course"})
            return

        # Provision access
        provision_grit(mapping["grit_tool"], user_email, mapping["name"])
        self._respond(200, {"status": "provisioned"})


def create_server(port=8000):
    if not WEBHOOK_SECRET:
        raise RuntimeError("WEBHOOK_SECRET environment variable must be set")
    Handler.course_map = load_course_map()
    server = HTTPServer(("0.0.0.0", port), Handler)
    return server


if __name__ == "__main__":
    port = int(os.environ.get("PORT", "8000"))
    server = create_server(port)
    log.info("GRIT Provisioner listening on port %d", port)
    server.serve_forever()
