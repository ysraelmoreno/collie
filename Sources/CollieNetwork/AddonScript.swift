/// mitmproxy addon emitting the JSON-line protocol documented in AddonProtocol.swift.
/// Kept as a string so collied can write it to disk without a resource bundle.
public enum AddonScript {
    public static let source = #"""
import asyncio, base64, fnmatch, json, os, sys
from mitmproxy import ctx, http

def _emit(obj, rule=None):
    if rule:
        obj["mappedBy"] = rule
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

def _matches(m, r):
    if m.get("method") and m["method"].upper() != r.method.upper():
        return False
    if m.get("host") and not fnmatch.fnmatchcase(r.pretty_host.lower(), m["host"].lower()):
        return False
    if m.get("path") and not fnmatch.fnmatchcase(r.path.split("?", 1)[0], m["path"]):
        return False
    for k, v in (m.get("query") or {}).items():
        if v not in r.query.get_all(k):
            return False
    return True

class Collie:
    def __init__(self):
        self.rules, self.stamp = [], None

    def load(self, loader):
        loader.add_option("collie_body_cap", int, 10 * 1024 * 1024, "Max body bytes sent per message")
        loader.add_option("collie_rules", str, "", "Map rules file written by collied")

    # The daemon replaces the file atomically; it is reread when it changes. Unreadable, invalid or of an unknown
    # version: the previous rules stay. Gone: no rules.
    def _rules(self):
        path = ctx.options.collie_rules
        if not path:
            return []
        try:
            st = os.stat(path)
        except OSError:
            self.rules, self.stamp = [], None
            return []
        stamp = (st.st_mtime_ns, st.st_ino, st.st_size)
        if stamp != self.stamp:
            self.stamp = stamp
            try:
                with open(path, "rb") as f:
                    d = json.load(f)
                if d.get("v") != 1 or not isinstance(d.get("rules"), list):
                    raise ValueError("unknown rules file")
                self.rules = [x for x in d["rules"] if isinstance(x, dict) and x.get("enabled", True)]
            except Exception as e:
                ctx.log.warn("collie: rules file ignored: %s" % e)
        return self.rules

    def _rule(self, r):
        for rule in self._rules():
            try:
                if _matches(rule.get("match") or {}, r):
                    return rule
            except Exception:
                pass
        return None

    async def request(self, flow):
        r, c = flow.request, flow.client_conn
        rule = self._rule(r)
        rid = rule.get("id") if rule else None
        if rid:
            flow.metadata["collie_rule"] = rid
        tls = {"sni": c.sni, "alpn": _alpn(c.alpn)} if c.tls_established else None
        _emit({"type": "request", "id": flow.id, "ts": r.timestamp_start, "method": r.method,
               "url": r.pretty_url, "httpVersion": r.http_version, "headers": _headers(r.headers),
               "body": _body(r), "tls": tls}, rid)
        if not rule:
            return
        delay = rule.get("delayMs") or 0
        if delay > 0:
            await asyncio.sleep(delay / 1000)
        action = rule.get("action") or {}
        if "local" not in action:
            flow.kill()
            return
        a = action["local"]
        body = base64.b64decode(a.get("bodyB64") or "")
        headers = [(h["name"].encode(), h["value"].encode()) for h in a.get("headers") or []]
        flow.response = http.Response.make(int(a.get("status", 200)), body, headers)

    def response(self, flow):
        r = flow.response
        _emit({"type": "response", "id": flow.id, "ttfb": r.timestamp_start, "ts": r.timestamp_end or r.timestamp_start,
               "status": r.status_code, "reason": r.reason, "headers": _headers(r.headers), "body": _body(r)},
              flow.metadata.get("collie_rule"))

    def error(self, flow):
        _emit({"type": "error", "id": flow.id, "ts": flow.error.timestamp, "message": flow.error.msg},
              flow.metadata.get("collie_rule"))

    def websocket_start(self, flow):
        _emit({"type": "tunneled", "id": flow.id, "ts": flow.websocket.timestamp_opened})

addons = [Collie()]
"""#
}
