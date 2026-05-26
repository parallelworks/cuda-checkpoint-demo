#!/usr/bin/env python3
"""
server.py — Web dashboard for the CUDA Mandelbrot checkpoint demo.

Reads from the shared/ directory (one level up):
  progress.json  — computation stats written by mandelbrot
  preview.ppm    — 512×512 live preview written by mandelbrot
  mandelbrot.log — stdout log (if run with nohup redirect)

Endpoints:
  GET /              HTML dashboard, auto-refreshes every 5 s
  GET /api/progress  Raw progress.json
  GET /api/image     Current preview as PNG (converted from PPM)
  GET /api/log       Last 60 lines of mandelbrot.log
"""

import base64
import io
import json
import os
from pathlib import Path

from flask import Flask, Response, send_file

# ── Path configuration ────────────────────────────────────────────────────────
# Shared data lives one directory above this script (at project root).
SCRIPT_DIR  = Path(__file__).resolve().parent
SHARED_DIR  = SCRIPT_DIR.parent / "shared"
PROGRESS    = SHARED_DIR / "progress.json"
PREVIEW_PPM = SHARED_DIR / "preview.ppm"
LOG_FILE    = SHARED_DIR / "mandelbrot.log"

app = Flask(__name__)

# ── Helpers ───────────────────────────────────────────────────────────────────
def _read_progress() -> dict:
    try:
        return json.loads(PROGRESS.read_text())
    except Exception:
        return {"status": "not started", "percent": 0}


def _ppm_to_png(path: Path) -> bytes:
    from PIL import Image
    img = Image.open(path)
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    return buf.getvalue()


def _placeholder_png(msg: str = "") -> bytes:
    from PIL import Image, ImageDraw
    img = Image.new("RGB", (512, 512), (18, 18, 18))
    if msg:
        ImageDraw.Draw(img).text((10, 250), msg, fill=(80, 80, 80))
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    return buf.getvalue()


def _image_data_uri() -> str:
    """Return the preview as a base64 data URI, embedded directly in the HTML.
    This avoids a secondary browser request which can be blocked by tunnels/proxies."""
    if PREVIEW_PPM.exists():
        try:
            from PIL import Image, ImageOps
            img = Image.open(PREVIEW_PPM)
            # Stretch the histogram so the brightest pixel reaches 255.
            # cutoff=0.5 ignores the top/bottom 0.5% of pixels to avoid
            # a single bright outlier dominating the scale.
            img = ImageOps.autocontrast(img, cutoff=0.5)
            buf = io.BytesIO()
            img.save(buf, format="PNG")
            return "data:image/png;base64," + base64.b64encode(buf.getvalue()).decode()
        except Exception:
            pass
    data = _placeholder_png("Waiting for computation to start…")
    return "data:image/png;base64," + base64.b64encode(data).decode()


# ── Routes ────────────────────────────────────────────────────────────────────
@app.route("/")
def index():
    p   = _read_progress()
    pct = float(p.get("percent", 0))
    st  = p.get("status", "not started")
    bar_color = {"running": "#1a8fff", "complete": "#22c55e"}.get(st, "#555")
    tag_bg    = {"running": "#0f3c6e", "complete": "#14532d"}.get(st, "#333")

    rows_done  = p.get("rows_done",   "—")
    total_rows = p.get("total_rows",  "—")
    elapsed    = p.get("elapsed_sec", 0)
    eta        = p.get("eta_sec",     0)
    width      = p.get("width",       "—")
    height     = p.get("height",      "—")
    max_iter   = p.get("max_iter",    "—")
    cx         = p.get("center_x",    "—")
    cy         = p.get("center_y",    "—")
    vw         = p.get("view_width",  "—")

    html = f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta http-equiv="refresh" content="5">
  <title>CUDA Mandelbrot — {pct:.1f}%</title>
  <style>
    * {{ box-sizing: border-box; margin: 0; padding: 0; }}
    body  {{ font-family: 'Courier New', monospace; background: #0c0c0c;
             color: #d4d4d4; padding: 32px; }}
    h1   {{ color: #7ecfff; font-size: 1.4rem; margin-bottom: 20px; }}
    .tag {{ display: inline-block; padding: 2px 10px; border-radius: 3px;
            background: {tag_bg}; color: #a7f3d0; font-size: 0.85rem; }}
    .bar-wrap {{ background: #1e1e1e; border-radius: 4px; height: 22px;
                 width: 560px; margin: 14px 0 6px; }}
    .bar-fill {{ height: 22px; border-radius: 4px; background: {bar_color};
                 width: {min(pct, 100):.2f}%; transition: width 1s; }}
    .pct  {{ font-size: 1.1rem; font-weight: bold; color: #e2e8f0;
             margin-bottom: 18px; }}
    table {{ border-collapse: collapse; width: 480px; margin-bottom: 20px; }}
    td,th {{ padding: 5px 14px; text-align: left; font-size: 0.88rem; }}
    th    {{ color: #7ecfff; width: 140px; }}
    tr:nth-child(even) {{ background: #141414; }}
    .img-wrap {{ margin-top: 10px; }}
    img   {{ border: 1px solid #2a2a2a; display: block;
             image-rendering: pixelated; }}
    .note {{ color: #555; font-size: 0.78rem; margin-top: 14px; }}
    a     {{ color: #7ecfff; }}
  </style>
</head>
<body>
  <h1>CUDA Mandelbrot — <span class="tag">{st}</span></h1>

  <div class="bar-wrap"><div class="bar-fill"></div></div>
  <p class="pct">{pct:.2f}% complete</p>

  <table>
    <tr><th>Rows done</th> <td>{rows_done} / {total_rows}</td></tr>
    <tr><th>Elapsed</th>   <td>{float(elapsed):.1f} s</td></tr>
    <tr><th>ETA</th>       <td>{float(eta):.1f} s</td></tr>
    <tr><th>Resolution</th><td>{width} × {height}</td></tr>
    <tr><th>Max iter</th>  <td>{max_iter}</td></tr>
    <tr><th>Center X</th>  <td>{cx}</td></tr>
    <tr><th>Center Y</th>  <td>{cy}</td></tr>
    <tr><th>View width</th><td>{vw}</td></tr>
  </table>

  <div class="img-wrap">
    <img src="{_image_data_uri()}" width="512" height="512"
         alt="Live fractal preview">
  </div>

  <p class="note">
    Auto-refreshes every 5 s &nbsp;·&nbsp;
    <a href="/api/progress">raw JSON</a> &nbsp;·&nbsp;
    <a href="/api/log">process log</a>
  </p>
</body>
</html>"""
    return Response(html, mimetype="text/html")


@app.route("/api/progress")
def api_progress():
    body = PROGRESS.read_text() if PROGRESS.exists() else '{"status": "not started"}'
    return Response(body, mimetype="application/json")


@app.route("/api/image")
def api_image():
    if PREVIEW_PPM.exists():
        try:
            data = _ppm_to_png(PREVIEW_PPM)
            return Response(data, mimetype="image/png")
        except Exception:
            pass   # fall through to placeholder
    data = _placeholder_png("Waiting for computation to start…")
    return Response(data, mimetype="image/png")


@app.route("/api/log")
def api_log():
    if not LOG_FILE.exists():
        return Response("No log file yet.\n"
                        f"Expected: {LOG_FILE}\n"
                        "Run:  ./mandelbrot > ../shared/mandelbrot.log 2>&1 &",
                        mimetype="text/plain")
    lines = LOG_FILE.read_text(errors="replace").splitlines()
    return Response("\n".join(lines[-60:]), mimetype="text/plain")


# ── Entry point ───────────────────────────────────────────────────────────────
if __name__ == "__main__":
    port = int(os.environ.get("PORT", 8080))
    print(f"Dashboard:  http://0.0.0.0:{port}/")
    print(f"Shared dir: {SHARED_DIR}")
    print(f"            (must exist and be writable by mandelbrot process)")
    app.run(host="0.0.0.0", port=port, debug=False)
