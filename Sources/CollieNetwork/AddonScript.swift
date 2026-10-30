/// mitmproxy addon emitting the JSON-line protocol documented in AddonProtocol.swift.
/// Kept as a string so collied can write it to disk without a resource bundle.
public enum AddonScript {
    public static let source = #"""
import base64, json, sys
from mitmproxy import ctx

def _emit(obj):
    sys.stdout.write(json.dumps(obj, separators=(",", ":")) + "\n")
    sys.stdout.flush()

def _headers(h):
    return [{"name": k, "value": v} for k, v in h.items(multi=True)]

def _body(msg):
    raw = msg.raw_content
    if not raw:
        return None
    cap = ctx.options.collie_body_cap
    return {"size": len(raw), "truncated": len(raw) > cap,
            "contentEncoding": msg.headers.get("content-encoding"),
            "data": base64.b64encode(raw[:cap]).decode("ascii")}

def _alpn(v):
    return v.decode("ascii", "replace") if isinstance(v, bytes) else v

class Collie:
    def load(self, loader):
        loader.add_option("collie_body_cap", int, 10 * 1024 * 1024, "Max body bytes sent per message")

    def request(self, flow):
        r, c = flow.request, flow.client_conn
        tls = {"sni": c.sni, "alpn": _alpn(c.alpn)} if c.tls_established else None
        _emit({"type": "request", "id": flow.id, "ts": r.timestamp_start, "method": r.method,
               "url": r.pretty_url, "httpVersion": r.http_version, "headers": _headers(r.headers),
               "body": _body(r), "tls": tls})

    def response(self, flow):
        r = flow.response
        _emit({"type": "response", "id": flow.id, "ttfb": r.timestamp_start, "ts": r.timestamp_end or r.timestamp_start,
               "status": r.status_code, "reason": r.reason, "headers": _headers(r.headers), "body": _body(r)})

    def error(self, flow):
        _emit({"type": "error", "id": flow.id, "ts": flow.error.timestamp, "message": flow.error.msg})

    def websocket_start(self, flow):
        _emit({"type": "tunneled", "id": flow.id, "ts": flow.websocket.timestamp_opened})

addons = [Collie()]
"""#
}
