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
#   1. clang -Os → ElevatedMac4k  (~50KB)
#   2. strip -u  → stripped       (~50KB)
#   3. xz pack   → shell launcher (~?KB, target: <4KB)
#
# Requirements for packing:
#   - xz (brew install xz)
#
# Usage:
#   make                    — build + strip
#   make size               — build, strip, print full size report
#   make report             — print size report for current build
#   make compare-compress   — rank all xz options by compressed size
#   make pack               — build self-extracting xz launcher (best flags)
#   make pack XZ_FLAGS='-9' — pack with custom xz flags
#   make run                — build and run
#   make clean              — remove build artifacts

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
REPORT          = report_binary.py
SHADER_COMPARE  = compare_shader_formats.py
COMPRESS_CMP    = compare_compression.py
PACK_TOOL       = make_pack.py
PACKED          = $(OUTDIR)/ElevatedMac4k.4k
XZ_FLAGS       ?= -9 --extreme

.PHONY: all size report review shader-compare compare-compress pack run shaders tables clean

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

shader-compare: shaders.h $(SHADER_COMPARE)
	@python3 $(SHADER_COMPARE)

compare-compress: $(STRIPPED) $(COMPRESS_CMP)
	@python3 $(COMPRESS_CMP) $(STRIPPED)

pack: $(STRIPPED) $(PACK_TOOL)
	@python3 $(PACK_TOOL) $(STRIPPED) $(PACKED) $(XZ_FLAGS)
	@echo "  Packed: $(PACKED) ($$(wc -c < $(PACKED)) bytes)"

size: report

run: $(RUNBIN)
	$(RUNBIN)

clean:
	@rm -rf $(OUTDIR)
