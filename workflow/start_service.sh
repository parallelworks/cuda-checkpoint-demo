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

# Use the fixed work directory so CRIU restore always finds the binary at the
# same absolute path across multiple cancel → restart cycles.
# controller.sh has already populated this directory and compiled the binary.
DEMO_DIR="${HOME}/cuda-checkpoint-work"
CHECKPOINT_DIR="${DEMO_DIR}/checkpoints"
SHARED_DIR="${DEMO_DIR}/shared"

# Export so cancel.sh (launched by the boilerplate's cleanup() trap) can find
# the work directory even though it runs in a subprocess.
export DEMO_WORK_DIR="${DEMO_DIR}"

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

_DEMO_DIR="${DEMO_WORK_DIR}"
_SHARED_DIR="${_DEMO_DIR}/shared"
_CHECKPOINT_DIR="${_DEMO_DIR}/checkpoints"

# Normalise path: strip leading and trailing slashes
_BPATH="${bucket_path:-}"
_BPATH="${_BPATH#/}"
_BPATH="${_BPATH%/}"

# pw buckets cp -r always creates a subdirectory named after the source's
# last path component inside the destination.  Upload one level above so
# the tool creates   <bucket>/<path>/checkpoints/   in the bucket.
_DEST="${bucket_uri}/${_BPATH}"

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
_PID=""

# Prefer the job-specific PID file written by start_service.sh.
# This avoids a race where a subsequent job's mandelbrot has already
# overwritten the shared pid.txt before this cancel.sh runs.
_MPID_FILE="${PW_PARENT_JOB_DIR}/mandelbrot.pid"
if [ -f "${_MPID_FILE}" ]; then
    _PID=$(tr -d '[:space:]' < "${_MPID_FILE}")
    echo "  PID source: job-local mandelbrot.pid → ${_PID}"
elif [ -f "${_SHARED_DIR}/pid.txt" ]; then
    _PID=$(tr -d '[:space:]' < "${_SHARED_DIR}/pid.txt")
    echo "  PID source: shared pid.txt (fallback) → ${_PID}"
else
    echo "  No PID file found — skipping checkpoint"
fi

if [ -n "${_PID}" ]; then
    if kill -0 "${_PID}" 2>/dev/null; then
        echo "  Process ${_PID} is running — checkpointing..."
        bash "${_DEMO_DIR}/03_checkpoint/checkpoint.sh" \
            && _RAN_CHECKPOINT=1 \
            || echo "  WARNING: checkpoint.sh failed — skipping upload"
    else
        echo "  Process ${_PID} already finished — no checkpoint needed"
    fi
fi

echo ""
echo "--- Bucket upload ---"
if [ "${_RAN_CHECKPOINT}" -eq 1 ]; then
    if [ -n "${bucket_uri:-}" ] && [ -n "${_BPATH}" ]; then
        echo "  Uploading: ${_CHECKPOINT_DIR}"
        echo "        → ${_DEST}/checkpoints/"
        pw buckets cp -r "${_CHECKPOINT_DIR}" "${_DEST}/" \
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
# Mandelbrot ignores SIGTERM (SIG_IGN set by its setsid bash wrapper) so
# kill -- -$$ and plain SIGTERM do nothing to it.  We must kill it
# explicitly with SIGKILL.  If checkpoint.sh succeeded, criu already
# terminated the process; this is a no-op in that case.
if [ -n "${_PID}" ] && kill -0 "${_PID}" 2>/dev/null; then
    echo "  Sending SIGKILL to mandelbrot (PID ${_PID})..."
    kill -9 "${_PID}" 2>/dev/null || true
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

    echo "Downloading from: ${_SRC}"
    # pw buckets cp -r SOURCE (no trailing slash) DEST/ creates a subdirectory
    # named after the source's last path component inside DEST.
    # With a trailing slash on the source the tool copies the CONTENTS directly
    # into DEST — so the .img files land in WORK_DIR root, not checkpoints/.
    # Always omit the trailing slash from the source URL.
    rm -rf "${CHECKPOINT_DIR}"
    mkdir -p "${DEMO_DIR}"
    pw buckets cp -r "${_SRC}" "${DEMO_DIR}/" \
        || { echo "ERROR: checkpoint download failed from ${_SRC} — aborting job"; exit 1; }

    echo "=== Restoring mandelbrot from checkpoint... ==="
    bash "${DEMO_DIR}/03_checkpoint/restore.sh" \
        || { echo "ERROR: restore.sh failed — aborting job"; exit 1; }
    echo "Mandelbrot restored and running"

    # Capture the PID immediately after restore, before any other job could
    # overwrite the shared pid.txt.  restore.sh already validated the PID,
    # so a brief retry loop is sufficient.
    MANDELBROT_PID=""
    for _i in $(seq 1 5); do
        MANDELBROT_PID=$(cat "${SHARED_DIR}/pid.txt" 2>/dev/null | tr -d '[:space:]')
        if [ -n "${MANDELBROT_PID}" ] && kill -0 "${MANDELBROT_PID}" 2>/dev/null; then
            break
        fi
        sleep 1
    done
    if [ -z "${MANDELBROT_PID}" ] || ! kill -0 "${MANDELBROT_PID}" 2>/dev/null; then
        echo "ERROR: could not confirm restored mandelbrot PID from pid.txt"
        exit 1
    fi
    echo "Restored mandelbrot PID: ${MANDELBROT_PID}"

else
    # ── Start mode: fresh computation ────────────────────────────────────────
    echo "=== Start mode: launching fresh mandelbrot computation... ==="
    # Kill any leftover mandelbrot from a previous job or test session that may
    # still be writing to the shared work directory.
    pkill -KILL -f "${DEMO_DIR}/01_fractal/mandelbrot" 2>/dev/null || true
    sleep 1
    # Two layers of signal protection so the platform's cgroup-wide SIGTERM
    # cannot kill mandelbrot before cancel.sh gets to checkpoint it:
    #
    #   1. setsid  — new POSIX session, own process group; the platform's
    #               "kill -- -$$" targeting this job's PGID doesn't reach it.
    #
    #   2. trap '' TERM HUP inside the bash wrapper — sets SIGTERM/SIGHUP to
    #               SIG_IGN.  POSIX guarantees SIG_IGN is preserved across
    #               exec(), so the mandelbrot inherits it and cannot be killed
    #               by SIGTERM even when the platform broadcasts to the whole
    #               session cgroup (which setsid alone doesn't protect against).
    #
    # After a successful checkpoint criu terminates the process itself.
    # If checkpoint failed, cancel.sh kills with SIGKILL (cannot be ignored).
    #
    # When bash is a process group leader, setsid(1) forks before exec, so
    # $! is the wrapper PID — not the mandelbrot.  The mandelbrot writes its
    # own PID to pid.txt immediately at startup (before CUDA init), so we
    # wait for that file instead of trusting $!.
    rm -f "${SHARED_DIR}/pid.txt"
    setsid bash -c "trap '' TERM HUP; exec '${DEMO_DIR}/01_fractal/mandelbrot'" \
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
    MANDELBROT_PID="${FRACTAL_PID}"
fi

# ── Store PID in a job-specific file ─────────────────────────────────────────
# cancel.sh reads this file first so it always operates on THIS job's
# mandelbrot, even if a concurrent job's process has since overwritten the
# shared ~/cuda-checkpoint-work/shared/pid.txt.
echo "${MANDELBROT_PID}" > "${PW_PARENT_JOB_DIR}/mandelbrot.pid"
echo "Mandelbrot PID ${MANDELBROT_PID} saved to ${PW_PARENT_JOB_DIR}/mandelbrot.pid"

# ── Flask web server (background) ─────────────────────────────────────────────
# Run Flask in the background so the liveness watchdog can share this script.
# Job lifetime is still tied to Flask — when Flask exits the script ends.
# Subshell for `cd` keeps the parent shell's CWD at ${PW_PARENT_JOB_DIR} so
# cleanup() can still find cancel.sh when SIGTERM fires.
echo "Starting Flask dashboard on port ${service_port}..."
(cd "${DEMO_DIR}/02_webserver" && PORT="${service_port}" python3 server.py) &
FLASK_PID=$!
echo "Flask PID: ${FLASK_PID}"

# ── Liveness watchdog ─────────────────────────────────────────────────────────
# Background monitor: poll every 15 s for mandelbrot liveness.
# If it disappears before completing, mark progress.json status="dead" and
# send SIGTERM to Flask so the job ends cleanly rather than hanging forever
# serving stale data.
(
    while kill -0 "${MANDELBROT_PID}" 2>/dev/null; do
        sleep 15
    done
    # Mandelbrot is gone — was it a clean completion?
    _ST=$(python3 -c "
import json, pathlib
p = pathlib.Path('${SHARED_DIR}/progress.json')
try:
    print(json.loads(p.read_text()).get('status', 'unknown'))
except Exception:
    print('unknown')
" 2>/dev/null || echo "unknown")
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) WATCHDOG: mandelbrot PID ${MANDELBROT_PID} exited (status=${_ST})"
    if [ "${_ST}" != "complete" ]; then
        echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) WATCHDOG: unexpected exit — marking status=dead"
        python3 -c "
import json, pathlib
p = pathlib.Path('${SHARED_DIR}/progress.json')
try:
    d = json.loads(p.read_text())
except Exception:
    d = {}
d['status'] = 'dead'
p.write_text(json.dumps(d))
" 2>/dev/null || true
        echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) WATCHDOG: terminating Flask (PID ${FLASK_PID})"
        kill "${FLASK_PID}" 2>/dev/null || true
    else
        echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) WATCHDOG: computation complete — Flask stays up"
    fi
) &
WATCHDOG_PID=$!
echo "Watchdog PID: ${WATCHDOG_PID}"

# Wait for Flask to exit (either normally, killed by the watchdog, or SIGTERM
# from the platform — in the last case the cleanup() trap interrupts the wait).
wait "${FLASK_PID}" || true

# ── Natural exit: disarm the cancel hook and reap setsid'd mandelbrot ─────────
# Flask exited normally (computation done, browser closed, or watchdog trigger).
# Use the job-local MANDELBROT_PID captured at startup — NOT a fresh read of
# shared pid.txt, which could have been overwritten by a subsequent job that
# started on the same host before this cleanup ran.
kill "${WATCHDOG_PID}" 2>/dev/null || true
rm -f "${PW_PARENT_JOB_DIR}/cancel.sh"
# Mandelbrot runs under setsid with SIGTERM ignored — won't be caught by
# kill -- -$$ and won't respond to SIGTERM.  Use SIGKILL to terminate it
# if it is still alive (e.g. Flask closed before computation finished, or
# watchdog detected unexpected death).  No-op if already gone.
[ -n "${MANDELBROT_PID}" ] && kill -9 "${MANDELBROT_PID}" 2>/dev/null || true
