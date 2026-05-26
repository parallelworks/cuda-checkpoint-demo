# Component 2 — Web Dashboard

A minimal Flask server that reads from `shared/` and displays live progress.

---

## Files

| File | Description |
|------|-------------|
| `server.py` | Flask application |
| `requirements.txt` | Python dependencies |

---

## Data read at runtime

The server only **reads** from `<project_root>/shared/`.  
It never writes to disk.

| File read | Used for |
|-----------|---------|
| `shared/progress.json` | Stats table and progress bar |
| `shared/preview.ppm` | Live fractal preview (converted to PNG on-the-fly) |
| `shared/mandelbrot.log` | `/api/log` endpoint (last 60 lines) |

---

## Install dependencies

```bash
pip3 install -r requirements.txt
```

---

## Run

```bash
cd 02_webserver
python3 server.py
```

Default port: **8080** (override with `PORT=9090 python3 server.py`).

Open: [http://localhost:8080/](http://localhost:8080/)

---

## Endpoints

| URL | Returns |
|-----|---------|
| `GET /` | HTML dashboard (auto-refreshes every 5 s) |
| `GET /api/progress` | Raw `progress.json` as `application/json` |
| `GET /api/image` | Current preview as `image/png` |
| `GET /api/log` | Last 60 lines of `mandelbrot.log` |

---

## Test independently

```bash
# With no computation running the dashboard shows "not started"
# and a dark placeholder image.
python3 server.py &

# Fake some data to verify rendering:
mkdir -p ../shared
echo '{"status":"running","rows_done":1024,"total_rows":4096,"percent":25,"elapsed_sec":30,"eta_sec":90,"width":4096,"height":4096,"max_iter":100000,"center_x":-0.74529,"center_y":0.11307,"view_width":0.6}' \
  > ../shared/progress.json

curl -s http://localhost:8080/api/progress | python3 -m json.tool

kill %1  # stop server
```
