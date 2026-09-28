"""Small service probes and safe, single-line application events."""
import json
import os
import threading
from contextlib import closing
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import httpx
import psycopg2
import config


def log(event, level="INFO", **fields):
    # Callers supply identifiers and safe codes only, never bodies or exception text.
    print(json.dumps({"timestamp": datetime.now(timezone.utc).isoformat(), "event": event,
                      "level": level, "service": os.environ.get("SERVICE_NAME", "python"),
                      **fields}, default=str, separators=(",", ":")), flush=True)


def failpoint(name, instance_id):
    if config.COURSE_TEST_PROFILE == "1" and os.environ.get("COURSE_FAILPOINT") == name:
        log("failpoint.reached", name=name, instanceId=instance_id)
        threading.Event().wait()


def database_ready():
    with closing(psycopg2.connect(config.DATABASE_URL, connect_timeout=2, options="-c statement_timeout=2000")) as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT 1")
            return cur.fetchone()[0] == 1


def gateway_ready():
    from urllib.parse import urlsplit, urlunsplit
    target = urlsplit(config.RECEIPT_API_URL)
    url = urlunsplit((target.scheme, target.netloc, "/health/ready", "", ""))
    return httpx.get(url, timeout=2).status_code == 200


class ProbeHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def do_GET(self):
        if self.path == "/metrics":
            body = b"# TYPE component_up gauge\ncomponent_up 1\n# EOF\n"
            status, content_type = 200, "application/openmetrics-text; version=1.0.0; charset=utf-8"
        else:
            status, data = 200, {"status": "live"}
            if self.path == "/health/ready":
                try:
                    ready = self.server.ready()
                except Exception:
                    ready = False
                status, data = (200, {"status": "ready"}) if ready else (503, {"status": "not_ready", "code": "dependency.unavailable"})
            elif self.path != "/health/live":
                status, data = 404, {"status": "error", "code": "route.not_found"}
            body, content_type = json.dumps(data).encode(), "application/json"
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class Server(ThreadingHTTPServer):
    def handle_error(self, request, client_address):
        log("http.error", "WARNING", errorCode="http.request_failed")


def start_probes():
    # Probes stay responsive while the polling loop waits on I/O or a test failpoint.
    server = Server(("", 8080), ProbeHandler)
    server.ready = database_ready
    threading.Thread(target=server.serve_forever, daemon=True).start()
