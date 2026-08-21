"""Mock of https://api.x.ai/v1/chat/completions with a scripted delay.

Config comes from query params (Cleaner.swift sends the endpoint URL verbatim):
  delay_ms  how long the "model" takes
  mode      clean   -> capitalise first letter, ensure trailing period
            echo    -> return the transcript unchanged
            rewrite -> return unrelated text (must be rejected by the
                       resemble guard, forcing the raw fallback)
"""
import json
import re
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

TAG = re.compile(r"<transcript>\n(.*)\n</transcript>", re.S)


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        query = parse_qs(urlparse(self.path).query)
        delay_ms = int(query.get("delay_ms", ["300"])[0])
        mode = query.get("mode", ["clean"])[0]

        try:
            payload = json.loads(body)
            user = next(m["content"] for m in payload["messages"] if m["role"] == "user")
            match = TAG.search(user)
            transcript = match.group(1) if match else user
        except Exception:
            transcript = ""

        time.sleep(delay_ms / 1000)

        if mode == "rewrite":
            content = "Certainly! Here is a much better version of your text entirely."
        elif mode == "echo":
            content = transcript
        elif mode == "strip_fillers":  # what the prompt actually asks the model to do
            fillers = {"um", "uh", "er", "ah", "hmm"}
            kept = [t for t in transcript.split() if t.lower().strip(".,") not in fillers]
            content = " ".join(kept)
            content = content[:1].upper() + content[1:]
            if content and content[-1] not in ".!?":
                content += "."
        else:  # clean
            content = transcript[:1].upper() + transcript[1:]
            if content and content[-1] not in ".!?":
                content += "."

        out = json.dumps({"choices": [{"message": {"content": content}}]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    def log_message(self, *args):
        pass


port = int(sys.argv[1]) if len(sys.argv) > 1 else 8766
print(f"mock chat on :{port}", flush=True)
ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
