CC = clang
ARCHS = -arch arm64 -arch x86_64
MIN_VERSION = -mmacosx-version-min=14.0
FRAMEWORKS = -framework Foundation -framework AppKit -framework AVFoundation -framework CoreServices -framework CoreImage -framework Metal -framework MetalKit -framework QuartzCore -framework Vision
MODULE_CACHE_DIR = $(BUILD_DIR)/ModuleCache
OBJC_FLAGS = -fobjc-arc -fmodules -fmodules-cache-path=$(abspath $(MODULE_CACHE_DIR))
LINKER_FLAGS = -undefined dynamic_lookup -dynamiclib
INSTALL_NAME = -install_name @rpath/SpliceKit.framework/Versions/A/SpliceKit

SOURCES = Sources/SpliceKit.m \
          Sources/SpliceKitDualTimeline.m \
          Sources/SpliceKitDualTimelineDrag.m \
          Sources/SpliceKitRuntime.m \
          Sources/SpliceKitSwizzle.m \
          Sources/SpliceKitServer.m \
          Sources/SpliceKitURLImport.m \
          Sources/SpliceKitLogPanel.m \
          Sources/SpliceKitTranscriptPanel.m \
          Sources/SpliceKitTranscriptGrep.m \
          Sources/SpliceKitCaptionPanel.m \
          Sources/SpliceKitCommandPalette.m \
          Sources/SpliceKitDebugUI.m \
          Sources/SpliceKitStructureBlocks.m \
          Sources/SpliceKitSectionsBar.m \
          Sources/SpliceKitLiveCam.m \
          Sources/SpliceKitUprezzer.m \
          Sources/SpliceKitLua.m \
          Sources/SpliceKitLuaPanel.m \
          Sources/SpliceKitPlugins.m

BUILD_DIR = build
OUTPUT = $(BUILD_DIR)/SpliceKit

# Lua 5.4.7 (vendored, compiled as static lib)
LUA_DIR = vendor/lua-5.4.7/src
LUA_SRCS = $(filter-out $(LUA_DIR)/lua.c $(LUA_DIR)/luac.c, $(wildcard $(LUA_DIR)/*.c))
LUA_OBJS = $(patsubst $(LUA_DIR)/%.c, $(BUILD_DIR)/lua/%.o, $(LUA_SRCS))
LUA_LIB = $(BUILD_DIR)/liblua.a

# Modded app paths — auto-detect standard or Creator Studio edition
MODDED_APP_STANDARD = $(HOME)/Applications/SpliceKit/Final Cut Pro.app
MODDED_APP_CREATOR = $(HOME)/Applications/SpliceKit/Final Cut Pro Creator Studio.app
MODDED_APP = $(shell if [ -d "$(MODDED_APP_STANDARD)" ]; then echo "$(MODDED_APP_STANDARD)"; elif [ -d "$(MODDED_APP_CREATOR)" ]; then echo "$(MODDED_APP_CREATOR)"; else echo "$(MODDED_APP_STANDARD)"; fi)
FW_DIR = $(MODDED_APP)/Contents/Frameworks/SpliceKit.framework
ENTITLEMENTS = entitlements.plist

SILENCE_DETECTOR = $(BUILD_DIR)/silence-detector
STRUCTURE_ANALYZER = $(BUILD_DIR)/structure-analyzer
MIXER_APP = $(BUILD_DIR)/SpliceKitMixer
AUDIO_BUS_PROBE_DIR = tools/audio-bus-probe-au
AUDIO_BUS_PROBE_COMPONENT = $(BUILD_DIR)/SpliceKitAudioBusProbe.component
AUDIO_BUS_PROBE_BINARY = $(AUDIO_BUS_PROBE_COMPONENT)/Contents/MacOS/SpliceKitAudioBusProbe
AUDIO_BUS_PROBE_INFO = $(AUDIO_BUS_PROBE_DIR)/Info.plist
AUDIO_BUS_PROBE_SOURCE = $(AUDIO_BUS_PROBE_DIR)/SpliceKitAudioBusProbe.c
AUDIO_BUS_PROBE_INSTALL_DIR = $(HOME)/Library/Audio/Plug-Ins/Components
TOOLS_DIR = $(HOME)/Applications/SpliceKit/tools
PARAKEET_PKG_DIR = patcher/SpliceKitPatcher.app/Contents/Resources/tools/parakeet-transcriber
PARAKEET_RELEASE_BIN = $(PARAKEET_PKG_DIR)/.build/release/parakeet-transcriber
PARAKEET_DEBUG_BIN = $(PARAKEET_PKG_DIR)/.build/debug/parakeet-transcriber

.PHONY: all clean deploy launch tools url-import-tools install-hooks

all: $(OUTPUT)

tools: $(SILENCE_DETECTOR) $(STRUCTURE_ANALYZER) $(MIXER_APP)

audio-bus-probe: $(AUDIO_BUS_PROBE_BINARY)
	@echo "Built: $(AUDIO_BUS_PROBE_COMPONENT)"

$(AUDIO_BUS_PROBE_BINARY): $(AUDIO_BUS_PROBE_SOURCE) $(AUDIO_BUS_PROBE_INFO) | $(BUILD_DIR)
	@mkdir -p "$(AUDIO_BUS_PROBE_COMPONENT)/Contents/MacOS"
	@cp "$(AUDIO_BUS_PROBE_INFO)" "$(AUDIO_BUS_PROBE_COMPONENT)/Contents/Info.plist"
	$(CC) $(ARCHS) $(MIN_VERSION) -std=c11 -O2 -Wall -Wextra -Wno-deprecated-declarations \
		-fvisibility=hidden -dynamiclib \
		-framework AudioToolbox -framework AudioUnit -framework CoreAudio -framework CoreFoundation -framework CoreServices \
		"$(AUDIO_BUS_PROBE_SOURCE)" -o "$(AUDIO_BUS_PROBE_BINARY)"
	@codesign --force --sign - "$(AUDIO_BUS_PROBE_COMPONENT)" >/dev/null

install-audio-bus-probe: audio-bus-probe
	@mkdir -p "$(AUDIO_BUS_PROBE_INSTALL_DIR)"
	@rm -rf "$(AUDIO_BUS_PROBE_INSTALL_DIR)/SpliceKitAudioBusProbe.component"
	@cp -R "$(AUDIO_BUS_PROBE_COMPONENT)" "$(AUDIO_BUS_PROBE_INSTALL_DIR)/SpliceKitAudioBusProbe.component"
	@codesign --force --sign - "$(AUDIO_BUS_PROBE_INSTALL_DIR)/SpliceKitAudioBusProbe.component" >/dev/null
	@killall -9 AudioComponentRegistrar >/dev/null 2>&1 || true
	@echo "Installed: $(AUDIO_BUS_PROBE_INSTALL_DIR)/SpliceKitAudioBusProbe.component"

uninstall-audio-bus-probe:
	@rm -rf "$(AUDIO_BUS_PROBE_INSTALL_DIR)/SpliceKitAudioBusProbe.component"
	@killall -9 AudioComponentRegistrar >/dev/null 2>&1 || true
	@echo "Uninstalled: $(AUDIO_BUS_PROBE_INSTALL_DIR)/SpliceKitAudioBusProbe.component"

url-import-tools:
	@mkdir -p "$(TOOLS_DIR)"
	@YTDLP_PATH="$$(command -v yt-dlp || true)"; \
	if [ -n "$$YTDLP_PATH" ]; then \
		ln -sf "$$YTDLP_PATH" "$(TOOLS_DIR)/yt-dlp"; \
		echo "Linked yt-dlp -> $$YTDLP_PATH"; \
	else \
		echo "yt-dlp not found in PATH. Install with: brew install yt-dlp"; \
	fi
	@FFMPEG_PATH="$$(command -v ffmpeg || true)"; \
	if [ -n "$$FFMPEG_PATH" ]; then \
		ln -sf "$$FFMPEG_PATH" "$(TOOLS_DIR)/ffmpeg"; \
		echo "Linked ffmpeg -> $$FFMPEG_PATH"; \
	else \
		echo "ffmpeg not found in PATH. Install with: brew install ffmpeg"; \
	fi

install-hooks:
	@bash tools/install_git_hooks.sh

$(BUILD_DIR):
	@mkdir -p $(BUILD_DIR)

$(BUILD_DIR)/lua: | $(BUILD_DIR)
	@mkdir -p $(BUILD_DIR)/lua

$(SILENCE_DETECTOR): tools/silence-detector.swift | $(BUILD_DIR)
	swiftc -O -suppress-warnings -o $(SILENCE_DETECTOR) tools/silence-detector.swift
	@echo "Built: $(SILENCE_DETECTOR)"

$(STRUCTURE_ANALYZER): tools/structure-analyzer.swift | $(BUILD_DIR)
	swiftc -O -suppress-warnings -o $(STRUCTURE_ANALYZER) tools/structure-analyzer.swift
	@echo "Built: $(STRUCTURE_ANALYZER)"

MIXER_SOURCES = $(wildcard tools/mixer-app/*.swift)
$(MIXER_APP): $(MIXER_SOURCES) | $(BUILD_DIR)
	swiftc -O -suppress-warnings -parse-as-library -o $(MIXER_APP) $(MIXER_SOURCES)
	@echo "Built: $(MIXER_APP)"

# Lua static library — compiled as C (no -fobjc-arc)
$(BUILD_DIR)/lua/%.o: $(LUA_DIR)/%.c | $(BUILD_DIR)/lua
	$(CC) $(ARCHS) $(MIN_VERSION) -DLUA_USE_MACOSX -O2 -Wall -c $< -o $@

$(LUA_LIB): $(LUA_OBJS) | $(BUILD_DIR)
	libtool -static -o $@ $^
	@echo "Built: $(LUA_LIB)"

$(OUTPUT): $(SOURCES) Sources/SpliceKit.h $(LUA_LIB) | $(BUILD_DIR)
	$(CC) $(ARCHS) $(MIN_VERSION) $(FRAMEWORKS) $(OBJC_FLAGS) $(LINKER_FLAGS) \
		$(INSTALL_NAME) -I Sources -I $(LUA_DIR) \
		$(SOURCES) $(LUA_LIB) -o $(OUTPUT)
	@echo "Built: $(OUTPUT)"
	@file $(OUTPUT)

clean:
	rm -rf $(BUILD_DIR)

deploy: $(OUTPUT) $(SILENCE_DETECTOR) $(STRUCTURE_ANALYZER) $(MIXER_APP)
	@echo "=== Deploying SpliceKit to modded FCP ==="
	@mkdir -p "$(FW_DIR)/Versions/A/Resources"
	cp $(OUTPUT) "$(FW_DIR)/Versions/A/SpliceKit"
	@# Create framework symlinks (must use cd for relative paths)
	@cd "$(FW_DIR)/Versions" && ln -sf A Current
	@cd "$(FW_DIR)" && ln -sf Versions/Current/SpliceKit SpliceKit
	@cd "$(FW_DIR)" && ln -sf Versions/Current/Resources Resources
	@# Create Info.plist if missing
	@test -f "$(FW_DIR)/Versions/A/Resources/Info.plist" || \
		printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.splicekit.SpliceKit</string><key>CFBundleName</key><string>SpliceKit</string><key>CFBundleVersion</key><string>1.0.0</string><key>CFBundlePackageType</key><string>FMWK</string><key>CFBundleExecutable</key><string>SpliceKit</string></dict></plist>' \
		> "$(FW_DIR)/Versions/A/Resources/Info.plist"
	@# Add speech recognition usage description for transcript feature
	@/usr/libexec/PlistBuddy -c "Add :NSSpeechRecognitionUsageDescription string 'SpliceKit uses speech recognition to transcribe timeline audio for text-based editing.'" "$(MODDED_APP)/Contents/Info.plist" 2>/dev/null || true
	@/usr/libexec/PlistBuddy -c "Add :NSCameraUsageDescription string 'SpliceKit LiveCam uses the camera for native webcam recording inside Final Cut Pro.'" "$(MODDED_APP)/Contents/Info.plist" 2>/dev/null || true
	@/usr/libexec/PlistBuddy -c "Add :NSMicrophoneUsageDescription string 'SpliceKit LiveCam uses the microphone for native webcam capture inside Final Cut Pro.'" "$(MODDED_APP)/Contents/Info.plist" 2>/dev/null || true
	@# Deploy tools
	@mkdir -p "$(TOOLS_DIR)"
	@$(MAKE) url-import-tools
	@cp $(SILENCE_DETECTOR) "$(TOOLS_DIR)/silence-detector" 2>/dev/null || true
	@cp $(STRUCTURE_ANALYZER) "$(TOOLS_DIR)/structure-analyzer" 2>/dev/null || true
	@cp $(MIXER_APP) "$(TOOLS_DIR)/SpliceKitMixer" 2>/dev/null || true
	@if [ -f "$(PARAKEET_RELEASE_BIN)" ]; then \
		cp "$(PARAKEET_RELEASE_BIN)" "$(TOOLS_DIR)/parakeet-transcriber"; \
		cp "$(PARAKEET_RELEASE_BIN)" "$(FW_DIR)/Versions/A/Resources/parakeet-transcriber"; \
	elif [ -f "$(PARAKEET_DEBUG_BIN)" ]; then \
		cp "$(PARAKEET_DEBUG_BIN)" "$(TOOLS_DIR)/parakeet-transcriber"; \
		cp "$(PARAKEET_DEBUG_BIN)" "$(FW_DIR)/Versions/A/Resources/parakeet-transcriber"; \
	fi
	@# Create plugins directory
	@mkdir -p "$(HOME)/Library/Application Support/SpliceKit/plugins"
	@# Copy Lua example scripts
	@mkdir -p "$(HOME)/Library/Application Support/SpliceKit/lua/examples"
	@mkdir -p "$(HOME)/Library/Application Support/SpliceKit/lua/auto"
	@mkdir -p "$(HOME)/Library/Application Support/SpliceKit/lua/lib"
	@mkdir -p "$(HOME)/Library/Application Support/SpliceKit/lua/menu"
	@cp -n scripts/lua/examples/*.lua "$(HOME)/Library/Application Support/SpliceKit/lua/examples/" 2>/dev/null || true
	@cp -n scripts/lua/menu/*.lua "$(HOME)/Library/Application Support/SpliceKit/lua/menu/" 2>/dev/null || true
	@cp -n scripts/lua/lib/*.lua "$(HOME)/Library/Application Support/SpliceKit/lua/lib/" 2>/dev/null || true
	@sign_identity=$$(security find-identity -v -p codesigning 2>/dev/null | awk '/"Apple Development:/ { print $$2; exit } /"Developer ID Application:/ && developer == "" { developer = $$2 } /[0-9]+\) [0-9A-F]+ "/ && first == "" { first = $$2 } END { if (developer != "") print developer; else if (first != "") print first }'); \
	if [ -n "$$sign_identity" ]; then \
		echo "Using signing identity: $$sign_identity"; \
	else \
		sign_identity="-"; \
		echo "No local codesigning identity found; falling back to ad-hoc signing"; \
	fi; \
	if ! codesign --force --sign "$$sign_identity" "$(FW_DIR)" || \
	   ! codesign --force --sign "$$sign_identity" --entitlements $(ENTITLEMENTS) "$(MODDED_APP)"; then \
		if [ "$$sign_identity" = "-" ]; then \
			exit 1; \
		fi; \
		echo "Developer signing failed; retrying with ad-hoc signature"; \
		codesign --force --sign - "$(FW_DIR)"; \
		codesign --force --sign - --entitlements $(ENTITLEMENTS) "$(MODDED_APP)"; \
	fi
	@codesign --verify --verbose "$(MODDED_APP)" 2>&1
	@echo "=== Deployed successfully ==="

launch: deploy
	@echo "=== Launching modded FCP with SpliceKit ==="
	DYLD_INSERT_LIBRARIES="$(FW_DIR)/Versions/A/SpliceKit" \
		"$(MODDED_APP)/Contents/MacOS/Final Cut Pro" &
	@echo "FCP launched. Check Console.app for [SpliceKit] messages."
	@echo "Connect: echo '{\"jsonrpc\":\"2.0\",\"method\":\"system.version\",\"id\":1}' | nc -U /tmp/splicekit.sock"
