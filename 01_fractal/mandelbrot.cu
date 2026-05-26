/*
 * mandelbrot.cu — CUDA Mandelbrot fractal, designed for CRIU checkpoint demos.
 *
 * Computes a large Mandelbrot image row-by-row.  Between every chunk of rows
 * it writes progress stats and a live preview to the shared/ directory so the
 * web server can display them.  A configurable SLEEP_MS pause between chunks
 * gives the operator time to issue a checkpoint before the job finishes.
 *
 * DATA WRITTEN AT RUNTIME — all under  <project_root>/shared/
 * ─────────────────────────────────────────────────────────────
 *   pid.txt        PID of this process (refreshed every chunk)
 *   progress.json  Computation stats (rows done, %, ETA, …)
 *   preview.ppm    512×512 downsampled live preview (PPM RGB)
 *   output.ppm     Full-resolution final image (written at end)
 *
 * Paths are resolved relative to the directory that contains this binary,
 * so the binary can be launched from any working directory.
 *
 * BUILD
 *   make                  # default: SLEEP_MS=200
 *   make SLEEP_MS=0       # maximum GPU speed
 *   make SLEEP_MS=1000    # slower, easier to catch for checkpoint
 *
 * RUN (foreground — shows live progress bar)
 *   ./mandelbrot
 *
 * RUN (background — recommended for checkpoint demo)
 *   ./mandelbrot > ../shared/mandelbrot.log 2>&1 &
 *   cat ../shared/pid.txt   # find the PID
 */

#include <cuda_runtime.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <limits.h>

/* ── Image parameters (all overridable with -DFOO=val at compile time) ──────── */
#ifndef WIDTH
#  define WIDTH    4096
#endif
#ifndef HEIGHT
#  define HEIGHT   4096
#endif
#ifndef MAX_ITER
#  define MAX_ITER 100000
#endif
#ifndef SLEEP_MS
#  define SLEEP_MS 200
#endif

#define CHUNK_ROWS    8   /* rows computed per GPU kernel launch               */
#define PREVIEW_W   512   /* preview image dimensions                          */
#define PREVIEW_H   512
#define PREVIEW_EVERY 4   /* write preview every N chunks                      */

/* ── View (overridable with -DCENTER_X=... etc.) ────────────────────────────── */
#ifndef CENTER_X
#  define CENTER_X (-0.5)    /* classic full Mandelbrot set                   */
#endif
#ifndef CENTER_Y
#  define CENTER_Y (0.0)
#endif
#ifndef VIEW_W
#  define VIEW_W   (3.5)     /* wide enough to show the full set              */
#endif

/* ── Paths (resolved at runtime relative to the binary) ─────────────────────── */
static char g_shared[PATH_MAX];

static void setup_paths(void) {
    char exe[PATH_MAX];
    ssize_t n = readlink("/proc/self/exe", exe, sizeof(exe) - 1);
    if (n < 0) { perror("readlink"); exit(1); }
    exe[n] = '\0';
    char *sl = strrchr(exe, '/');
    if (sl) *sl = '\0';
    snprintf(g_shared, sizeof(g_shared), "%s/../shared", exe);
}

/* ── CUDA kernel ─────────────────────────────────────────────────────────────── */
__global__ void mandelbrot_kernel(
    int   *d_chunk,
    int    start_row,
    int    num_rows,
    int    width,
    int    height,
    double cx, double cy, double vw,
    int    max_iter
) {
    int px = blockIdx.x * blockDim.x + threadIdx.x;
    int ry = blockIdx.y * blockDim.y + threadIdx.y;   /* row within chunk    */
    if (px >= width || ry >= num_rows) return;

    double vh = vw * ((double)height / width);
    double x0 = cx - vw * 0.5 + (px + 0.5) * vw / width;
    double y0 = cy - vh * 0.5 + ((start_row + ry) + 0.5) * vh / height;

    double x = 0.0, y = 0.0, x2 = 0.0, y2 = 0.0;
    int iter = 0;
    while (x2 + y2 <= 4.0 && iter < max_iter) {
        y  = 2.0 * x * y + y0;
        x  = x2 - y2 + x0;
        x2 = x * x;
        y2 = y * y;
        ++iter;
    }
    d_chunk[ry * width + px] = iter;
}

/* ── Colour mapping ─────────────────────────────────────────────────────────── */
/* Log-scale normalisation: t=iter/MAX_ITER is linear and compresses all fast-
   escaping pixels into near-zero when MAX_ITER is large.  log1p spreads the
   range so iter=1000 out of 500000 gets t≈0.35 rather than t=0.002.          */
static void iter_to_rgb(int iter, unsigned char *r, unsigned char *g, unsigned char *b) {
    if (iter == MAX_ITER) { *r = *g = *b = 0; return; }

    double t = log1p((double)iter) / log1p((double)MAX_ITER);

    /* 5-stop gradient:  black → blue → cyan → white → yellow → red           */
    double rv, gv, bv;
    if (t < 0.25) {
        double s = t / 0.25;
        rv = 0;   gv = 0;   bv = s;
    } else if (t < 0.5) {
        double s = (t - 0.25) / 0.25;
        rv = 0;   gv = s;   bv = 1.0;
    } else if (t < 0.75) {
        double s = (t - 0.5) / 0.25;
        rv = s;   gv = 1.0; bv = 1.0 - s;
    } else {
        double s = (t - 0.75) / 0.25;
        rv = 1.0; gv = 1.0 - s; bv = 0;
    }

    *r = (unsigned char)(rv * 255);
    *g = (unsigned char)(gv * 255);
    *b = (unsigned char)(bv * 255);
}

/* ── I/O helpers ─────────────────────────────────────────────────────────────── */
static void write_pid(void) {
    char p[PATH_MAX];
    snprintf(p, sizeof(p), "%s/pid.txt", g_shared);
    FILE *f = fopen(p, "w");
    if (f) { fprintf(f, "%d\n", getpid()); fclose(f); }
}

static void remove_pid(void) {
    char p[PATH_MAX];
    snprintf(p, sizeof(p), "%s/pid.txt", g_shared);
    remove(p);
}

static void write_progress(int rows_done, double elapsed, const char *status) {
    write_pid();   /* refresh PID every chunk (critical for post-restore detection) */

    char p[PATH_MAX];
    snprintf(p, sizeof(p), "%s/progress.json", g_shared);
    FILE *f = fopen(p, "w");
    if (!f) return;

    double pct = 100.0 * rows_done / HEIGHT;
    double eta = (rows_done > 0 && rows_done < HEIGHT)
                 ? elapsed / rows_done * (HEIGHT - rows_done) : 0.0;

    fprintf(f,
        "{\n"
        "  \"status\":      \"%s\",\n"
        "  \"rows_done\":   %d,\n"
        "  \"total_rows\":  %d,\n"
        "  \"percent\":     %.2f,\n"
        "  \"elapsed_sec\": %.1f,\n"
        "  \"eta_sec\":     %.1f,\n"
        "  \"width\":       %d,\n"
        "  \"height\":      %d,\n"
        "  \"max_iter\":    %d,\n"
        "  \"sleep_ms\":    %d,\n"
        "  \"center_x\":    %.8f,\n"
        "  \"center_y\":    %.8f,\n"
        "  \"view_width\":  %.6f\n"
        "}\n",
        status, rows_done, HEIGHT, pct, elapsed, eta,
        WIDTH, HEIGHT, MAX_ITER, SLEEP_MS,
        CENTER_X, CENTER_Y, VIEW_W);
    fclose(f);
}

/* 512×512 downsampled preview — fast to write, browser-friendly size */
static void write_preview(int *h_result, int rows_done) {
    char p[PATH_MAX];
    snprintf(p, sizeof(p), "%s/preview.ppm", g_shared);
    FILE *f = fopen(p, "wb");
    if (!f) return;

    fprintf(f, "P6\n%d %d\n255\n", PREVIEW_W, PREVIEW_H);
    for (int py = 0; py < PREVIEW_H; py++) {
        int sy = (int)((double)py * HEIGHT / PREVIEW_H);
        for (int px = 0; px < PREVIEW_W; px++) {
            int sx = (int)((double)px * WIDTH  / PREVIEW_W);
            unsigned char r, g, b;
            if (sy < rows_done)
                iter_to_rgb(h_result[sy * WIDTH + sx], &r, &g, &b);
            else
                r = g = b = 18;   /* dark grey — not yet computed             */
            fputc(r, f); fputc(g, f); fputc(b, f);
        }
    }
    fclose(f);
}

static void write_output(int *h_result) {
    char p[PATH_MAX];
    snprintf(p, sizeof(p), "%s/output.ppm", g_shared);
    FILE *f = fopen(p, "wb");
    if (!f) return;
    fprintf(f, "P6\n%d %d\n255\n", WIDTH, HEIGHT);
    for (int i = 0; i < HEIGHT * WIDTH; i++) {
        unsigned char r, g, b;
        iter_to_rgb(h_result[i], &r, &g, &b);
        fputc(r, f); fputc(g, f); fputc(b, f);
    }
    fclose(f);
    printf("Full image written: %s/output.ppm\n", g_shared);
}

/* ── Main ────────────────────────────────────────────────────────────────────── */
int main(void) {
    setup_paths();

    printf("=== CUDA Mandelbrot (cuda-checkpoint demo) ===\n");
    printf("  Image:      %d x %d  |  max_iter: %d  |  sleep: %d ms/chunk\n",
           WIDTH, HEIGHT, MAX_ITER, SLEEP_MS);
    printf("  View:       center=(%.5f, %.5f)  width=%.5f\n",
           CENTER_X, CENTER_Y, VIEW_W);
    printf("  PID:        %d\n", getpid());
    printf("  Shared dir: %s/\n\n", g_shared);

    /* Allocate host buffer — zero-initialised so uncomputed rows are black   */
    int *h_result = (int *)calloc((size_t)HEIGHT * WIDTH, sizeof(int));
    if (!h_result) { fputs("OOM\n", stderr); return 1; }

    int *d_chunk;
    if (cudaMalloc(&d_chunk, (size_t)CHUNK_ROWS * WIDTH * sizeof(int)) != cudaSuccess) {
        fputs("cudaMalloc failed\n", stderr); return 1;
    }

    int  num_chunks = (HEIGHT + CHUNK_ROWS - 1) / CHUNK_ROWS;
    dim3 block(32, 8);
    dim3 grid((WIDTH + 31) / 32, (CHUNK_ROWS + 7) / 8);

    struct timespec t0;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    write_progress(0, 0.0, "running");

    for (int c = 0; c < num_chunks; c++) {
        int start_row = c * CHUNK_ROWS;
        int rows_this = (start_row + CHUNK_ROWS <= HEIGHT)
                        ? CHUNK_ROWS : (HEIGHT - start_row);

        mandelbrot_kernel<<<grid, block>>>(
            d_chunk, start_row, rows_this,
            WIDTH, HEIGHT, CENTER_X, CENTER_Y, VIEW_W, MAX_ITER);
        cudaDeviceSynchronize();

        cudaMemcpy(h_result + (size_t)start_row * WIDTH, d_chunk,
                   (size_t)rows_this * WIDTH * sizeof(int),
                   cudaMemcpyDeviceToHost);

        struct timespec tn;
        clock_gettime(CLOCK_MONOTONIC, &tn);
        double elapsed = (tn.tv_sec - t0.tv_sec)
                       + (tn.tv_nsec - t0.tv_nsec) * 1e-9;
        int rows_done = start_row + rows_this;

        write_progress(rows_done, elapsed, "running");

        if (PREVIEW_EVERY > 0 && (c % PREVIEW_EVERY == 0 || c == num_chunks - 1))
            write_preview(h_result, rows_done);

        if (c % 16 == 0 || c == num_chunks - 1) {
            double pct = 100.0 * rows_done / HEIGHT;
            double eta = (rows_done > 0)
                         ? elapsed / rows_done * (HEIGHT - rows_done) : 0.0;
            printf("\r  [%5.1f%%]  row %d/%d  elapsed %.1fs  eta %.1fs   ",
                   pct, rows_done, HEIGHT, elapsed, eta);
            fflush(stdout);
        }

#if SLEEP_MS > 0
        {
            struct timespec ts = {
                SLEEP_MS / 1000,
                (long)(SLEEP_MS % 1000) * 1000000L
            };
            nanosleep(&ts, NULL);
        }
#endif
    }

    printf("\n\nSaving full image…\n");
    struct timespec tn;
    clock_gettime(CLOCK_MONOTONIC, &tn);
    double total = (tn.tv_sec - t0.tv_sec) + (tn.tv_nsec - t0.tv_nsec) * 1e-9;

    write_output(h_result);
    write_preview(h_result, HEIGHT);
    write_progress(HEIGHT, total, "complete");

    printf("Total time: %.1f s\n", total);

    free(h_result);
    cudaFree(d_chunk);
    remove_pid();
    return 0;
}
