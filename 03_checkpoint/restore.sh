#!/usr/bin/env bash
# restore.sh — Restore the Mandelbrot computation from a CRIU checkpoint.
#
# Steps:
#   1. criu restore       recreates the process from binary images
#   2. Detect new PID     (process writes it to shared/pid.txt once unblocked)
#   3. cuda-checkpoint    resumes GPU state (unblocks pending CUDA calls)
#
# The restored process continues computing from exactly where it was frozen.
#
# ┌─ DATA REQUIRED ─────────────────────────────────────────────────────────────┐
# │                                                                             │
# │   <project>/checkpoints/   CRIU binary images from checkpoint.sh           │
# │                                                                             │
# │   If migrating from another machine, copy checkpoints/ here first:         │
# │     rsync -av user@source-host:/path/to/checkpoints/ checkpoints/          │
# │                                                                             │
# │   The computation binary (01_fractal/mandelbrot) must exist at the same    │
# │   path as on the source machine.  Recompile if needed:                     │
# │     cd 01_fractal && make                                                  │
# └─────────────────────────────────────────────────────────────────────────────┘
#
# NOTE: criu restore requires elevated privileges (sudo).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SHARED_DIR="$PROJECT_DIR/shared"
CHECKPOINTS_DIR="$PROJECT_DIR/checkpoints"
CUDA_CKPT="$PROJECT_DIR/bin/cuda-checkpoint"

# ── Banner ────────────────────────────────────────────────────────────────────
echo "╔══════════════════════════════════════════════════════╗"
echo "║       CUDA Mandelbrot — Restore                      ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
echo "  Reading checkpoint from:"
echo "    $CHECKPOINTS_DIR/"
echo ""

# ── Pre-flight checks ─────────────────────────────────────────────────────────
if [[ ! -d "$CHECKPOINTS_DIR" ]]; then
    echo "ERROR: $CHECKPOINTS_DIR not found."
    echo "Run checkpoint.sh first (or copy checkpoint images here)."
    exit 1
fi

if [[ ! -f "$CHECKPOINTS_DIR/inventory.img" ]]; then
    echo "ERROR: No CRIU images found in $CHECKPOINTS_DIR"
    echo "The directory exists but appears empty or incomplete."
    exit 1
fi

if [[ ! -x "$CUDA_CKPT" ]]; then
    echo "ERROR: cuda-checkpoint not found at $CUDA_CKPT"
    exit 1
fi

# Show metadata from the checkpoint
if [[ -f "$CHECKPOINTS_DIR/metadata.json" ]]; then
    echo "  Checkpoint metadata:"
    python3 -c "
import json
d = json.load(open('$CHECKPOINTS_DIR/metadata.json'))
p = d.get('progress', {})
print(f\"    Created:  {d.get('timestamp','?')}\")
print(f\"    Host:     {d.get('hostname','?')}\")
print(f\"    Progress: {p.get('percent',0):.1f}% ({p.get('rows_done','?')}/{p.get('total_rows','?')} rows)\")
" 2>/dev/null || true
    echo ""
fi

# ── Step 1: Restore process with CRIU ────────────────────────────────────────
echo "[1/3] Restoring process with CRIU (requires sudo) …"
echo "      The restored process will block at its next CUDA call"
echo "      until we run cuda-checkpoint --toggle in step 3."
echo ""

# --restore-detached: run the restored process in the background
# (otherwise criu restore itself becomes the parent and blocks)
sudo criu restore \
    --images-dir  "$CHECKPOINTS_DIR" \
    --restore-detached \
    --log-file    criu-restore.log \
    -v4

echo "      CRIU restore launched."

# ── Step 2: Locate the restored process ──────────────────────────────────────
echo ""
echo "[2/3] Locating restored process …"
echo "      (waiting for it to write shared/pid.txt)"

NEW_PID=""
for attempt in $(seq 1 20); do
    sleep 1
    # The process writes its PID at every write_progress() call.
    # After CRIU restores it, the process runs until the next CUDA call
    # (where it blocks), then — after cuda-checkpoint --toggle — it
    # resumes and calls write_progress(), which updates pid.txt.
    # So we also try pgrep as a fallback.
    CANDIDATE=$(cat "$SHARED_DIR/pid.txt" 2>/dev/null | tr -d '[:space:]' || true)
    if [[ -n "$CANDIDATE" ]] && kill -0 "$CANDIDATE" 2>/dev/null; then
        NEW_PID="$CANDIDATE"
        echo "      Found PID $NEW_PID via shared/pid.txt (attempt $attempt)"
        break
    fi
    # Fallback: pgrep for the binary name
    CANDIDATE=$(pgrep -n -f "01_fractal/mandelbrot" 2>/dev/null || true)
    if [[ -n "$CANDIDATE" ]] && kill -0 "$CANDIDATE" 2>/dev/null; then
        NEW_PID="$CANDIDATE"
        echo "      Found PID $NEW_PID via pgrep (attempt $attempt)"
        break
    fi
    printf "\r      Waiting… attempt %d/20" "$attempt"
done

if [[ -z "$NEW_PID" ]]; then
    echo ""
    echo "ERROR: Could not locate restored process after 20 seconds."
    echo "Check the CRIU log: $CHECKPOINTS_DIR/criu-restore.log"
    exit 1
fi

# ── Step 3: Resume CUDA state ─────────────────────────────────────────────────
echo ""
echo "[3/3] Resuming CUDA state …"
# sudo is required here: criu restore runs as root, which leaves the CUDA
# checkpoint channel in a state that only root can access via cuda-checkpoint.
# The same binary works without sudo for a freshly launched process, but after
# a CRIU restore the toggle must be run with elevated privileges.
echo "      sudo cuda-checkpoint --toggle --pid $NEW_PID"
sudo "$CUDA_CKPT" --toggle --pid "$NEW_PID"
echo "      GPU memory restored; CUDA execution resumed."

STATE=$(sudo "$CUDA_CKPT" --get-state --pid "$NEW_PID" 2>&1 || true)
echo "      State after toggle: $STATE"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║  Restore complete                                    ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
echo "  Restored PID: $NEW_PID"
echo "  Computation is running.  Monitor via:"
echo "    watch -n1 cat $SHARED_DIR/progress.json"
echo "    or open the web dashboard (02_webserver/server.py)"
echo ""
echo "  To checkpoint again: ./checkpoint.sh"
