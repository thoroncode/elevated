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
#   2. strip -u  → stripped       (~40-50KB)
#   3. (optional) custom packer   → packed    (target: <8KB)
#
# Usage:
#   make          — build + strip
#   make size     — build, strip, and print the full size report
#   make report   — print the size report for the current build
#   make run      — build and run
#   make clean    — remove build artifacts

CC      = clang
OUTDIR  = build
BIN     = $(OUTDIR)/ElevatedMac4k
STRIPPED = $(OUTDIR)/ElevatedMac4k.stripped
RUNBIN   = $(OUTDIR)/ElevatedMac4k.run

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
	-Wl,-no_function_starts \
	-Wl,-no_compact_unwind \
	-framework Metal \
	-framework QuartzCore \
	-framework AppKit \
	-framework AudioUnit \
	-lm

SRCS    = main.m $(SYNTH_DIR)/synth.c
SHADERS = ../elevated/ElevatedCore/Shaders.metal
SHADER_TOOL = strip_shaders.py
TABLE_SRC = $(SYNTH_DIR)/music_tables_raw.h
TABLE_HDR = $(SYNTH_DIR)/music_tables_packed.h
TABLE_TOOL = pack_synth_tables.py
REPORT  = report_binary.py

.PHONY: all size report review run shaders tables clean

all: $(STRIPPED)

# Generate shaders.h from the canonical Shaders.metal source.
# The resulting C string is what gets compiled at runtime via
# [MTLDevice newLibraryWithSource:options:error:].
shaders: shaders.h

tables: $(TABLE_HDR)

shaders.h: $(SHADERS) $(SHADER_TOOL)
	@echo "Generating shaders.h from $(SHADERS) (comments stripped)..."
	@printf '// shaders.h — auto-generated from Shaders.metal, do not edit\n' > shaders.h
	@printf '// Regenerate with: make shaders\n\n' >> shaders.h
	@printf 'static const char kMSLSource[] =\n' >> shaders.h
	@python3 $(SHADER_TOOL) $(SHADERS) >> shaders.h
	@printf '    ;\n' >> shaders.h
	@echo "  shaders.h written ($$(wc -c < shaders.h) bytes)"

$(TABLE_HDR): $(TABLE_SRC) $(TABLE_TOOL)
	@echo "Packing synth tables from $(TABLE_SRC)..."
	@python3 $(TABLE_TOOL) $(TABLE_SRC) $(TABLE_HDR)
	@echo "  $(TABLE_HDR) written ($$(wc -c < $(TABLE_HDR)) bytes)"

$(OUTDIR):
	@mkdir -p $(OUTDIR)

$(BIN): $(SRCS) shaders.h $(TABLE_HDR) | $(OUTDIR)
	$(CC) $(CFLAGS) $(LDFLAGS) $(SRCS) -o $(BIN)

$(STRIPPED): $(BIN)
	@cp $(BIN) $(STRIPPED)
	@strip -u $(STRIPPED)
	@codesign --remove-signature $(STRIPPED) >/dev/null 2>&1 || true

$(RUNBIN): $(STRIPPED)
	@cp $(STRIPPED) $(RUNBIN)
	@codesign -s - --force --timestamp=none $(RUNBIN) >/dev/null

report: $(STRIPPED) $(REPORT)
	@python3 $(REPORT) $(BIN) $(STRIPPED)

review: report
	@echo
	@echo "=== Stripped Binary Hexdump ==="
	@hexdump -C $(STRIPPED)

size: report

run: $(RUNBIN)
	$(RUNBIN)

clean:
	@rm -rf $(OUTDIR)
