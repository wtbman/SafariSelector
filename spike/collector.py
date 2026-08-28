import json, os, sys, time
from http.server import BaseHTTPRequestHandler, HTTPServer

OUT = sys.argv[1]

class H(BaseHTTPRequestHandler):
    def _cors(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.send_header("Access-Control-Allow-Methods", "POST, OPTIONS")

    def do_OPTIONS(self):
        self.send_response(204); self._cors(); self.end_headers()

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(n)
        try:
            obj = json.loads(raw)
            label = obj.get("label", "report")
        except Exception:
            obj, label = {"raw": raw.decode("utf8", "replace")}, "unparsed"
        path = os.path.join(OUT, f"{label}-{int(time.time()*1000)}.json")
        with open(path, "w") as f:
            json.dump(obj, f, indent=2, sort_keys=True)
        print("wrote", path, flush=True)
        self.send_response(200); self._cors()
        self.send_header("Content-Type", "application/json"); self.end_headers()
        self.wfile.write(b'{"ok":true}')

    def log_message(self, *a):
        pass

HTTPServer(("127.0.0.1", 8787), H).serve_forever()
