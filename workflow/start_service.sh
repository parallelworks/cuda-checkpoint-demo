#!/bin/bash
# start_service.sh — The actual job script (runs on the COMPUTE node).
#
# Appended to boilerplate that already:
#   - sourced inputs.sh  (fractal_*, bucket, bucket_path, restart are exported)
#   - set service_port via `pw agent open-port`
#   - wrote SESSION_PORT and HOSTNAME files
#   - registered cleanup() trap that calls cancel.sh then kills the process group
#   - touched job.started
#
# Two modes controlled by $restart:
#
#   start (restart=false)
#     Launch a fresh mandelbrot computation.  Write cancel.sh so that if the
#     workflow is canceled from the platform, the process is checkpointed and
#     the checkpoint is uploaded to the bucket.
#
#   restart (restart=true)
#     Download the checkpoint from the bucket, restore mandelbrot, then run
#     as in start mode (cancel.sh is still written for subsequent cancels).

set -x

DEMO_DIR="${HOME}/cuda-checkpoint-demo"
CHECKPOINT_DIR="${DEMO_DIR}/checkpoints"
SHARED_DIR="${DEMO_DIR}/shared"

mkdir -p "${SHARED_DIR}"

# ── Write cancel.sh ─────────────────────────────────────────────────────────────
# The boilerplate's cleanup() runs this when SIGTERM arrives (platform cancel).
# Written to ${PW_PARENT_JOB_DIR} which is the CWD established by run.sh.
# The heredoc uses single quotes so variable expansion happens at run time,
# not at write time; exported vars (bucket, bucket_path) are inherited by the
# child bash process that executes cancel.sh.
cat > "${PW_PARENT_JOB_DIR}/cancel.sh" << 'CANCEL_EOF'
#!/bin/bash
set -x
_DEMO_DIR="${HOME}/cuda-checkpoint-demo"
_SHARED_DIR="${_DEMO_DIR}/shared"
_CHECKPOINT_DIR="${_DEMO_DIR}/checkpoints"

echo "=== cancel.sh: workflow canceled — checkpointing mandelbrot... ==="

_RAN_CHECKPOINT=0
if [ -f "${_SHARED_DIR}/pid.txt" ]; then
    _PID=$(tr -d '[:space:]' < "${_SHARED_DIR}/pid.txt")
    if kill -0 "${_PID}" 2>/dev/null; then
        echo "Checkpointing PID ${_PID}..."
        bash "${_DEMO_DIR}/03_checkpoint/checkpoint.sh" \
            && _RAN_CHECKPOINT=1 \
            || echo "WARNING: checkpoint failed — skipping bucket upload"
    else
        echo "Process ${_PID} is no longer running — no checkpoint needed"
    fi
else
    echo "No pid.txt found — skipping checkpoint"
fi

if [ "${_RAN_CHECKPOINT}" -eq 1 ] && [ -n "${bucket:-}" ] && [ -n "${bucket_path:-}" ]; then
    _BPATH="${bucket_path%/}"
    echo "Uploading checkpoint to ${bucket}:${_BPATH}/checkpoints/ ..."
    pw buckets cp -r "${_CHECKPOINT_DIR}/" "${bucket}:${_BPATH}/checkpoints/" \
        && echo "Checkpoint uploaded successfully" \
        || echo "WARNING: bucket upload failed"
elif [ "${_RAN_CHECKPOINT}" -eq 1 ]; then
    echo "WARNING: bucket or bucket_path not set — checkpoint saved locally only"
fi
CANCEL_EOF
chmod +x "${PW_PARENT_JOB_DIR}/cancel.sh"

# ── Restart mode: restore from bucket checkpoint ─────────────────────────────
if [ "${restart:-false}" = "true" ]; then
    echo "=== Restart mode: downloading checkpoint from bucket... ==="
    _BPATH="${bucket_path%/}"
    rm -rf "${CHECKPOINT_DIR}"
    mkdir -p "${CHECKPOINT_DIR}"
    pw buckets cp -r "${bucket}:${_BPATH}/checkpoints/" "${CHECKPOINT_DIR}/"

    echo "=== Restoring mandelbrot from checkpoint... ==="
    bash "${DEMO_DIR}/03_checkpoint/restore.sh"
    echo "Mandelbrot restored and running"
else
    # ── Start mode: fresh computation ────────────────────────────────────────
    echo "=== Start mode: launching fresh mandelbrot computation... ==="
    "${DEMO_DIR}/01_fractal/mandelbrot" \
        > "${SHARED_DIR}/mandelbrot.log" 2>&1 &
    FRACTAL_PID=$!
    echo "${FRACTAL_PID}" > "${SHARED_DIR}/pid.txt"
    echo "Fractal PID: ${FRACTAL_PID}"
fi

# ── Flask web server (foreground — session lives while Flask runs) ─────────────
# Subshell for `cd` keeps the parent shell's CWD at ${PW_PARENT_JOB_DIR} so
# cleanup() can still find cancel.sh when SIGTERM fires.
echo "Starting Flask dashboard on port ${service_port}..."
(cd "${DEMO_DIR}/02_webserver" && PORT="${service_port}" python3 server.py)

# ── Natural exit: disarm the cancel hook ──────────────────────────────────────
# Flask exited normally (job finished or session closed after completion).
# Computation is done; no point uploading a stale checkpoint.
rm -f "${PW_PARENT_JOB_DIR}/cancel.sh"
