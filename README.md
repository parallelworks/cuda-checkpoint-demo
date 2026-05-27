# cuda-checkpoint demo

Three independent components that together demonstrate live process migration
of a CUDA application using [cuda-checkpoint](https://github.com/NVIDIA/cuda-checkpoint)
and [CRIU](https://criu.org/).

```
01_fractal/     CUDA Mandelbrot computation (long-running GPU job)
02_webserver/   Flask dashboard — live progress and fractal preview
03_checkpoint/  Scripts: freeze the job, snapshot to disk, restore/migrate
workflow/       PW Activate workflow — run on a cloud cluster with cancel/restart
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
├── 03_checkpoint/               Component 3
└── workflow/                    PW Activate workflow
    ├── general.yaml             Workflow definition (inputs, jobs, sessions)
    ├── controller.sh            Login-node setup: compile binary, install deps
    └── start_service.sh         Compute-node job: run fractal + Flask
```

---

## Quick start (local)

### Terminal 1 — start the computation

```bash
cd 01_fractal
./run.sh --preset demo      # 4096×4096, ~9 min
```

Presets:

| Preset | Resolution | Max iter | Sleep | Duration |
|--------|-----------|----------|-------|---------|
| `fast` | 2048×2048 | 10 000 | none | ~10 s |
| `demo` | 4096×4096 | 100 000 | 1000 ms/chunk | ~9 min |
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

## PW Activate workflow

The `workflow/` directory contains a
[PW Activate](https://docs.parallel.works) workflow that runs the demo on a
cloud GPU cluster and supports **checkpoint-on-cancel** and **restart from
checkpoint** via a cloud storage bucket.

### Workflow inputs

| Input | Type | Description |
|-------|------|-------------|
| Bucket | bucket | Cloud storage bucket for checkpoint files |
| Checkpoint Path | string | Path within bucket (e.g. `cuda-demo/run-01`) |
| Restart from Checkpoint? | boolean | `false` = fresh start, `true` = resume |
| Cluster | group | Target resource, scheduler settings |
| Fractal Settings | group | Resolution, iterations, zoom, sleep interval |

Default fractal settings produce a ~15-minute run (4096×4096, 500 000 iterations,
1000 ms sleep/chunk) — long enough to cancel and checkpoint well before completion.

### Start mode (`Restart = false`)

1. `preprocessing` compiles the mandelbrot binary with the form parameters baked in
   and installs Python dependencies on the login node.
2. `session_runner` launches the job on the compute node:
   - Mandelbrot starts in its own process group (`setsid`) so platform SIGTERM
     does not reach it directly.
   - Flask dashboard opens a browser session showing live progress.
3. When the workflow is **canceled from the platform**, `cancel.sh` runs:
   - Checkpoints the mandelbrot process (`cuda-checkpoint --toggle` + `criu dump`).
   - Uploads the `checkpoints/` directory to the bucket.
   - Terminates mandelbrot.

### Restart mode (`Restart = true`)

1. Same preprocessing step.
2. On the compute node, before starting Flask:
   - Downloads `checkpoints/` from the bucket.
   - Restores the mandelbrot process (`criu restore` + `cuda-checkpoint --toggle`).
3. Computation resumes from the saved progress; Flask shows the correct percentage.

### Checkpoint files in the bucket

```
<bucket>/<bucket_path>/checkpoints/
    *.img           CRIU images
    metadata.json   { timestamp, hostname, pid_at_checkpoint, progress }
    criu.log        CRIU dump/restore log
```

### cancel.log

Every cancellation writes a detailed log to `<job_dir>/cancel.log`:

```
========================================================
cancel.sh  started : 2026-05-26T15:37:07Z
host               : my-gpu-node
job dir            : /home/user/pw/jobs/aa/00051
bucket URI         : pw://user/mybucket
upload destination : pw://user/mybucket/cuda-demo/run-01
========================================================

--- Checkpoint ---
  pid.txt PID : 12345
  Process is running — checkpointing...
  [checkpoint output]

--- Bucket upload ---
  Uploading: /home/user/.../checkpoints/
        → pw://user/mybucket/cuda-demo/run-01/
  Upload succeeded

--- Kill mandelbrot ---
  Sending SIGKILL to mandelbrot (PID 12345)...
========================================================
cancel.sh  finished: 2026-05-26T15:37:23Z
========================================================
```

### Implementation notes

**PID tracking**: `setsid(1)` forks when the calling bash is a process group
leader (the typical case for platform-launched jobs). In that case `$!` is the
short-lived wrapper process, not the mandelbrot. The mandelbrot writes its own
PID to `shared/pid.txt` at the very start of `main()` (before CUDA
initialization), and `start_service.sh` waits for that file instead of trusting
`$!`.

**Signal protection (two layers)**: Mandelbrot is launched via
`setsid bash -c "trap '' TERM HUP; exec ./mandelbrot"`.
*Layer 1 — `setsid`*: creates a new POSIX session and process group so the
platform's `kill -- -$$` (targeting the job's PGID) does not reach it.
*Layer 2 — `trap '' TERM HUP`*: sets SIGTERM and SIGHUP to `SIG_IGN` before
`exec`. POSIX guarantees `SIG_IGN` is preserved across `exec()`, so the
mandelbrot inherits it and survives even a cgroup-wide SIGTERM broadcast.
`cancel.sh` checkpoints the live CUDA process first, then kills it with
SIGKILL (which cannot be ignored) once the checkpoint is saved (or fails).

**CUDA checkpoint strategy**: `checkpoint.sh` calls `cuda-checkpoint --toggle`
directly rather than polling `--get-state` first. Polling `--get-state` in
some platform environments corrupts the checkpoint channel on the first call,
causing all subsequent `--toggle` attempts to fail. Calling `--toggle` directly
bypasses that failure path. A `kill -0` liveness check before each attempt
lets the script exit early if the process has already been terminated.

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
