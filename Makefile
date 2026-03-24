.PHONY: all build run debug capture ref compare compare-range clean

BIN = ElevatedMac/.build/release/ElevatedMac

all: build

build:
	swift build -c release --package-path ElevatedMac

# Normal playback
run: build
	$(BIN)

# Same binary, debug flag enables transport bar + overlay
# $(BIN) --debug   (or just run the binary directly with --debug)

# Transport bar + debug overlay + console log
debug: build
	$(BIN) --debug

# Run and save one PNG per second to /tmp/elevated_cap/
# Progress printed to console. Quit (Cmd-Q) after the demo ends (~215s).
capture: build
	mkdir -p /tmp/elevated_cap
	$(BIN) --capture

# Extract 1fps reference frames from elevated_8000.avi → /tmp/elevated_ref/
ref:
	bash tools/extract_ref.sh

# Compare all matching ref vs cap frames (opens in Preview)
compare:
	bash tools/compare.sh

# Compare a single second:  make compare-one T=42
compare-one:
	bash tools/compare.sh $(T) $(T)

# Compare a range of seconds:  make compare-range T0=30 T1=60
compare-range:
	bash tools/compare.sh $(T0) $(T1)

clean:
	swift package --package-path ElevatedMac clean
	rm -rf /tmp/elevated_ref /tmp/elevated_cap /tmp/elevated_cmp
