.PHONY: all build run debug capture app icon ref compare compare-range clean

BIN       = ElevatedMac/.build/release/ElevatedMac
APP       = Elevated.app
APP_BIN   = $(APP)/Contents/MacOS/ElevatedMac
ICON_TIME = 185.867
ICON_SRC  = assets/icon_source.png
ICON_ICNS = assets/icon.icns

all: build

build:
	swift build -c release --package-path ElevatedMac

# Normal playback
run: build
	$(BIN)

# Transport bar + debug overlay + console log
debug: build
	$(BIN) --debug

# Render the app icon from the demo at t=185.867s (00:03:05:52) and build icon.icns
icon: build
	@mkdir -p assets
	@echo "Rendering icon frame at t=$(ICON_TIME)s..."
	@$(BIN) --icon-at=$(ICON_TIME) --icon-out=$(ICON_SRC)
	@echo "Building iconset..."
	@rm -rf /tmp/Elevated.iconset && mkdir /tmp/Elevated.iconset
	@sips -c 1080 1080 $(ICON_SRC) --out /tmp/icon_sq.png > /dev/null
	@sips -z 16   16   /tmp/icon_sq.png --out /tmp/Elevated.iconset/icon_16x16.png      > /dev/null
	@sips -z 32   32   /tmp/icon_sq.png --out /tmp/Elevated.iconset/icon_16x16@2x.png   > /dev/null
	@sips -z 32   32   /tmp/icon_sq.png --out /tmp/Elevated.iconset/icon_32x32.png      > /dev/null
	@sips -z 64   64   /tmp/icon_sq.png --out /tmp/Elevated.iconset/icon_32x32@2x.png   > /dev/null
	@sips -z 128  128  /tmp/icon_sq.png --out /tmp/Elevated.iconset/icon_128x128.png    > /dev/null
	@sips -z 256  256  /tmp/icon_sq.png --out /tmp/Elevated.iconset/icon_128x128@2x.png > /dev/null
	@sips -z 256  256  /tmp/icon_sq.png --out /tmp/Elevated.iconset/icon_256x256.png    > /dev/null
	@sips -z 512  512  /tmp/icon_sq.png --out /tmp/Elevated.iconset/icon_256x256@2x.png > /dev/null
	@sips -z 512  512  /tmp/icon_sq.png --out /tmp/Elevated.iconset/icon_512x512.png    > /dev/null
	@sips -z 1024 1024 /tmp/icon_sq.png --out /tmp/Elevated.iconset/icon_512x512@2x.png > /dev/null
	@iconutil -c icns /tmp/Elevated.iconset -o $(ICON_ICNS)
	@rm -rf /tmp/Elevated.iconset /tmp/icon_sq.png
	@echo "Icon: $(ICON_ICNS)"

# Build a self-contained Elevated.app bundle (double-clickable, drag to Applications)
#   Normal:  open Elevated.app
#   Debug:   open Elevated.app --args --debug
#   CLI:     Elevated.app/Contents/MacOS/ElevatedMac --debug
app: build icon
	@echo "Assembling $(APP)..."
	@rm -rf $(APP)
	@mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	@cp $(BIN) $(APP)/Contents/MacOS/
	@cp -r ElevatedMac/.build/release/ElevatedMac_ElevatedMac.bundle \
	        $(APP)/Contents/Resources/
	@cp $(ICON_ICNS) $(APP)/Contents/Resources/
	@/usr/libexec/PlistBuddy \
	    -c "Add :CFBundleName           string Elevated" \
	    -c "Add :CFBundleIdentifier     string org.rgba.elevated" \
	    -c "Add :CFBundleVersion        string 1.0" \
	    -c "Add :CFBundleShortVersionString string 1.0" \
	    -c "Add :CFBundleExecutable     string ElevatedMac" \
	    -c "Add :CFBundlePackageType    string APPL" \
	    -c "Add :CFBundleIconFile       string icon" \
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
