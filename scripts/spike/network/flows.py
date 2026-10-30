"""mitmdump addon: one JSON line per finished flow on stdout (what collied would parse)."""
import json
from mitmproxy import http


def response(flow: http.HTTPFlow) -> None:
    print(json.dumps({
        "method": flow.request.method,
        "url": flow.request.pretty_url,
        "status": flow.response.status_code,
        "http": flow.response.http_version,
        "alpn": (flow.client_conn.alpn or b"").decode(),
        "sni": flow.client_conn.sni,
        "client": flow.client_conn.peername[0] if flow.client_conn.peername else None,
    }), flush=True)


def tls_failed_client(data) -> None:
    # client refused our leaf: pinning or a CA the app does not trust
    print(json.dumps({"tls_failed": data.context.client.sni, "error": str(data.conn.error)}), flush=True)
