#!/bin/bash
# controller.sh — Runs on the LOGIN node before the job starts.
#
# This script is PREPENDED with inputs.sh by the session runner, so all
# fractal_* variables (from the workflow form) are already exported.
#
# Responsibilities:
#   1. Compile the mandelbrot binary with form parameters baked in
#   2. Install Python dependencies for the web server

set -x

DEMO_DIR="${PW_PARENT_JOB_DIR}"

# ── 1. Compile mandelbrot ─────────────────────────────────────────────────────
echo "Compiling mandelbrot binary..."
cd "${DEMO_DIR}/01_fractal"

make -B \
    WIDTH="${fractal_width:-4096}" \
    HEIGHT="${fractal_height:-4096}" \
    MAX_ITER="${fractal_max_iter:-100000}" \
    SLEEP_MS="${fractal_sleep_ms:-200}" \
    CENTER_X="${fractal_center_x:--0.5}" \
    CENTER_Y="${fractal_center_y:-0.0}" \
    VIEW_W="${fractal_view_width:-3.5}"

echo "Binary ready: ${DEMO_DIR}/01_fractal/mandelbrot"

# ── 2. Python dependencies ────────────────────────────────────────────────────
echo "Installing Python dependencies..."
pip3 install -q flask Pillow
echo "Dependencies installed."
