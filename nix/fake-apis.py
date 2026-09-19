"""Stand-ins for TypeSafe System One and Resend in the VM test.

System One answers every Noul with 0.95 when the log mentions "killed by OOM"
(0.02 otherwise) and every Choice with its first option. Resend appends each
request body to /tmp/emails.jsonl and records Authorization headers so the
test can prove decrypted keys were used.
"""

import json
from http.server import BaseHTTPRequestHandler, HTTPServer


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        with open("/tmp/authorization.log", "a") as log:
            log.write(f"{self.path} {self.headers.get('Authorization')}\n")
        if self.path == "/v1/systemone":
            unhealthy = "killed by OOM" in body["state"]["log"]
            answers = {}
            for key, question in body["questions"].items():
                if question["type"] == "noul":
                    answers[key] = {"type": "noul", "noul": 0.95 if unhealthy else 0.02}
                else:
                    options = list(question["criteria"])
                    probabilities = {option: 0.0 for option in options}
                    probabilities[options[0]] = 1.0
                    answers[key] = {
                        "type": "choice",
                        "choice": options[0],
                        "probabilities": probabilities,
                        "confidence": 1.0,
                    }
            self.reply({"model": "jev-fake", "answers": answers, "usage": {"input_tokens": 1, "output_tokens": 1}})
        elif self.path == "/emails":
            with open("/tmp/emails.jsonl", "a") as emails:
                emails.write(json.dumps(body) + "\n")
            self.reply({"id": "fake"})
        else:
            self.send_response(404)
            self.end_headers()

    def reply(self, payload):
        data = json.dumps(payload).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


HTTPServer(("127.0.0.1", 8080), Handler).serve_forever()
