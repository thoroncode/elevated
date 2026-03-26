# elevated4k/Makefile
# Size-optimized macOS 4K intro build.
#
# Architecture:
#   - One Objective-C file (main.m) — no Swift runtime
#   - CAMetalLayer + CVDisplayLink — no MetalKit overhead
#   - MSL shaders inline as C string — no compiled .metallib
#   - Synth shared from ../elevated/CSynth/ — no duplication
#   - AudioUnit for audio output
#
# Build pipeline:
#   1. clang -Os → ElevatedMac4k  (~60-80KB)
#   2. strip -x  → stripped       (~40-50KB)
#   3. (optional) custom packer   → packed    (target: <8KB)
#
# Usage:
#   make          — build + strip
#   make size     — build, strip, show section sizes + final byte count
#   make run      — build and run
#   make clean    — remove build artifacts

CC      = clang
OUTDIR  = build
BIN     = $(OUTDIR)/ElevatedMac4k
STRIPPED = $(OUTDIR)/ElevatedMac4k.stripped

SYNTH_DIR = ../elevated/CSynth

CFLAGS  = \
	-Os \
	-mmacosx-version-min=26.0 \
	-fno-stack-protector \
	-fomit-frame-pointer \
	-fno-exceptions \
	-fno-unwind-tables \
	-fno-asynchronous-unwind-tables \
	-ffunction-sections \
	-fdata-sections \
	-I$(SYNTH_DIR)/include

LDFLAGS = \
	-Wl,-dead_strip \
	-Wl,-no_compact_unwind \
	-framework Metal \
	-framework QuartzCore \
	-framework AppKit \
	-framework AudioUnit \
	-framework CoreAudio \
	-framework Accelerate \
	-lm

SRCS    = main.m $(SYNTH_DIR)/synth.c
SHADERS = ../elevated/ElevatedCore/Shaders.metal

.PHONY: all size run shaders clean

all: $(STRIPPED)

# Generate shaders.h from the canonical Shaders.metal source.
# The resulting C string is what gets compiled at runtime via
# [MTLDevice newLibraryWithSource:options:error:].
shaders: $(SHADERS)
	@echo "Generating shaders.h from $(SHADERS) (comments stripped)..."
	@printf '// shaders.h — auto-generated from Shaders.metal, do not edit\n' > shaders.h
	@printf '// Regenerate with: make shaders\n\n' >> shaders.h
	@printf 'static const char kMSLSource[] =\n' >> shaders.h
	@python3 strip_shaders.py $(SHADERS) >> shaders.h
	@printf '    ;\n' >> shaders.h
	@echo "  shaders.h written ($$(wc -c < shaders.h) bytes)"

$(OUTDIR):
	@mkdir -p $(OUTDIR)

$(BIN): $(SRCS) shaders.h | $(OUTDIR)
	$(CC) $(CFLAGS) $(LDFLAGS) $(SRCS) -o $(BIN)

$(STRIPPED): $(BIN)
	@cp $(BIN) $(STRIPPED)
	@strip -x $(STRIPPED)

size: $(STRIPPED)
	@echo ""
	@echo "=== Section sizes (unstripped) ==="
	@size $(BIN)
	@echo ""
	@echo "=== Final stripped binary ==="
	@ls -la $(STRIPPED)
	@echo ""
	@printf "  Bytes: %d\n" $$(wc -c < $(STRIPPED))
	@printf "  KB:    %d\n" $$(( $$(wc -c < $(STRIPPED)) / 1024 ))
	@echo ""
	@echo "=== For comparison: original Windows EXE ==="
	@ls -la ../elevated_1920_1080.exe 2>/dev/null || echo "  (not found)"

run: $(STRIPPED)
	$(STRIPPED)

clean:
	@rm -rf $(OUTDIR)
