CC = clang
ARCHS = -arch arm64 -arch x86_64
MIN_VERSION = -mmacosx-version-min=14.0
FRAMEWORKS = -framework Foundation -framework AppKit -framework AVFoundation
OBJC_FLAGS = -fobjc-arc -fmodules
LINKER_FLAGS = -undefined dynamic_lookup -dynamiclib
INSTALL_NAME = -install_name @rpath/FCPBridge.framework/Versions/A/FCPBridge

SOURCES = Sources/FCPBridge.m \
          Sources/FCPBridgeRuntime.m \
          Sources/FCPBridgeSwizzle.m \
          Sources/FCPBridgeServer.m \
          Sources/FCPTranscriptPanel.m

BUILD_DIR = build
OUTPUT = $(BUILD_DIR)/FCPBridge

# Modded app paths
MODDED_APP = $(HOME)/Desktop/FinalCutPro_Modded/Final Cut Pro.app
FW_DIR = $(MODDED_APP)/Contents/Frameworks/FCPBridge.framework
ENTITLEMENTS = entitlements.plist

.PHONY: all clean deploy launch

all: $(OUTPUT)

$(OUTPUT): $(SOURCES) Sources/FCPBridge.h
	@mkdir -p $(BUILD_DIR)
	$(CC) $(ARCHS) $(MIN_VERSION) $(FRAMEWORKS) $(OBJC_FLAGS) $(LINKER_FLAGS) \
		$(INSTALL_NAME) -I Sources \
		$(SOURCES) -o $(OUTPUT)
	@echo "Built: $(OUTPUT)"
	@file $(OUTPUT)

clean:
	rm -rf $(BUILD_DIR)

deploy: $(OUTPUT)
	@echo "=== Deploying FCPBridge to modded FCP ==="
	@mkdir -p "$(FW_DIR)/Versions/A/Resources"
	cp $(OUTPUT) "$(FW_DIR)/Versions/A/FCPBridge"
	@# Create framework symlinks (must use cd for relative paths)
	@cd "$(FW_DIR)/Versions" && ln -sf A Current
	@cd "$(FW_DIR)" && ln -sf Versions/Current/FCPBridge FCPBridge
	@cd "$(FW_DIR)" && ln -sf Versions/Current/Resources Resources
	@# Create Info.plist if missing
	@test -f "$(FW_DIR)/Versions/A/Resources/Info.plist" || \
		printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.custom.FCPBridge</string><key>CFBundleName</key><string>FCPBridge</string><key>CFBundleVersion</key><string>1.0.0</string><key>CFBundlePackageType</key><string>FMWK</string><key>CFBundleExecutable</key><string>FCPBridge</string></dict></plist>' \
		> "$(FW_DIR)/Versions/A/Resources/Info.plist"
	@# Add speech recognition usage description for transcript feature
	@/usr/libexec/PlistBuddy -c "Add :NSSpeechRecognitionUsageDescription string 'FCPBridge uses speech recognition to transcribe timeline audio for text-based editing.'" "$(MODDED_APP)/Contents/Info.plist" 2>/dev/null || true
	@# Sign the framework
	codesign --force --sign - "$(FW_DIR)"
	@# Re-sign the app
	codesign --force --sign - --entitlements $(ENTITLEMENTS) "$(MODDED_APP)"
	@codesign --verify --verbose "$(MODDED_APP)" 2>&1
	@echo "=== Deployed successfully ==="

launch: deploy
	@echo "=== Launching modded FCP with FCPBridge ==="
	DYLD_INSERT_LIBRARIES="$(FW_DIR)/Versions/A/FCPBridge" \
		"$(MODDED_APP)/Contents/MacOS/Final Cut Pro" &
	@echo "FCP launched. Check Console.app for [FCPBridge] messages."
	@echo "Connect: echo '{\"jsonrpc\":\"2.0\",\"method\":\"system.version\",\"id\":1}' | nc -U /tmp/fcpbridge.sock"
