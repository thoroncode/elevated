.PHONY: all build run debug capture app ref compare compare-range clean

BIN = ElevatedMac/.build/release/ElevatedMac
APP = Elevated.app
APP_BIN = $(APP)/Contents/MacOS/ElevatedMac

all: build

build:
	swift build -c release --package-path ElevatedMac

# Normal playback
run: build
	$(BIN)

# Transport bar + debug overlay + console log
debug: build
	$(BIN) --debug

# Build a self-contained Elevated.app bundle (double-clickable, drag to Applications)
#   Normal:  open Elevated.app
#   Debug:   open Elevated.app --args --debug
#   CLI:     Elevated.app/Contents/MacOS/ElevatedMac --debug
app: build
	@echo "Assembling $(APP)..."
	@rm -rf $(APP)
	@mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	@cp $(BIN) $(APP)/Contents/MacOS/
	@cp -r ElevatedMac/.build/release/ElevatedMac_ElevatedMac.bundle \
	        $(APP)/Contents/Resources/
	@/usr/libexec/PlistBuddy \
	    -c "Add :CFBundleName           string Elevated" \
	    -c "Add :CFBundleIdentifier     string org.rgba.elevated" \
	    -c "Add :CFBundleVersion        string 1.0" \
	    -c "Add :CFBundleShortVersionString string 1.0" \
	    -c "Add :CFBundleExecutable     string ElevatedMac" \
	    -c "Add :CFBundlePackageType    string APPL" \
	    -c "Add :NSPrincipalClass       string NSApplication" \
	    -c "Add :NSHighResolutionCapable bool true" \
	    -c "Add :LSMinimumSystemVersion string 13.0" \
	    $(APP)/Contents/Info.plist
	@codesign --force --deep --sign - $(APP)
	@echo ""
	@echo "  Built: $(CURDIR)/$(APP)"
	@echo ""
	@echo "  Copy to Desktop:  cp -r $(CURDIR)/$(APP) ~/Desktop/"
	@echo "  Run normal:       open $(CURDIR)/$(APP)"
	@echo "  Run debug:        open $(CURDIR)/$(APP) --args --debug"

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
