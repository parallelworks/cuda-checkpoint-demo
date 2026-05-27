NVCC      := nvcc
TARGET    := mandelbrot

WIDTH     ?= 4096
HEIGHT    ?= 4096
MAX_ITER  ?= 100000
SLEEP_MS  ?= 5000
CENTER_X  ?= -0.5
CENTER_Y  ?= 0.0
VIEW_W    ?= 3.5

NVCC_FLAGS := -O2 -arch=native -std=c++14 \
              -DWIDTH=$(WIDTH) -DHEIGHT=$(HEIGHT) \
              -DMAX_ITER=$(MAX_ITER) -DSLEEP_MS=$(SLEEP_MS) \
              -DCENTER_X=$(CENTER_X) -DCENTER_Y=$(CENTER_Y) -DVIEW_W=$(VIEW_W)

.PHONY: all clean fast demo long

all: $(TARGET)

$(TARGET): mandelbrot.cu
	$(NVCC) $(NVCC_FLAGS) -o $@ $< -lm

fast: override WIDTH=2048
fast: override HEIGHT=2048
fast: override MAX_ITER=10000
fast: override SLEEP_MS=0
fast: override CENTER_X=-0.5
fast: override CENTER_Y=0.0
fast: override VIEW_W=3.5
fast: $(TARGET)

demo: override WIDTH=4096
demo: override HEIGHT=4096
demo: override MAX_ITER=100000
demo: override SLEEP_MS=5000
demo: override CENTER_X=-0.5
demo: override CENTER_Y=0.0
demo: override VIEW_W=3.5
demo: $(TARGET)

long: override WIDTH=8192
long: override HEIGHT=8192
long: override MAX_ITER=500000
long: override SLEEP_MS=0
long: override CENTER_X=-0.5
long: override CENTER_Y=0.0
long: override VIEW_W=3.5
long: $(TARGET)

clean:
	rm -f $(TARGET)
