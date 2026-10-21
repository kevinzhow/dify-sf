"""A local SMTP capture (the review's "本地镜像") plus an HTTP view of what it received.

  python3 capture.py            # listens on 127.0.0.1:2525 (SMTP) and 8025 (HTTP list of the captured messages)

The HTTP side answers the whole captured conversation as one text page, so a test can find the mailed link with a regex
(`/form/<token>`), as it would find it in a mail client.
"""
import email
import http.server
import socketserver
import threading

MESSAGES = []


class SMTP(socketserver.StreamRequestHandler):
    def handle(self):
        w = self.wfile.write
        w(b"220 capture.local ESMTP\r\n")
        data_mode = False
        body = []
        while True:
            line = self.rfile.readline()
            if not line:
                return
            text = line.decode("utf-8", "replace").rstrip("\r\n")
            if data_mode:
                if text == ".":
                    data_mode = False
                    MESSAGES.append("\n".join(body))
                    body = []
                    w(b"250 OK\r\n")
                else:
                    body.append(text)
                continue
            upper = text.upper()
            if upper.startswith("EHLO") or upper.startswith("HELO"):
                w(b"250-capture.local\r\n250 8BITMIME\r\n")
            elif upper.startswith("MAIL FROM:") or upper.startswith("RCPT TO:") or upper in ("RSET", "NOOP"):
                w(b"250 OK\r\n")
            elif upper == "DATA":
                data_mode = True
                w(b"354 End data with <CR><LF>.<CR><LF>\r\n")
            elif upper == "QUIT":
                w(b"221 Bye\r\n")
                return
            else:
                w(b"250 OK\r\n")


class HTTP(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        # The raw messages, decoded bodies included: the test looks for the link where a reader would.
        out = []
        for raw in MESSAGES:
            msg = email.message_from_string(raw)
            for part in msg.walk():
                if part.get_content_maintype() == "text":
                    payload = part.get_payload(decode=True) or b""
                    out.append(payload.decode(part.get_content_charset() or "utf-8", "replace"))
        body = "\n".join(out).encode()
        if self.path.startswith("/all"):
            body = ("\n---\n".join(MESSAGES)).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_DELETE(self):
        MESSAGES.clear()
        self.send_response(204)
        self.end_headers()

    def log_message(self, *a):
        pass


class Reuse(socketserver.TCPServer):
    allow_reuse_address = True


for port, handler in ((2525, SMTP), (8025, HTTP)):
    srv = Reuse(("0.0.0.0", port), handler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
print("capture: SMTP 0.0.0.0:2525, HTTP 0.0.0.0:8025", flush=True)
threading.Event().wait()
