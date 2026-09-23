"""A fake mobile proxy + rotation link for testing the action without a real modem.

It answers plain-HTTP proxy requests (absolute-URI GETs, which is what curl
sends for an http:// URL through an http proxy) with ipinfo-style JSON, checks
Proxy-Authorization, and serves a rotation link at /rotate on the same port.

    python mock_proxy.py PORT USER PASS COUNTRY ORG [--rotate-429]

The IP ends in the rotation count, so each successful rotation changes it.
With --rotate-429 the first rotation call answers 429 with Retry-After: 1.
"""

import base64
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

port, user, password, country, org = sys.argv[1:6]
rotate_429 = "--rotate-429" in sys.argv[6:]
state = {"ip_suffix": 10, "rotate_calls": 0}
expected_auth = "Basic " + base64.b64encode(f"{user}:{password}".encode()).decode()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        sys.stderr.write("mock: " + (fmt % args) + "\n")

    def _send(self, code, body, headers=None):
        data = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path.startswith("/rotate"):  # origin-form: the rotation link
            state["rotate_calls"] += 1
            if rotate_429 and state["rotate_calls"] == 1:
                return self._send(429, '{"error":"cooldown"}', {"Retry-After": "1"})
            state["ip_suffix"] += 1
            return self._send(200, '{"status":"ok"}')
        if self.path.startswith("http://"):  # absolute-form: proxied request
            if self.headers.get("Proxy-Authorization") != expected_auth:
                return self._send(407, '{"error":"bad proxy auth"}',
                                  {"Proxy-Authenticate": 'Basic realm="mock"'})
            return self._send(200, json.dumps({
                "ip": f"119.234.8.{state['ip_suffix']}",
                "country": country,
                "org": org,
            }, indent=2))
        return self._send(404, '{"error":"not found"}')


ThreadingHTTPServer(("127.0.0.1", int(port)), Handler).serve_forever()
