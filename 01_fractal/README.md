# Component 1 — CUDA Mandelbrot Fractal

Computes a Mandelbrot fractal image in a long-running GPU loop.
Resolution, iteration depth, and pacing are all configurable at build time.

---

## Files

| File | Description |
|------|-------------|
| `mandelbrot.cu` | CUDA C source |
| `Makefile` | Build rules |
| `run.sh` | Configure, compile, and launch in one step |
| `mandelbrot` | Compiled binary (after build) |

---

## Quickstart

```bash
cd 01_fractal
./run.sh               # uses defaults (4096×4096, 100k iter, 200ms sleep)
./run.sh --preset demo # explicit preset
```

---

## run.sh

The recommended way to launch. Compiles with the chosen parameters and starts
the binary in the background.

```bash
# Presets
./run.sh --preset fast    # 2048×2048, 10k iter,  no sleep   (~10 s)
./run.sh --preset demo    # 4096×4096, 100k iter, 200ms sleep (~2 min)
./run.sh --preset long    # 8192×8192, 500k iter, no sleep   (~10 min)

# Manual flags (all optional, use defaults for anything omitted)
./run.sh --width 8192 --height 8192 --max-iter 500000 --sleep 0

# Run in the foreground instead of background
./run.sh --preset demo --foreground
```

---

## Parameters

| Parameter | Default | Effect |
|-----------|---------|--------|
| `WIDTH` / `HEIGHT` | 4096 | Image resolution — doubles both → 4× GPU work |
| `MAX_ITER` | 100 000 | Max iterations per pixel — main quality/speed knob |
| `SLEEP_MS` | 200 | Host sleep between row-chunks (ms) — controls pacing without changing GPU work |
| `CHUNK_ROWS` | 8 | Rows per GPU kernel launch (hardcoded, edit source to change) |
| `CENTER_X/Y` | Seahorse Valley | Fractal view centre (edit source) |
| `VIEW_W` | 0.6 | Complex-plane window width (edit source) |

**To run longer:** increase `--max-iter` or `--sleep`, or both.  
**To get more detail:** increase `--width`/`--height` and `--max-iter` together.

---

## Data written at runtime

All output lives under **`<project_root>/shared/`** — one directory above this one.

| File | When written | Contents |
|------|-------------|----------|
| `shared/pid.txt` | Every chunk | PID of this process — read by `checkpoint.sh` |
| `shared/progress.json` | Every chunk | `status`, `percent`, `rows_done`, `elapsed_sec`, `eta_sec`, view params |
| `shared/preview.ppm` | Every 4 chunks | 512×512 PPM preview — displayed by the web dashboard |
| `shared/output.ppm` | End of computation | Full-resolution final image |
| `shared/mandelbrot.log` | If stdout is redirected | Progress log |

> **For migration:** only `checkpoints/` needs to be copied to the target machine.
> The `shared/` files are monitoring artefacts and are not required for restore.

---

## Building manually

```bash
make                                          # defaults
make SLEEP_MS=1000                            # slower pacing
make WIDTH=8192 HEIGHT=8192 MAX_ITER=500000   # high-res, no sleep
```

---

## Test independently

```bash
./run.sh --preset fast
sleep 3
cat ../shared/progress.json
ls -lh ../shared/preview.ppm
kill $(cat ../shared/pid.txt)
```
