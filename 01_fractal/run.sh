#!/usr/bin/env bash
# run.sh — Configure, compile, and launch the Mandelbrot computation.
#
# USAGE
#   ./run.sh                                          use defaults (4096×4096, classic full view)
#   ./run.sh --preset fast|demo|long                  named preset
#   ./run.sh --width 8192 --height 8192 --max-iter 500000 --sleep 0
#   ./run.sh --center-x -0.74529 --center-y 0.11307 --view-width 0.6   (Seahorse Valley)
#   ./run.sh --foreground                             run in foreground (default: background)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Defaults ──────────────────────────────────────────────────────────────────
WIDTH=4096
HEIGHT=4096
MAX_ITER=100000
SLEEP_MS=5000
CENTER_X=-0.5
CENTER_Y=0.0
VIEW_W=3.5
FOREGROUND=0
PRESET=""

# ── Parse arguments ───────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --width)      WIDTH="$2";     shift 2 ;;
        --height)     HEIGHT="$2";    shift 2 ;;
        --max-iter)   MAX_ITER="$2";  shift 2 ;;
        --sleep)      SLEEP_MS="$2";  shift 2 ;;
        --center-x)   CENTER_X="$2";  shift 2 ;;
        --center-y)   CENTER_Y="$2";  shift 2 ;;
        --view-width) VIEW_W="$2";    shift 2 ;;
        --preset)     PRESET="$2";    shift 2 ;;
        --foreground) FOREGROUND=1;   shift   ;;
        --help|-h)
            sed -n '2,4p' "$0" | sed 's/^# //'
            exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ── Apply preset ──────────────────────────────────────────────────────────────
case "$PRESET" in
    fast)
        WIDTH=2048;  HEIGHT=2048;  MAX_ITER=10000;   SLEEP_MS=0
        CENTER_X=-0.5; CENTER_Y=0.0; VIEW_W=3.5
        ;;
    demo)
        WIDTH=4096;  HEIGHT=4096;  MAX_ITER=100000;  SLEEP_MS=5000
        CENTER_X=-0.5; CENTER_Y=0.0; VIEW_W=3.5
        ;;
    long)
        WIDTH=8192;  HEIGHT=8192;  MAX_ITER=500000;  SLEEP_MS=0
        CENTER_X=-0.5; CENTER_Y=0.0; VIEW_W=3.5
        ;;
    "")
        : ;;  # no preset
    *)
        echo "Unknown preset '$PRESET'. Valid: fast | demo | long"
        exit 1 ;;
esac

# ── Estimate runtime ──────────────────────────────────────────────────────────
NUM_CHUNKS=$(( (HEIGHT + 7) / 8 ))
SLEEP_TOTAL=$(( NUM_CHUNKS * SLEEP_MS / 1000 ))
echo ""
echo "  Parameters:"
echo "    Width / Height : ${WIDTH} × ${HEIGHT}"
echo "    Max iterations : ${MAX_ITER}"
echo "    Sleep between  : ${SLEEP_MS} ms/chunk"
echo "    Chunks         : ${NUM_CHUNKS}"
echo "    Sleep total    : ~${SLEEP_TOTAL} s"
echo "    Center         : (${CENTER_X}, ${CENTER_Y})"
echo "    View width     : ${VIEW_W}"
echo ""

# ── Kill any running instance ─────────────────────────────────────────────────
if pgrep -f "01_fractal/mandelbrot" > /dev/null 2>&1; then
    echo "  Stopping existing mandelbrot process…"
    pkill -f "01_fractal/mandelbrot" || true
    sleep 1
fi

# ── Compile ───────────────────────────────────────────────────────────────────
# Always force a full recompile because compile-time defines (WIDTH, MAX_ITER,
# etc.) may have changed since the last build — make cannot detect that.
echo "  Compiling…"
make -C "$SCRIPT_DIR" -B \
    WIDTH="$WIDTH" HEIGHT="$HEIGHT" MAX_ITER="$MAX_ITER" SLEEP_MS="$SLEEP_MS" \
    CENTER_X="$CENTER_X" CENTER_Y="$CENTER_Y" VIEW_W="$VIEW_W" \
    --no-print-directory 2>&1 | sed 's/^/    /'
echo "  Compile OK."
echo ""

# ── Launch ────────────────────────────────────────────────────────────────────
mkdir -p "$SCRIPT_DIR/../shared"

if [[ $FOREGROUND -eq 1 ]]; then
    echo "  Running in foreground (Ctrl-C to stop)…"
    exec "$SCRIPT_DIR/mandelbrot"
else
    "$SCRIPT_DIR/mandelbrot" > "$SCRIPT_DIR/../shared/mandelbrot.log" 2>&1 &
    BG_PID=$!
    sleep 1
    if ! kill -0 "$BG_PID" 2>/dev/null; then
        echo "  ERROR: process exited immediately. Check log:"
        tail -20 "$SCRIPT_DIR/../shared/mandelbrot.log"
        exit 1
    fi
    echo "  Started in background.  PID: $BG_PID"
    echo "  Log:      $SCRIPT_DIR/../shared/mandelbrot.log"
    echo "  Progress: $SCRIPT_DIR/../shared/progress.json"
    echo ""
    echo "  Monitor:  watch -n1 'cat ../shared/progress.json | python3 -m json.tool'"
    echo "  Stop:     kill $BG_PID"
fi
