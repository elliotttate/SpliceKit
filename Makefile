CC = clang
ARCHS = -arch arm64 -arch x86_64
MIN_VERSION = -mmacosx-version-min=14.0
FRAMEWORKS = -framework Foundation -framework AppKit -framework AVFoundation -framework CoreServices
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
          Sources/SpliceKitCaptionPanel.m \
          Sources/SpliceKitCommandPalette.m \
          Sources/SpliceKitDebugUI.m \
          Sources/SpliceKitStructureBlocks.m \
          Sources/SpliceKitSectionsBar.m \
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
TOOLS_DIR = $(HOME)/Applications/SpliceKit/tools
PARAKEET_PKG_DIR = patcher/SpliceKitPatcher.app/Contents/Resources/tools/parakeet-transcriber
PARAKEET_RELEASE_BIN = $(PARAKEET_PKG_DIR)/.build/release/parakeet-transcriber
PARAKEET_DEBUG_BIN = $(PARAKEET_PKG_DIR)/.build/debug/parakeet-transcriber

.PHONY: all clean deploy launch tools url-import-tools

all: $(OUTPUT)

tools: $(SILENCE_DETECTOR) $(STRUCTURE_ANALYZER)

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

deploy: $(OUTPUT) $(SILENCE_DETECTOR) $(STRUCTURE_ANALYZER)
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
	@# Deploy tools
	@mkdir -p "$(TOOLS_DIR)"
	@$(MAKE) url-import-tools
	@cp $(SILENCE_DETECTOR) "$(TOOLS_DIR)/silence-detector" 2>/dev/null || true
	@cp $(STRUCTURE_ANALYZER) "$(TOOLS_DIR)/structure-analyzer" 2>/dev/null || true
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
