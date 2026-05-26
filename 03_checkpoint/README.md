# Component 3 — Checkpoint & Restore

Two shell scripts that wrap `cuda-checkpoint` + `criu` to freeze and resume
the running Mandelbrot computation.

---

## Files

| File | Description |
|------|-------------|
| `checkpoint.sh` | Suspend GPU state, dump process to disk, terminate |
| `restore.sh` | Restore process from disk, resume GPU state |

---

## How it works

### Checkpoint sequence

```
cuda-checkpoint --toggle --pid $PID
    → locks CUDA driver APIs
    → waits for pending GPU work to finish
    → copies device memory to host RAM
    → releases GPU resources

sudo criu dump --images-dir ../checkpoints --tree $PID
    → snapshots CPU registers, virtual memory, file descriptors
    → terminates the process
```

### Restore sequence

```
sudo criu restore --images-dir ../checkpoints --restore-detached
    → recreates the process from the snapshot
    → process resumes from its last instruction
    → immediately blocks at its next CUDA call (GPU still suspended)

cuda-checkpoint --toggle --pid $NEW_PID
    → reacquires GPU
    → restores device memory and CUDA objects
    → unblocks CUDA calls — computation continues
```

---

## Checkpoint data location

```
<project_root>/
└── checkpoints/          ← ALL checkpoint data lives here
    ├── inventory.img     ┐
    ├── core-*.img        │ CRIU binary images
    ├── pages-*.img       │ (CPU + host memory)
    ├── *.img             ┘
    ├── criu.log          CRIU dump log
    ├── criu-restore.log  CRIU restore log
    └── metadata.json     Human-readable: timestamp, host, progress %
```

> **To migrate to another machine:** copy the entire `checkpoints/` directory.
> The `shared/` files (progress.json, preview.ppm) are monitoring artefacts and
> are **not** required for restore.

---

## Usage

### Checkpoint (stop process, save snapshot)

```bash
cd 03_checkpoint
./checkpoint.sh
```

### Checkpoint and keep running (live migration)

```bash
./checkpoint.sh --live    # process continues; snapshot is also saved
# then: kill the original process when the new machine is ready
```

### Restore

```bash
./restore.sh
```

---

## Migrate to another machine

```bash
# 1. On source machine — checkpoint (stop the process)
./03_checkpoint/checkpoint.sh

# 2. Copy checkpoint images to target
rsync -av checkpoints/ user@target:/path/to/cuda-checkpoint-demo/checkpoints/

# 3. On target machine — ensure binary exists at same path
cd 01_fractal && make

# 4. On target machine — restore
cd 03_checkpoint && ./restore.sh
```

---

## Note on sudo

`criu dump` and `criu restore` require elevated privileges to access
`/proc/<pid>/mem` and restore kernel state.  Only those two CRIU calls
use `sudo`; `cuda-checkpoint` runs as the regular user.

---

## Test independently

```bash
# Start computation in background
cd ../01_fractal
./mandelbrot > ../shared/mandelbrot.log 2>&1 &
sleep 5

# Checkpoint it
cd ../03_checkpoint
./checkpoint.sh

# Verify the images were written
ls -lh ../checkpoints/

# Restore it
./restore.sh

# Verify it's running again
cat ../shared/progress.json
```
