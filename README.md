# cuda-checkpoint demo

Three independent components that together demonstrate live process migration
of a CUDA application using [cuda-checkpoint](https://github.com/NVIDIA/cuda-checkpoint)
and [CRIU](https://criu.org/).

```
01_fractal/     CUDA Mandelbrot computation (long-running GPU job)
02_webserver/   Flask dashboard — live progress and fractal preview
03_checkpoint/  Scripts: freeze the job, snapshot to disk, restore/migrate
```

---

## Requirements

| Tool | Version | Check |
|------|---------|-------|
| NVIDIA driver | ≥ 550 | `nvidia-smi` |
| CUDA / nvcc | 12.x | `nvcc --version` |
| CRIU | 3.x | `criu --version` |
| Python | 3.8+ | `python3 --version` |
| cuda-checkpoint | bundled | `bin/cuda-checkpoint --help` |

Install Python dependencies once:
```bash
pip3 install -r 02_webserver/requirements.txt
```

---

## Directory layout

```
cuda-checkpoint-demo/
├── bin/
│   └── cuda-checkpoint          pre-built NVIDIA binary
│
├── shared/                      ← RUNTIME DATA (written by computation)
│   ├── pid.txt                  PID of running mandelbrot process
│   ├── progress.json            Stats: percent done, ETA, view params
│   ├── preview.ppm              512×512 live preview image
│   ├── output.ppm               Full-resolution final image (written at end)
│   └── mandelbrot.log           stdout log
│
├── checkpoints/                 ← CHECKPOINT DATA (what you migrate!)
│   ├── *.img                    CRIU binary process snapshot
│   ├── metadata.json            Human-readable: timestamp, host, progress %
│   └── criu*.log                CRIU operation logs
│
├── 01_fractal/                  Component 1
├── 02_webserver/                Component 2
└── 03_checkpoint/               Component 3
```

---

## Quick start

### Terminal 1 — start the computation

```bash
cd 01_fractal
./run.sh --preset demo      # 4096×4096, ~2 min
```

Presets:

| Preset | Resolution | Max iter | Sleep | Duration |
|--------|-----------|----------|-------|---------|
| `fast` | 2048×2048 | 10 000 | none | ~10 s |
| `demo` | 4096×4096 | 100 000 | 200 ms/chunk | ~2 min |
| `long` | 8192×8192 | 500 000 | none | ~10 min |

Or set parameters explicitly:
```bash
./run.sh --width 8192 --height 8192 --max-iter 500000 --sleep 0
```

### Terminal 2 — start the web dashboard

```bash
cd 02_webserver
python3 server.py
# Open http://localhost:8080/
```

### Checkpoint the running job

```bash
cd 03_checkpoint
./checkpoint.sh
# The process is now stopped; snapshot is in ../checkpoints/
```

### Restore the job

```bash
./restore.sh
# Process resumes from exactly where it was frozen
```

---

## Migrate to another machine

```bash
# 1. Checkpoint on source (stops the process)
./03_checkpoint/checkpoint.sh

# 2. Copy ONLY the checkpoints/ directory to the target
rsync -av checkpoints/ user@target-host:/same/path/checkpoints/

# 3. On target: build the binary at the same absolute path
cd 01_fractal && make

# 4. On target: restore
cd 03_checkpoint && ./restore.sh
```

The `shared/` directory does **not** need to be copied — only `checkpoints/`
contains the actual process snapshot.

---

## How it works

```
cuda-checkpoint --toggle   suspends CUDA: copies device memory → host RAM,
                           releases GPU resources. All CUDA API calls block.

criu dump                  snapshots the Linux process: CPU registers, virtual
                           memory (now including ex-GPU data), file descriptors.
                           Terminates the process.

criu restore               recreates the process. It resumes at its last
                           instruction and blocks at the next CUDA call
                           (GPU still suspended).

cuda-checkpoint --toggle   resumes CUDA: reacquires GPU, restores device memory,
                           rebuilds CUDA objects, unblocks all pending calls.
```

---

## Notes

- `criu dump` and `criu restore` require `sudo` — only those two calls, not the rest.
- Does not support UVM or IPC memory (current cuda-checkpoint limitation).
- Source and target machines must have the same GPU driver version.
- The binary must be at the **same absolute path** on both machines.
