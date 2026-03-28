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
# Size strategy:
#   - All large data blobs (shader, tables) declared non-const → __DATA not __TEXT
#   - -Wl,-no_data_const → GOT/ObjC imageinfo go to __DATA, no __DATA_CONST segment
#   - Goal: 1× __TEXT page + 1× __DATA page instead of 2× __TEXT + 1× __DATA_CONST
#
# Compression pipeline (final step — do NOT pre-compress blobs before this):
#   1. clang -Os → ElevatedMac4k
#   2. strip -u + codesign --remove-signature → ElevatedMac4k.stripped
#   3. xz (ARM64 BCJ + lzma2 bt4) → 62-byte shell stub → ElevatedMac4k.4k
#   Stub: #!/bin/sh\ntail -c+63 $0|xz -d>_;chmod +x _;codesign -s- _;./_
#   Best known flags: --arm64 --lzma2=preset=9e,mf=bt4,lc=2,nice=64,depth=0 (~21% ratio)
#   Run `make compare-compress` to re-rank all candidates.
#
# Requirements for packing:
#   - xz  (brew install xz)
#
# Usage:
#   make                    — build + strip
#   make size               — build, strip, print full size report
#   make report             — size report for current build (no rebuild)
#   make hexdump            — hexdump stripped binary (pre-compression view)
#   make review             — size report + hexdump
#   make compare-compress   — rank all xz option combinations by compressed size
#   make pack               — build self-extracting xz launcher with best flags
#   make pack XZ_FLAGS='…'  — pack with custom xz flags
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
	-Wl,-no_data_const \
	-framework Metal \
	-framework QuartzCore \
	-framework AppKit \
	-framework AudioUnit \
	-lm

SRCS    = main.m $(SYNTH_DIR)/synth.c
SHADERS = ../elevated/ElevatedCore/Shaders.metal
SHADER_TOOL = strip_shaders.py
SHADER_MIN  = $(OUTDIR)/shaders.min.metal
TABLE_SRC = $(SYNTH_DIR)/music_tables_raw.h
TABLE_HDR = $(SYNTH_DIR)/music_tables_packed.h
TABLE_TOOL = pack_synth_tables.py
REPORT          = report_binary.py
SHADER_COMPARE  = compare_shader_formats.py
COMPRESS_CMP    = compare_compression.py
TINY_PACK       = tiny_pack.py
DECODER_A64     = decoder_a64.s
PACKED          = $(OUTDIR)/ElevatedMac4k.4k
# Best flags found by `make compare-compress` (ARM64 BCJ + bt4 match finder).
# Override on the command line: make pack XZ_FLAGS='...'
XZ_FLAGS       ?= --arm64 --lzma2=preset=9e,mf=bt4,lc=2,nice=64,depth=0

.PHONY: all size report review hexdump shader-compare compare-compress pack pack-run tiny-pack tiny-bench tiny-check decoder-size run shaders tables clean

all: $(STRIPPED)

# Generate shaders.h from the canonical Shaders.metal source.
# The resulting C string is what gets compiled at runtime via
# [MTLDevice newLibraryWithSource:options:error:].
shaders: shaders.h $(SHADER_MIN)
	@printf '  Header:   %s/%s (%s bytes)\n' $$(pwd) shaders.h "$$(wc -c < shaders.h | tr -d ' ')"
	@printf '  Minified: %s/%s (%s bytes)\n' $$(pwd) $(SHADER_MIN) "$$(wc -c < $(SHADER_MIN) | tr -d ' ')"

tables: $(TABLE_HDR)

$(SHADER_MIN): $(SHADERS) $(SHADER_TOOL) | $(OUTDIR)
	@echo "Writing minified shader payload from $(SHADERS)..."
	@python3 $(SHADER_TOOL) --raw $(SHADERS) > $(SHADER_MIN)
	@echo "  $(SHADER_MIN) written ($$(wc -c < $(SHADER_MIN)) bytes)"

shaders.h: $(SHADERS) $(SHADER_TOOL)
	@echo "Generating shaders.h from $(SHADERS) (comments stripped)..."
	@printf '// shaders.h — auto-generated from Shaders.metal, do not edit\n' > shaders.h
	@printf '// Regenerate with: make shaders\n\n' >> shaders.h
	@printf 'static char kMSLSource[] =\n' >> shaders.h
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
	@printf '  Binary:   %s/%s\n' $$(pwd) $(BIN)

$(STRIPPED): $(BIN)
	@cp $(BIN) $(STRIPPED)
	@strip -u $(STRIPPED)
	@codesign --remove-signature $(STRIPPED) >/dev/null 2>&1 || true
	@printf '  Stripped: %s/%s\n' $$(pwd) $(STRIPPED)

$(RUNBIN): $(STRIPPED)
	@cp $(STRIPPED) $(RUNBIN)
	@codesign -s - --force --timestamp=none $(RUNBIN) >/dev/null
	@printf '  Run bin:  %s/%s\n' $$(pwd) $(RUNBIN)

report: $(STRIPPED) $(REPORT)
	@python3 $(REPORT) $(BIN) $(STRIPPED)

hexdump: $(STRIPPED)
	@hexdump -C $(STRIPPED)

review: report hexdump

shader-compare: shaders.h $(SHADER_COMPARE)
	@python3 $(SHADER_COMPARE)

compare-compress: $(STRIPPED) $(COMPRESS_CMP)
	@python3 $(COMPRESS_CMP) $(STRIPPED)

pack: $(STRIPPED)
	@{ printf '#!/bin/sh\ntail -c+63 $$0|xz -d>_;chmod +x _;codesign -s- _;./_\n'; \
	   xz -c $(XZ_FLAGS) -- $<; } > $(PACKED) && chmod +x $(PACKED)
	@sz=$$(wc -c < $(PACKED) | tr -d ' '); \
	 printf '  Stub:   62 bytes (fixed offset 63)\n'; \
	 printf '  Packed: %s/%s  (%d bytes total)\n' $$(pwd) $(PACKED) $$sz; \
	 if [ $$sz -le 4096 ]; then printf '  Fits in 4096 bytes!\n'; \
	 else printf '  %d bytes over 4096 (%d / 4096)\n' $$(($$sz-4096)) $$sz; fi

# Grammar A custom packer (sub-160-byte ARM64 decoder).
# Total-size comparison: Grammar A vs xz+stub vs libcompression approach.
tiny-bench: $(STRIPPED) $(TINY_PACK)
	@python3 $(TINY_PACK) bench $(STRIPPED)

tiny-pack: $(STRIPPED) $(TINY_PACK)
	@python3 $(TINY_PACK) encode $(STRIPPED) $(OUTDIR)/ElevatedMac4k.lza
	@echo "  Grammar A payload: $(OUTDIR)/ElevatedMac4k.lza"

tiny-check: $(STRIPPED) $(TINY_PACK)
	@python3 $(TINY_PACK) check $(STRIPPED)

# Assemble decoder and report its exact byte size.
decoder-size: $(DECODER_A64) | $(OUTDIR)
	@clang -target arm64-apple-macos13 -c $(DECODER_A64) -o $(OUTDIR)/decoder_a64.o
	@echo "Grammar A ARM64 decoder: $$(size $(OUTDIR)/decoder_a64.o | awk 'NR==2{print $$1}') bytes (__TEXT)"
	@otool -tv $(OUTDIR)/decoder_a64.o | grep -c '^\s*[0-9a-f]' | \
	    xargs -I{} sh -c 'echo "  {} instructions × 4 bytes = $$(({} * 4)) bytes"'

size: report

pack-run: pack
	-$(PACKED)

run: $(RUNBIN)
	-$(RUNBIN)

clean:
	@rm -rf $(OUTDIR)
