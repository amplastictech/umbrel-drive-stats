"""Drive Stats: reports usage of the main drive and each external drive.

Read-only. Uses statvfs only; never opens or writes files on the drives.
"""
import html
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = os.environ.get("DRIVES_ROOT", "/external")
PORT = int(os.environ.get("PORT", "8080"))


def human(n):
    for unit in ("B", "K", "M", "G", "T", "P"):
        if n < 1024 or unit == "P":
            return f"{n:.1f}{unit}" if unit in ("T", "P") else f"{n:.0f}{unit}"
        n /= 1024


def usage(path):
    st = os.statvfs(path)
    total = st.f_blocks * st.f_frsize
    free = st.f_bavail * st.f_frsize
    used = total - st.f_bfree * st.f_frsize
    # Same formula as df: used / (used + available)
    pct = round(100 * used / (used + free)) if used + free else 0
    return {"total": total, "free": free, "used": used, "pct": pct}


def drives():
    """Main drive first, then mounted external drives sorted by name.

    Folders under the external root that are not mount points (leftover
    ghost folders from old mounts) are skipped.
    """
    out = []
    try:
        out.append({"name": "Main", **usage(ROOT)})  # root folder sits on the main drive
    except OSError:
        pass
    try:
        names = sorted(os.listdir(ROOT))  # case-sensitive: Seagate1, Seagate2, T7, btc-node
    except OSError:
        names = []
    for name in names:
        path = os.path.join(ROOT, name)
        if os.path.isdir(path) and os.path.ismount(path):
            try:
                out.append({"name": name, **usage(path)})
            except OSError:
                continue
    return out


def text_bar(pct, width=6):
    filled = min(width, max(0, round(pct * width / 100)))
    return "█" * filled + "░" * (width - filled)


def bars_widget():
    """Four tiles, one per external drive, each with a text progress bar."""
    items = [
        {"title": f'{d["name"]} {d["pct"]}%', "text": text_bar(d["pct"]), "subtext": f'{human(d["free"])} free'}
        for d in drives() if d["name"] != "Main"
    ][:4]
    while len(items) < 4:
        items.append({"title": "-", "text": "-", "subtext": ""})
    return {"type": "four-stats", "link": "", "items": items}


def gauge_widget(pair):
    """Two ring gauges: externals 1-2 for pair 0, externals 3-4 for pair 1."""
    ext = [d for d in drives() if d["name"] != "Main"][pair * 2:pair * 2 + 2]
    items = [
        {"title": d["name"], "text": str(d["pct"]), "subtext": "%", "progress": d["pct"] / 100}
        for d in ext
    ]
    while len(items) < 2:
        items.append({"title": "-", "text": "-", "subtext": "", "progress": 0})
    return {"type": "two-stats-with-guage", "link": "", "items": items}


def all_widget():
    return {
        "type": "list",
        "link": "",
        "items": [
            {"text": f'{d["name"]}  {d["pct"]}%', "subtext": f'{text_bar(d["pct"])}  {human(d["free"])} free of {human(d["total"])}'}
            for d in drives()
        ],
        "noItemsText": "No drives found",
    }


def page():
    rows = []
    for d in drives():
        color = "#d64545" if d["pct"] >= 90 else "#e0a030" if d["pct"] >= 75 else "#3fa66b"
        rows.append(
            f'<div class="row"><div class="top"><b>{html.escape(d["name"])}</b>'
            f'<span>{d["pct"]}% &middot; {human(d["free"])} free of {human(d["total"])}</span></div>'
            f'<div class="bar"><div style="width:{d["pct"]}%;background:{color}"></div></div></div>'
        )
    return f"""<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="refresh" content="30"><title>Drive Stats</title>
<style>
:root{{--bg:#fff;--fg:#111;--muted:#666;--track:#e6e6e6}}
@media (prefers-color-scheme:dark){{:root{{--bg:#111;--fg:#eee;--muted:#999;--track:#2a2a2a}}}}
body{{background:var(--bg);color:var(--fg);font:15px system-ui,sans-serif;margin:0;padding:24px 16px}}
main{{max-width:640px;margin:0 auto}} h1{{font-size:20px;margin:0 0 20px}}
.row{{margin-bottom:18px}} .top{{display:flex;justify-content:space-between;gap:12px;margin-bottom:6px}}
.top span{{color:var(--muted)}} .bar{{height:10px;background:var(--track);border-radius:5px;overflow:hidden}}
.bar div{{height:100%;border-radius:5px}}
</style></head><body><main><h1>Drive Stats</h1>{''.join(rows) or '<p>No drives found</p>'}</main></body></html>"""


class Handler(BaseHTTPRequestHandler):
    def _send(self, body, ctype):
        data = body.encode()
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        path = self.path.split("?")[0].rstrip("/")
        if path == "/widgets/bars":
            self._send(json.dumps(bars_widget()), "application/json")
        elif path == "/widgets/gauges-1":
            self._send(json.dumps(gauge_widget(0)), "application/json")
        elif path == "/widgets/gauges-2":
            self._send(json.dumps(gauge_widget(1)), "application/json")
        elif path == "/widgets/all":
            self._send(json.dumps(all_widget()), "application/json")
        elif path == "/api/drives":
            self._send(json.dumps(drives()), "application/json")
        else:
            self._send(page(), "text/html; charset=utf-8")

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
