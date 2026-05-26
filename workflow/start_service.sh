#!/bin/bash
# start_service.sh — The actual job script (runs on the COMPUTE node).
#
# Appended to boilerplate that already:
#   - sourced inputs.sh  (fractal_*, bucket_uri, bucket_path, restart are exported)
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
# Written to ${PW_PARENT_JOB_DIR} (= CWD established by run.sh).
# Single-quoted heredoc: variables expand at run time from the inherited env.
# bucket_uri is the pw:// URI extracted directly via ${{ inputs.bucket.uri }}
# in general.yaml — no JSON parsing needed here.
cat > "${PW_PARENT_JOB_DIR}/cancel.sh" << 'CANCEL_EOF'
#!/bin/bash
set -x

_LOG="${PW_PARENT_JOB_DIR}/cancel.log"
exec > >(tee -a "${_LOG}") 2>&1

_DEMO_DIR="${HOME}/cuda-checkpoint-demo"
_SHARED_DIR="${_DEMO_DIR}/shared"
_CHECKPOINT_DIR="${_DEMO_DIR}/checkpoints"

# Normalise path: strip leading and trailing slashes
_BPATH="${bucket_path:-}"
_BPATH="${_BPATH#/}"
_BPATH="${_BPATH%/}"

_DEST="${bucket_uri}/${_BPATH}/checkpoints"

echo "========================================================"
echo "cancel.sh  started : $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "host               : $(hostname)"
echo "job dir            : ${PW_PARENT_JOB_DIR:-unknown}"
echo "bucket URI         : ${bucket_uri:-<empty>}"
echo "bucket path        : ${_BPATH:-<empty>}"
echo "upload destination : ${_DEST}"
echo "========================================================"

echo ""
echo "--- Checkpoint ---"
_RAN_CHECKPOINT=0
if [ -f "${_SHARED_DIR}/pid.txt" ]; then
    _PID=$(tr -d '[:space:]' < "${_SHARED_DIR}/pid.txt")
    echo "  pid.txt PID : ${_PID}"
    if kill -0 "${_PID}" 2>/dev/null; then
        echo "  Process is running — checkpointing..."
        bash "${_DEMO_DIR}/03_checkpoint/checkpoint.sh" \
            && _RAN_CHECKPOINT=1 \
            || echo "  WARNING: checkpoint.sh failed — skipping upload"
    else
        echo "  Process ${_PID} already finished — no checkpoint needed"
    fi
else
    echo "  No pid.txt found — skipping checkpoint"
fi

echo ""
echo "--- Bucket upload ---"
if [ "${_RAN_CHECKPOINT}" -eq 1 ]; then
    if [ -n "${bucket_uri:-}" ] && [ -n "${_BPATH}" ]; then
        echo "  Uploading: ${_CHECKPOINT_DIR}/"
        echo "        → ${_DEST}/"
        pw buckets cp -r "${_CHECKPOINT_DIR}/" "${_DEST}/" \
            && echo "  Upload succeeded" \
            || echo "  WARNING: upload failed (check pw CLI output above)"
    else
        echo "  WARNING: bucket_uri or bucket_path is empty — checkpoint kept locally"
        echo "  bucket_uri : ${bucket_uri:-<empty>}"
        echo "  bucket_path: ${bucket_path:-<empty>}"
    fi
else
    echo "  No checkpoint to upload"
fi

echo ""
echo "--- Kill mandelbrot ---"
# Mandelbrot runs under setsid (its own process group) so kill -- -$$ in
# the boilerplate cleanup does not reach it.  We must kill it explicitly.
# If checkpoint.sh succeeded, criu already terminated the process; this is
# a no-op in that case.
if [ -n "${_PID}" ] && kill -0 "${_PID}" 2>/dev/null; then
    echo "  Sending SIGTERM to mandelbrot (PID ${_PID})..."
    kill "${_PID}" 2>/dev/null || true
    sleep 1
    kill -0 "${_PID}" 2>/dev/null && kill -9 "${_PID}" 2>/dev/null || true
fi

echo ""
echo "========================================================"
echo "cancel.sh  finished: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "========================================================"
CANCEL_EOF
chmod +x "${PW_PARENT_JOB_DIR}/cancel.sh"

# ── Restart mode: restore from bucket checkpoint ─────────────────────────────
if [ "${restart:-false}" = "true" ]; then
    echo "=== Restart mode: downloading checkpoint from bucket... ==="
    _BPATH="${bucket_path:-}"
    _BPATH="${_BPATH#/}"
    _BPATH="${_BPATH%/}"
    _SRC="${bucket_uri}/${_BPATH}/checkpoints"

    echo "Downloading from: ${_SRC}/"
    rm -rf "${CHECKPOINT_DIR}"
    mkdir -p "${CHECKPOINT_DIR}"
    pw buckets cp -r "${_SRC}/" "${CHECKPOINT_DIR}/"

    echo "=== Restoring mandelbrot from checkpoint... ==="
    bash "${DEMO_DIR}/03_checkpoint/restore.sh"
    echo "Mandelbrot restored and running"
else
    # ── Start mode: fresh computation ────────────────────────────────────────
    echo "=== Start mode: launching fresh mandelbrot computation... ==="
    # setsid puts mandelbrot in its own session/process group so that the
    # SIGTERM the platform sends to this job's process group does NOT reach
    # it.  cancel.sh can then checkpoint it safely and kills it explicitly.
    #
    # When bash is a process group leader (common in platform-launched jobs),
    # setsid(1) forks before exec, so $! is the wrapper PID — not the mandelbrot.
    # The mandelbrot writes its own PID to pid.txt immediately at startup (before
    # CUDA init), so we wait for that file instead of trusting $!.
    rm -f "${SHARED_DIR}/pid.txt"
    setsid "${DEMO_DIR}/01_fractal/mandelbrot" \
        > "${SHARED_DIR}/mandelbrot.log" 2>&1 &
    SETSID_PID=$!
    echo "setsid wrapper PID: ${SETSID_PID} (waiting for mandelbrot to write pid.txt...)"

    # Wait up to 30s for the mandelbrot to write its actual PID
    _W=0
    while true; do
        FRACTAL_PID=$(cat "${SHARED_DIR}/pid.txt" 2>/dev/null | tr -d '[:space:]')
        if [ -n "${FRACTAL_PID}" ] && kill -0 "${FRACTAL_PID}" 2>/dev/null; then
            break
        fi
        _W=$((_W + 1))
        if [ ${_W} -ge 30 ]; then
            echo "ERROR: mandelbrot did not write pid.txt within 30s"
            exit 1
        fi
        sleep 1
    done
    echo "Fractal PID: ${FRACTAL_PID}"
fi

# ── Flask web server (foreground — session lives while Flask runs) ─────────────
# Subshell for `cd` keeps the parent shell's CWD at ${PW_PARENT_JOB_DIR} so
# cleanup() can still find cancel.sh when SIGTERM fires.
echo "Starting Flask dashboard on port ${service_port}..."
(cd "${DEMO_DIR}/02_webserver" && PORT="${service_port}" python3 server.py)

# ── Natural exit: disarm the cancel hook and reap setsid'd mandelbrot ─────────
# Flask exited normally (job finished or session closed after completion).
rm -f "${PW_PARENT_JOB_DIR}/cancel.sh"
# Mandelbrot runs under setsid and won't be caught by kill -- -$$.  Kill it
# if it is still alive (e.g. Flask was closed before computation finished).
_MPID=$(cat "${SHARED_DIR}/pid.txt" 2>/dev/null | tr -d '[:space:]')
[ -n "${_MPID}" ] && kill "${_MPID}" 2>/dev/null || true
