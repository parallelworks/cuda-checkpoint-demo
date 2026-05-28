#!/usr/bin/env bash
# checkpoint.sh — Freeze and snapshot the running Mandelbrot computation.
#
# Combines two tools:
#   1. cuda-checkpoint --toggle   suspends GPU state, copies device memory to host
#   2. criu dump                  snapshots the full process (CPU + host memory)
#
# After this script completes the process is GONE.  To continue it, run restore.sh.
#
# ┌─ CHECKPOINT DATA LOCATION ──────────────────────────────────────────────────┐
# │                                                                             │
# │   <project>/checkpoints/     ← CRIU binary images (what you migrate)       │
# │                                                                             │
# │   To resume on ANOTHER MACHINE, copy this entire directory:                │
# │     rsync -av checkpoints/ user@new-host:/path/to/cuda-checkpoint-demo/checkpoints/ │
# │                                                                             │
# │   The shared/ directory (progress.json, preview.ppm) is NOT needed for     │
# │   restore — it's only for monitoring.  The checkpoint is self-contained.   │
# └─────────────────────────────────────────────────────────────────────────────┘
#
# USAGE
#   ./checkpoint.sh               checkpoint and terminate the process
#   ./checkpoint.sh --live        checkpoint but leave process running (live migration)
#
# PREREQUISITES (one-time admin setup):
#   CRIU requires the cap_checkpoint_restore capability to run without root:
#     sudo setcap cap_checkpoint_restore+eip $(which criu)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SHARED_DIR="$PROJECT_DIR/shared"
CHECKPOINTS_DIR="$PROJECT_DIR/checkpoints"
CUDA_CKPT="$PROJECT_DIR/bin/cuda-checkpoint"
PID_FILE="$SHARED_DIR/pid.txt"

LEAVE_RUNNING=0
[[ "${1:-}" == "--live" ]] && LEAVE_RUNNING=1

# ── Banner ────────────────────────────────────────────────────────────────────
echo "╔══════════════════════════════════════════════════════╗"
echo "║       CUDA Mandelbrot — Checkpoint                   ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
echo "  Checkpoint images will be stored in:"
echo "    $CHECKPOINTS_DIR/"
echo ""

# ── Pre-flight checks ─────────────────────────────────────────────────────────
_CRIU_BIN=$(command -v criu 2>/dev/null)
if [[ -z "$_CRIU_BIN" ]]; then
    echo "ERROR: criu not found in PATH. Install CRIU first."
    exit 1
fi
_CRIU_CAPS=$(getcap "$_CRIU_BIN" 2>/dev/null || echo "")
if ! echo "$_CRIU_CAPS" | grep -qE "cap_checkpoint_restore|cap_sys_admin"; then
    echo "ERROR: CRIU is not configured for non-root operation."
    echo ""
    echo "  Ask your system administrator to run once:"
    echo "    sudo setcap cap_checkpoint_restore+eip $_CRIU_BIN"
    echo ""
    echo "  Then verify with: getcap $_CRIU_BIN"
    exit 1
fi

if [[ ! -f "$PID_FILE" ]]; then
    echo "ERROR: $PID_FILE not found."
    echo "Is the Mandelbrot computation running?  Start it with:"
    echo "  cd 01_fractal && ./mandelbrot > ../shared/mandelbrot.log 2>&1 &"
    exit 1
fi

PID=$(tr -d '[:space:]' < "$PID_FILE")
if ! kill -0 "$PID" 2>/dev/null; then
    echo "ERROR: Process $PID is not running (stale pid.txt?)."
    exit 1
fi
echo "  Target PID: $PID"

if [[ ! -x "$CUDA_CKPT" ]]; then
    echo "ERROR: cuda-checkpoint not found at $CUDA_CKPT"
    exit 1
fi

# ── Step 1: Suspend CUDA state ────────────────────────────────────────────────
echo ""
echo "[1/3] Suspending CUDA state …"

# Strategy: attempt --toggle directly rather than polling --get-state first.
#
# Background: in some execution environments (e.g. platform-launched jobs)
# --get-state consistently returns "initialization error" / "OS call failed"
# even on a healthy running process, because the first failed query corrupts
# the checkpoint channel.  Calling --toggle directly bypasses that failure
# path and succeeds in those environments.
#
# Fallback logic:
#   1. If CUDA state is already 'checkpointed' (prior attempt), resume first.
#   2. Try --toggle up to WAIT_MAX times with 1 s sleep between attempts.
#   3. On each attempt also check the process is still alive; exit early if dead.

WAIT_MAX=30
WAITED=0
while true; do
    # Liveness check — bail out early rather than poll for 30 s if the process
    # was killed by the platform's cgroup cleanup between cancel.sh starting and
    # this point.
    if ! kill -0 "$PID" 2>/dev/null; then
        echo "ERROR: Process $PID exited before CUDA could be suspended."
        exit 1
    fi

    # Check current state (informational; do NOT block on errors from this call).
    CUDA_STATE=$("$CUDA_CKPT" --get-state --pid "$PID" 2>&1 || true)
    echo "      cuda-checkpoint --get-state --pid $PID → ${CUDA_STATE}"

    # If already checkpointed from a prior failed attempt, resume first.
    if [[ "$CUDA_STATE" == "checkpointed" ]]; then
        echo "      State is 'checkpointed' — resuming before re-toggling..."
        "$CUDA_CKPT" --toggle --pid "$PID" 2>&1 || true
        sleep 1
        continue
    fi

    # Attempt the toggle regardless of what --get-state reported.
    # In healthy environments this is a no-op (we already know it's 'running').
    # In environments where --get-state fails, this is the only path that works.
    echo "      cuda-checkpoint --toggle --pid $PID"
    if "$CUDA_CKPT" --toggle --pid "$PID" 2>&1; then
        echo "      GPU memory copied to host; GPU resources released."
        break
    fi

    WAITED=$((WAITED + 1))
    if [[ $WAITED -ge $WAIT_MAX ]]; then
        echo "ERROR: Could not suspend CUDA after ${WAIT_MAX} attempts (last state: ${CUDA_STATE})"
        exit 1
    fi
    echo "      Toggle failed — retrying (${WAITED}/${WAIT_MAX}) ..."
    sleep 1
done

STATE=$("$CUDA_CKPT" --get-state --pid "$PID" 2>&1 || true)
echo "      State after toggle: $STATE"

# ── Step 2: Dump process with CRIU ───────────────────────────────────────────
echo ""
echo "[2/3] Dumping process with CRIU …"

# Clear old checkpoint images so restore always uses a fresh dump
rm -rf "$CHECKPOINTS_DIR"
mkdir -p "$CHECKPOINTS_DIR"

CRIU_FLAGS=(
    --images-dir   "$CHECKPOINTS_DIR"
    --tree         "$PID"
    --log-file     criu.log
    -v4
    --unprivileged
)
if [[ $LEAVE_RUNNING -eq 1 ]]; then
    CRIU_FLAGS+=(--leave-running)
    echo "      Mode: --live  (process keeps running after checkpoint)"
fi

criu dump "${CRIU_FLAGS[@]}"
echo "      CRIU dump complete."

# ── Step 3: Save human-readable metadata ─────────────────────────────────────
echo ""
echo "[3/3] Writing checkpoint metadata …"
PROGRESS_JSON=$(cat "$SHARED_DIR/progress.json" 2>/dev/null || echo '{}')
cat > "$CHECKPOINTS_DIR/metadata.json" <<EOF
{
  "timestamp":          "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "hostname":           "$(hostname)",
  "pid_at_checkpoint":  $PID,
  "leave_running":      $LEAVE_RUNNING,
  "progress":           $PROGRESS_JSON
}
EOF

# ── Summary ───────────────────────────────────────────────────────────────────
PERCENT=$(python3 -c "import json,sys; d=json.load(open('$SHARED_DIR/progress.json')); print(f\"{d.get('percent',0):.1f}\")" 2>/dev/null || echo "?")

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║  Checkpoint complete                                 ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
echo "  Progress at checkpoint: ${PERCENT}%"
echo ""
echo "  Checkpoint files (CRIU images):"
echo "    $CHECKPOINTS_DIR/"
ls -lh "$CHECKPOINTS_DIR/" | awk '{print "    "$0}'
echo ""
echo "  ── To migrate to another machine ──────────────────────"
echo "  rsync -av \\"
echo "    $CHECKPOINTS_DIR/ \\"
echo "    user@new-host:$(realpath "$CHECKPOINTS_DIR")/"
echo ""
echo "  ── To restore on THIS machine ──────────────────────────"
echo "  ./restore.sh"
