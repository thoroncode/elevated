.PHONY: all help build run debug capture branch-frame app app-icon pkg zip src-distribution uninstall ref compare compare-one compare-range clean

BIN       = ElevatedMac/.build/release/ElevatedMac
APP       = Elevated.app
APP_BIN   = $(APP)/Contents/MacOS/ElevatedMac
ICON_TIME = 185.867
ICON_SRC  = assets/icon_source.png
ICON_ICNS = assets/icon.icns
DIST_DIR  = dist
SRC_DIST_NAME ?= elevated-src-$(shell date +%Y%m%d-%H%M%S)
SRC_DIST_ARCHIVE = $(DIST_DIR)/$(SRC_DIST_NAME).zip
SRC_DIST_OPTIONAL_FILES = LICENSE
SRC_DIST_EXCLUDE_FILES = elevated_music.wav

all: build

help:
	@echo "Available targets:"
	@echo "  all               Build release binary (default)"
	@echo "  help              Show this help"
	@echo "  build             Build release binary"
	@echo "  run               Run demo"
	@echo "  debug             Run demo with debug overlay"
	@echo "  app-icon          Regenerate app icon assets"
	@echo "  app               Build Elevated.app bundle"
	@echo "  zip               Zip Elevated.app to ~/Desktop/Elevated.zip"
	@echo "  src-distribution  Create source zip in dist/"
	@echo "  pkg               Build Elevated.pkg installer"
	@echo "  uninstall         Remove /Applications/Elevated.app"
	@echo "  capture           Capture one PNG per second to /tmp/elevated_cap/"
	@echo "  branch-frame      Capture one exact frame (use T=<sec> [BRANCHES='...'])"
	@echo "  ref               Extract reference frames to /tmp/elevated_ref/"
	@echo "  compare           Compare all matching reference/capture frames"
	@echo "  compare-one       Compare one second (use T=<sec>)"
	@echo "  compare-range     Compare range (use T0=<sec> T1=<sec>)"
	@echo "  clean             Clean Swift build artifacts and temp frame dirs"

build:
	swift build -c release --package-path ElevatedMac

# Normal playback (same binary + resources as distribution)
run: app
	$(APP_BIN)

# Transport bar + debug overlay + console log
# Runs the same binary + resource layout as the distribution (via Elevated.app)
debug: app
	$(APP_BIN) --debug

# Regenerate the app icon from the demo at t=185.867s (00:03:05:52).
# The result is committed to assets/ so this only needs to be run explicitly.
app-icon: build
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
app: build
	@echo "Assembling $(APP)..."
	@rm -rf $(APP)
	@mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	@cp $(BIN) $(APP)/Contents/MacOS/
	@cp ElevatedMac/.build/release/ElevatedMac_ElevatedMac.bundle/Shaders.metal \
	        $(APP)/Contents/Resources/
	@cp $(ICON_ICNS) $(APP)/Contents/Resources/
	@shortver=$$(printf '%s.%d.%s' $$(date +%y) $$(date +%-m) $$(date +%d)); \
	 buildver=$$(date +%H.%M); \
	 /usr/libexec/PlistBuddy \
	    -c "Add :CFBundleName           string Elevated" \
	    -c "Add :CFBundleIdentifier     string org.rgba.elevated" \
	    -c "Add :CFBundleVersion        string $$buildver" \
	    -c "Add :CFBundleShortVersionString string $$shortver" \
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

# Zip Elevated.app and drop it on the Desktop — ready to send via Slack/email
zip: app
	@echo "Zipping to ~/Desktop/Elevated.zip..."
	@cd $(dir $(APP)) && zip -qr ~/Desktop/Elevated.zip $(notdir $(APP))
	@echo "  ~/Desktop/Elevated.zip — ready to send"

# Build a source distribution archive from tracked files in the current working tree.
# Output: dist/elevated-src-YYYYMMDD-HHMMSS.zip
src-distribution:
	@mkdir -p $(DIST_DIR)
	@tmpdir=$$(mktemp -d /tmp/elevated-srcdist.XXXXXX); \
	    trap 'rm -rf "$$tmpdir"' EXIT HUP INT TERM; \
	    mkdir -p "$$tmpdir/$(SRC_DIST_NAME)"; \
	    git ls-files | while IFS= read -r path; do \
	        skip=0; \
	        for excluded in $(SRC_DIST_EXCLUDE_FILES); do \
	            if [ "$$path" = "$$excluded" ]; then \
	                skip=1; \
	                break; \
	            fi; \
	        done; \
	        if [ "$$skip" -eq 1 ]; then \
	            continue; \
	        fi; \
	        mkdir -p "$$tmpdir/$(SRC_DIST_NAME)/$$(dirname "$$path")"; \
	        cp "$$path" "$$tmpdir/$(SRC_DIST_NAME)/$$path"; \
	    done; \
	    for path in $(SRC_DIST_OPTIONAL_FILES); do \
	        if [ -f "$$path" ]; then \
	            mkdir -p "$$tmpdir/$(SRC_DIST_NAME)/$$(dirname "$$path")"; \
	            cp "$$path" "$$tmpdir/$(SRC_DIST_NAME)/$$path"; \
	        fi; \
	    done; \
	    (cd "$$tmpdir" && zip -qr "$(CURDIR)/$(SRC_DIST_ARCHIVE)" "$(SRC_DIST_NAME)"); \
	    echo ""; \
	    echo "  Source archive: $(CURDIR)/$(SRC_DIST_ARCHIVE)"; \
	    echo "  Extract and build:"; \
	    echo "    unzip $(CURDIR)/$(SRC_DIST_ARCHIVE) -d /tmp"; \
	    echo "    make -C /tmp/$(SRC_DIST_NAME) build"

# Build a macOS .pkg installer — installs Elevated.app to /Applications
# Always cleans Swift build artifacts first to guarantee a fresh binary.
pkg:
	@swift package --package-path ElevatedMac clean
	@$(MAKE) app
	@echo "Building Elevated.pkg..."
	@rm -rf /tmp/elevated_pkg_stage && cp -r $(APP) /tmp/elevated_pkg_stage
	@pkgbuild \
	    --install-location /Applications \
	    --component /tmp/elevated_pkg_stage \
	    --identifier org.rgba.elevated \
	    --version 1.0 \
	    Elevated.pkg
	@rm -rf /tmp/elevated_pkg_stage
	@echo ""
	@echo "  Installer: $(CURDIR)/Elevated.pkg"
	@echo "  Send this file — recipient double-clicks to install to /Applications"

# Remove the installed app from /Applications
uninstall:
	@if [ -d /Applications/Elevated.app ]; then \
	    sudo rm -rf /Applications/Elevated.app && echo "Uninstalled /Applications/Elevated.app"; \
	else \
	    echo "Elevated.app is not installed in /Applications"; \
	fi

# Run and save one PNG per second to /tmp/elevated_cap/
# Progress printed to console. Quit (Cmd-Q) after the demo ends (~215s).
capture: build
	mkdir -p /tmp/elevated_cap
	$(BIN) --capture

# Capture one exact frame across branches using temporary git worktrees.
# Example:
#   make branch-frame T=81.383333
#   make branch-frame T=81.383333 BRANCHES="main feature/foo" OUT_DIR=/tmp/elevated_branch_frames
branch-frame:
	@test -n "$(T)" || (echo "Usage: make branch-frame T=<seconds> [BRANCHES='main other-branch'] [OUT_DIR=/tmp/elevated_branch_frames]" && exit 1)
	bash tools/capture_branches.sh --time "$(T)" --out "$(if $(OUT_DIR),$(OUT_DIR),/tmp/elevated_branch_frames)" $(BRANCHES)

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
