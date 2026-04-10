.PHONY: all help version stamp-version build run debug debug-compare capture branch-frame app app-icon pkg zip src-distribution uninstall ref compare compare-one compare-range clean 4k 4k-report 4k-review 4k-size 4k-shaders 4k-tables 4k-run 4k-pack-run 4k-clean ios-archive ios-upload ios-release ios-metadata ios-screenshots mac-screenshots tv-screenshots all-screenshots ios-submit ios-add-tester tv-release tv-submit

BIN       = elevated/.build/release/ElevatedMacCLI
APP       = Elevated.app
APP_BIN   = $(APP)/Contents/MacOS/ElevatedMacCLI
ICON_TIME = 185.867
ICON_SRC  = assets/icon_source.png
ICON_ICNS = assets/icon.icns
DIST_DIR  = dist
SRC_DIST_NAME ?= elevated-src-$(shell date +%Y%m%d-%H%M%S)
SRC_DIST_ARCHIVE = $(DIST_DIR)/$(SRC_DIST_NAME).zip
SRC_DIST_OPTIONAL_FILES = LICENSE
SRC_DIST_EXCLUDE_FILES = elevated_music.wav
VERSION_SCRIPT = ./scripts/version.sh

-include fastlane/.env

ELEVATED_ASC_TEAM_ID ?= TEAMIDPLACEHOLDER
ELEVATED_APPLE_TEAM_ID ?= TEAMIDPLACEHOLDER
ELEVATED_APP_IDENTIFIER ?= example.invalid.elevated
ELEVATED_MACOS_APP_IDENTIFIER ?= example.invalid.elevated.macos
ELEVATED_TESTFLIGHT_GROUP ?= Internal Testers

all: build

help:
	@echo "Available targets:"
	@echo "  all               Build release binary (default)"
	@echo "  help              Show this help"
	@echo "  version           Print the current release version stamp"
	@echo "  stamp-version     Write the current release version into Xcode projects"
	@echo "  build             Build release binary"
	@echo "  run               Run demo fullscreen with a 5s startup delay"
	@echo "  debug             Run demo with debug overlay"
	@echo "  debug-compare     Run debug split view: baseline vs current shader"
	@echo "  app-icon          Regenerate app icon assets"
	@echo "  app               Build Elevated.app bundle"
	@echo "  zip               Zip Elevated.app to ~/Desktop/Elevated-YY.M.D.zip"
	@echo "  src-distribution  Create source zip in dist/"
	@echo "  pkg               Build Elevated.pkg installer"
	@echo "  ios-archive       Build iOS archive"
	@echo "  ios-upload        Upload iOS archive to TestFlight"
	@echo "  ios-release       Archive with the current version and upload to TestFlight"
	@echo "  ios-screenshots    Generate App Store screenshots from the demo"
	@echo "  ios-metadata      Upload metadata/icon/screenshots to App Store Connect"
	@echo "  ios-submit        Submit latest build for App Store review"
	@echo "  ios-add-tester    Add tester to TestFlight (EMAIL=user@example.com)"
	@echo ""
	@echo "Apple TV:"
	@echo "  tv-release        Archive with the current version and upload tvOS to TestFlight"
	@echo "  tv-submit         Submit latest tvOS build for App Store review"
	@echo ""
	@echo "  uninstall         Remove /Applications/Elevated.app"
	@echo "  capture           Capture one PNG per second to /tmp/elevated_cap/"
	@echo "  branch-frame      Capture one exact frame (use T=<sec> [BRANCHES='...'])"
	@echo "  ref               Extract reference frames to /tmp/elevated_ref/"
	@echo "  compare           Compare all matching reference/capture frames"
	@echo "  compare-one       Compare one second (use T=<sec>)"
	@echo "  compare-range     Compare range (use T0=<sec> T1=<sec>)"
	@echo "  clean             Clean Swift, 4K build artifacts, and temp frame dirs"
	@echo ""
	@echo "4K size-optimized build (elevated4k/ — ObjC, no Swift runtime):"
	@echo "  4k                Build size-optimized binary (ObjC + inline shaders)"
	@echo "  4k-report         Build and print the detailed 4K size report"
	@echo "  4k-review         Build, report, and dump the stripped 4K binary"
	@echo "  4k-shaders        Regenerate shaders.h from Shaders.metal"
	@echo "  4k-tables         Regenerate packed synth tables"
	@echo "  4k-size           Alias for 4k-report"
	@echo "  4k-run            Build and run the 4K version (uncompressed)"
	@echo "  4k-pack-run       Pack with xz and run the self-extracting binary"
	@echo "  4k-clean          Clean 4K build artifacts"

version:
	@$(VERSION_SCRIPT) display

stamp-version:
	@./stamp-version.sh

build:
	swift build -c release --package-path elevated --product ElevatedMacCLI

# Normal playback: fullscreen by default, with a 5s startup delay.
run: app
	$(APP_BIN)

# Transport bar + debug overlay + console log
# Runs the same binary + resource layout as the distribution (via Elevated.app)
debug: app
	$(APP_BIN) --debug

debug-compare: app
	$(APP_BIN) --debug-compare

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
	@echo "Generating iOS/visionOS icons..."
	@sips -z 1024 1024 /tmp/icon_sq.png --out App/Assets.xcassets/AppIcon.appiconset/icon_1024.png > /dev/null
	@sips -z 1024 1024 /tmp/icon_sq.png --out AppVision/Assets.xcassets/AppIcon.appiconset/icon_1024.png > /dev/null
	@echo "Generating tvOS icons..."
	@sips -z 480  800  $(ICON_SRC) --out AppTV/Assets.xcassets/AppIcon.appiconset/icon_800x480.png > /dev/null
	@sips -z 720  1920 $(ICON_SRC) --out AppTV/Assets.xcassets/AppIcon.appiconset/icon_1920x720.png > /dev/null
	@sips -z 768  1280 $(ICON_SRC) --out AppTV/Assets.xcassets/AppIcon.appiconset/icon_1280x768.png > /dev/null
	@cp /tmp/icon_sq.png fastlane/metadata/app_icon.png
	@rm -rf /tmp/Elevated.iconset /tmp/icon_sq.png
	@echo "Icons: $(ICON_ICNS) + iOS/tvOS/visionOS asset catalogs + fastlane metadata"

# Build a self-contained Elevated.app bundle (double-clickable, drag to Applications)
#   Normal:  open Elevated.app
#   Debug:   open Elevated.app --args --debug
#   CLI:     Elevated.app/Contents/MacOS/ElevatedMacCLI --debug
app: build
	@echo "Assembling $(APP)..."
	@rm -rf $(APP)
	@mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	@cp $(BIN) $(APP)/Contents/MacOS/
	@xcrun -sdk macosx metal -c elevated/ElevatedCore/Shaders.metal -o /tmp/Shaders.air
	@xcrun -sdk macosx metallib /tmp/Shaders.air -o $(APP)/Contents/Resources/default.metallib
	@xcrun -sdk macosx metal -x metal -c elevated/ElevatedCore/ShadersBaseline.txt -o /tmp/ShadersBaseline.air
	@xcrun -sdk macosx metallib /tmp/ShadersBaseline.air -o $(APP)/Contents/Resources/baseline.metallib
	@rm -f /tmp/Shaders.air /tmp/ShadersBaseline.air
	@cp $(ICON_ICNS) $(APP)/Contents/Resources/
	@cp LICENSE $(APP)/Contents/Resources/
	@set -- $$($(VERSION_SCRIPT) pair); \
	    shortver=$$1; \
	    buildver=$$2; \
	    /usr/libexec/PlistBuddy \
	        -c "Add :CFBundleName           string Elevated" \
	        -c "Add :CFBundleIdentifier     string $(ELEVATED_MACOS_APP_IDENTIFIER)" \
	        -c "Add :CFBundleVersion        string $$buildver" \
	    -c "Add :CFBundleShortVersionString string $$shortver" \
	    -c "Add :CFBundleExecutable     string ElevatedMacCLI" \
	    -c "Add :CFBundlePackageType    string APPL" \
	    -c "Add :CFBundleIconFile       string icon" \
	    -c "Add :NSPrincipalClass       string NSApplication" \
	    -c "Add :NSHighResolutionCapable bool true" \
	    -c "Add :LSMinimumSystemVersion string 26.0" \
	    $(APP)/Contents/Info.plist
	@codesign --force --deep --sign - $(APP)
	@echo ""
	@echo "  Built: $(CURDIR)/$(APP)"
	@echo ""
	@echo "  Copy to Desktop:  cp -r $(CURDIR)/$(APP) ~/Desktop/"
	@echo "  Run normal:       open $(CURDIR)/$(APP)"
	@echo "  Run debug:        open $(CURDIR)/$(APP) --args --debug"
	@echo "  Run compare:      open $(CURDIR)/$(APP) --args --debug-compare"

# Zip Elevated.app and drop it on the Desktop with the stamped short version
# in the filename, e.g. Elevated-26.4.3.zip.
zip: app
	@shortver=$$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' $(APP)/Contents/Info.plist); \
	 zipname=Elevated-$$shortver.zip; \
	 echo "Zipping to ~/Desktop/$$zipname..."; \
	 cd $(dir $(APP)) && zip -qr "$$HOME/Desktop/$$zipname" $(notdir $(APP)); \
	 echo "  $$HOME/Desktop/$$zipname — ready to send"

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
	@swift package --package-path elevated clean
	@$(MAKE) app
	@echo "Building Elevated.pkg..."
	@rm -rf /tmp/elevated_pkg_stage && cp -r $(APP) /tmp/elevated_pkg_stage
	@set -- $$($(VERSION_SCRIPT) pair); \
	    shortver=$$1; \
	    pkgbuild \
	        --install-location /Applications \
	        --component /tmp/elevated_pkg_stage \
	        --identifier $(ELEVATED_MACOS_APP_IDENTIFIER) \
	        --version $$shortver \
	        Elevated.pkg
	@rm -rf /tmp/elevated_pkg_stage
	@echo ""
	@echo "  Installer: $(CURDIR)/Elevated.pkg"
	@echo "  Send this file — recipient double-clicks to install to /Applications"

IOS_ARCHIVE = /tmp/Elevated.xcarchive
IOS_EXPORT  = /tmp/ElevatedExport
IOS_EXPORT_OPTIONS = /tmp/ElevatedExportOptions.plist

# Archive the iOS app with date-stamped version
ios-archive:
	@set -- $$($(VERSION_SCRIPT) pair); \
	    shortver=$$1; \
	    buildver=$$2; \
	    echo "Archiving iOS $$shortver ($$buildver)..."; \
	    xcodebuild -project ElevatedIOS.xcodeproj -scheme Elevated \
	    -destination 'generic/platform=iOS' -configuration Release \
	    MARKETING_VERSION=$$shortver CURRENT_PROJECT_VERSION=$$buildver \
	    archive -archivePath $(IOS_ARCHIVE) 2>&1 | tail -1
	@echo "  Archive: $(IOS_ARCHIVE)"

# Upload the most recent iOS archive to App Store Connect / TestFlight
ios-upload:
	@echo "Uploading to App Store Connect..."
	@./scripts/write_export_options_plist.sh $(IOS_EXPORT_OPTIONS)
	@xcodebuild -exportArchive -archivePath $(IOS_ARCHIVE) \
	    -exportOptionsPlist $(IOS_EXPORT_OPTIONS) \
	    -exportPath $(IOS_EXPORT) \
	    -allowProvisioningUpdates 2>&1 | tail -3
	@echo "  Upload complete — check App Store Connect for processing status"

# One-step: archive with the current version and upload to TestFlight
ios-release: ios-archive ios-upload

FASTLANE = PATH="/opt/homebrew/opt/ruby/bin:/opt/homebrew/lib/ruby/gems/4.0.0/bin:$$PATH" fastlane

SS_DIR   = fastlane/screenshots/en-GB
SS_TIMES = 5.0 17.0 48.0 95.0 185.0

# Generate App Store screenshots at key demo moments.
# The macOS binary renders at 1920x1080; sips resizes for each device class.
# App Store required sizes:
#   iPhone 6.9": 1320x2868 (portrait) — we pad landscape into portrait
#   iPad 13":    2064x2752 (portrait) — padded
#   Mac:         2880x1800 or 1920x1080
#   Apple TV:    3840x2160 or 1920x1080
#   visionOS:    use Mac screenshots (same render)

ios-screenshots: build
	@mkdir -p $(SS_DIR)
	@i=1; for t in $(SS_TIMES); do \
	    echo "Capturing t=$${t}s..."; \
	    $(BIN) --icon-at=$${t} --icon-out=/tmp/ss_$${i}.png; \
	    sips -z 1320 2868 /tmp/ss_$${i}.png --out $(SS_DIR)/iPhone_6.9_$${i}.png > /dev/null 2>&1; \
	    sips -p 2064 2752 /tmp/ss_$${i}.png --out $(SS_DIR)/iPad_13_$${i}.png > /dev/null 2>&1; \
	    rm -f /tmp/ss_$${i}.png; \
	    i=$$((i+1)); \
	done
	@echo "iOS screenshots: $(SS_DIR)/"

mac-screenshots: build
	@mkdir -p $(SS_DIR)
	@i=1; for t in $(SS_TIMES); do \
	    echo "Capturing t=$${t}s..."; \
	    $(BIN) --icon-at=$${t} --icon-out=/tmp/ss_$${i}.png; \
	    sips -z 1080 1920 /tmp/ss_$${i}.png --out $(SS_DIR)/Mac_$${i}.png > /dev/null 2>&1; \
	    rm -f /tmp/ss_$${i}.png; \
	    i=$$((i+1)); \
	done
	@echo "Mac screenshots: $(SS_DIR)/"

tv-screenshots: build
	@mkdir -p $(SS_DIR)
	@i=1; for t in $(SS_TIMES); do \
	    echo "Capturing t=$${t}s..."; \
	    $(BIN) --icon-at=$${t} --icon-out=/tmp/ss_$${i}.png; \
	    sips -z 1080 1920 /tmp/ss_$${i}.png --out $(SS_DIR)/AppleTV_$${i}.png > /dev/null 2>&1; \
	    rm -f /tmp/ss_$${i}.png; \
	    i=$$((i+1)); \
	done
	@echo "Apple TV screenshots: $(SS_DIR)/"

all-screenshots: ios-screenshots mac-screenshots tv-screenshots
	@echo "All screenshots generated in $(SS_DIR)/"

# Upload metadata (description, keywords, icon, screenshots) to App Store Connect
ios-metadata:
	@test -f Elevated.pkg && mv Elevated.pkg Elevated.pkg.bak || true
	@$(FASTLANE) metadata; rc=$$?; \
	 test -f Elevated.pkg.bak && mv Elevated.pkg.bak Elevated.pkg || true; \
	 exit $$rc

# Submit the latest TestFlight build for App Store review
ios-submit:
	@$(FASTLANE) submit

# Add a tester to TestFlight internal testing
# Usage: make ios-add-tester EMAIL=user@example.com
ios-add-tester:
	@test -n "$(EMAIL)" || (echo "Usage: make ios-add-tester EMAIL=user@example.com" && exit 1)
	@$(FASTLANE) pilot add $(EMAIL) -a $(ELEVATED_APP_IDENTIFIER) -g "$(ELEVATED_TESTFLIGHT_GROUP)"

# ── Apple TV (tvOS) ───────────────────────────────────────────────────────────

tv-release:
	@$(FASTLANE) appletv release

tv-submit:
	@$(FASTLANE) appletv submit

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
	-killall ElevatedMacCLI ElevatedMac4k ElevatedMac4k.run ElevatedMac4k.4k _ 2>/dev/null
	swift package --package-path elevated clean
	$(MAKE) -C elevated4k clean
	rm -rf /tmp/elevated_ref /tmp/elevated_cap /tmp/elevated_cmp

# ── 4K size-optimized build (elevated4k/) ─────────────────────────────────────
# Separate ObjC/C build targeting minimal binary size.
# No Swift runtime, inline MSL shaders, CAMetalLayer, AudioUnit.
# Does NOT affect the main Swift build above.

4k:
	$(MAKE) -C elevated4k

4k-report:
	$(MAKE) -C elevated4k report

4k-review:
	$(MAKE) -C elevated4k review

4k-shaders:
	$(MAKE) -C elevated4k shaders

4k-tables:
	$(MAKE) -C elevated4k tables

4k-size:
	$(MAKE) -C elevated4k size

4k-run:
	$(MAKE) -C elevated4k run

4k-pack-run:
	$(MAKE) -C elevated4k pack-run

4k-clean:
	$(MAKE) -C elevated4k clean
