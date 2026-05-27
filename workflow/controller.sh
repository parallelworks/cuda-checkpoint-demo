#!/bin/bash
# controller.sh — Runs on the LOGIN node before the job starts.
#
# This script is PREPENDED with inputs.sh by the session runner, so all
# fractal_* variables (from the workflow form) are already exported.
#
# Responsibilities:
#   1. Set up the STABLE WORK DIRECTORY (~/cuda-checkpoint-work)
#   2. Compile the mandelbrot binary there
#   3. Install Python dependencies for the web server
#
# WHY A FIXED WORK DIRECTORY?
#   CRIU records the absolute binary path into the checkpoint image.
#   Each PW job lands in a unique directory (jobs/aa/NNNNN), so a restored
#   process would look for the binary at the OLD job's path — causing restore
#   to fail once that directory is cleaned up, and preventing cancel.sh from
#   finding pid.txt (which the restored process writes to the OLD shared/).
#
#   Using ~/cuda-checkpoint-work as a fixed path that every job populates
#   means CRIU images are always valid, and multiple cancel → restart cycles
#   chain correctly.

set -x

JOB_DIR="${PW_PARENT_JOB_DIR}"
WORK_DIR="${HOME}/cuda-checkpoint-work"

# ── 1. Set up work directory ──────────────────────────────────────────────────
echo "Setting up work directory: ${WORK_DIR}"

# Refresh the code/binary directories; do NOT touch checkpoints/ here —
# in restart mode start_service.sh downloads fresh images from the bucket.
rm -rf "${WORK_DIR}/bin" \
       "${WORK_DIR}/01_fractal" \
       "${WORK_DIR}/02_webserver" \
       "${WORK_DIR}/03_checkpoint"

mkdir -p "${WORK_DIR}/shared" "${WORK_DIR}/checkpoints"

cp -r "${JOB_DIR}/bin"           "${WORK_DIR}/"
cp -r "${JOB_DIR}/01_fractal"    "${WORK_DIR}/"
cp -r "${JOB_DIR}/02_webserver"  "${WORK_DIR}/"
cp -r "${JOB_DIR}/03_checkpoint" "${WORK_DIR}/"

# Fresh start: wipe shared/ so the dashboard starts clean.
# Restart mode: shared/ will be repopulated by the restored process.
if [ "${restart:-false}" != "true" ]; then
    rm -rf "${WORK_DIR}/shared" "${WORK_DIR}/checkpoints"
    mkdir -p "${WORK_DIR}/shared" "${WORK_DIR}/checkpoints"
fi

# ── 2. Compile mandelbrot in the work directory ───────────────────────────────
# The binary MUST live at its compile-time path across all job runs so that
# CRIU restore can find it.  Recompiling every job ensures the form parameters
# are always baked in, even after a restart.
echo "Compiling mandelbrot binary..."
cd "${WORK_DIR}/01_fractal"

make -B \
    WIDTH="${fractal_width:-4096}" \
    HEIGHT="${fractal_height:-4096}" \
    MAX_ITER="${fractal_max_iter:-100000}" \
    SLEEP_MS="${fractal_sleep_ms:-5000}" \
    CENTER_X="${fractal_center_x:--0.5}" \
    CENTER_Y="${fractal_center_y:-0.0}" \
    VIEW_W="${fractal_view_width:-3.5}"

echo "Binary ready: ${WORK_DIR}/01_fractal/mandelbrot"

# ── 3. Python dependencies ────────────────────────────────────────────────────
echo "Installing Python dependencies..."
pip3 install -q flask Pillow
echo "Dependencies installed."
