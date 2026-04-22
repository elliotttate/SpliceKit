CC = clang
ARCHS = -arch arm64 -arch x86_64
MIN_VERSION = -mmacosx-version-min=14.0
FRAMEWORKS = -framework Foundation -framework AppKit -framework AVFoundation -framework CoreServices -framework CoreImage -framework Metal -framework MetalKit -framework QuartzCore -framework Vision
MODULE_CACHE_DIR = $(BUILD_DIR)/ModuleCache
OBJC_FLAGS = -fobjc-arc -fmodules -fmodules-cache-path=$(abspath $(MODULE_CACHE_DIR))
OBJCXX_FLAGS = $(OBJC_FLAGS) -std=c++17
DEBUG_FLAGS = -g
LINKER_FLAGS = -undefined dynamic_lookup -dynamiclib
CPP_LIBS = -lc++
INSTALL_NAME = -install_name @rpath/SpliceKit.framework/Versions/A/SpliceKit
SPLICEKIT_VERSION = $(shell awk -F= '/SPLICEKIT_VERSION/ { gsub(/[ ;]/, "", $$2); print $$2; exit }' patcher/SpliceKit/Configuration/Version.xcconfig)
VERSION_DEFINE = -DSPLICEKIT_VERSION=\"$(SPLICEKIT_VERSION)\"
SENTRY_FRAMEWORK_DIR = patcher/Frameworks
SENTRY_FRAMEWORK = $(SENTRY_FRAMEWORK_DIR)/Sentry.framework
SENTRY_FLAGS = -F $(SENTRY_FRAMEWORK_DIR) -ObjC -framework Sentry
DSYM = $(OUTPUT).dSYM

# Read canonical source list from Sources/SOURCES.txt
SOURCES = $(addprefix Sources/, $(shell grep -v '^\#' Sources/SOURCES.txt | grep -v '^$$'))
OBJC_SOURCES = $(filter %.m,$(SOURCES))
OBJCXX_SOURCES = $(filter %.mm,$(SOURCES))
OBJS = $(patsubst Sources/%.m,$(BUILD_DIR)/obj/%.o,$(OBJC_SOURCES)) \
	$(patsubst Sources/%.mm,$(BUILD_DIR)/obj/%.o,$(OBJCXX_SOURCES))

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
REGISTER_PRO_EXTENSION_APP = $(MODDED_APP)/Contents/Helpers/RegisterProExtension.app
PROAPP_SUPPORT_FRAMEWORK = $(MODDED_APP)/Contents/Frameworks/ProAppSupport.framework

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

BRAW_SOURCE_DIR = Plugins/BRAW/Sources
BRAW_PRIVATE_DIR = $(BRAW_SOURCE_DIR)/Private
BRAW_BUILD_DIR = $(BUILD_DIR)/braw-prototype
BRAW_SDK_FRAMEWORK_DIR = /Applications/Blackmagic RAW/Blackmagic RAW SDK/Mac/Libraries
BRAW_SDK_FRAMEWORK = $(BRAW_SDK_FRAMEWORK_DIR)/BlackmagicRawAPI.framework
BRAW_IMPORT_BUNDLE = $(BRAW_BUILD_DIR)/FormatReaders/SpliceKitBRAWImport.bundle
BRAW_IMPORT_EXEC = $(BRAW_IMPORT_BUNDLE)/Contents/MacOS/SpliceKitBRAWImport
BRAW_IMPORT_INFO = Plugins/BRAW/FormatReaders/SpliceKitBRAWImport.bundle/Contents/Info.plist
BRAW_DECODER_BUNDLE = $(BRAW_BUILD_DIR)/Codecs/SpliceKitBRAWDecoder.bundle
BRAW_DECODER_EXEC = $(BRAW_DECODER_BUNDLE)/Contents/MacOS/SpliceKitBRAWDecoder
BRAW_DECODER_INFO = Plugins/BRAW/Codecs/SpliceKitBRAWDecoder.bundle/Contents/Info.plist
BRAW_COMMON_SOURCES = $(BRAW_SOURCE_DIR)/BRAWCommon.mm
BRAW_IMPORT_SOURCES = $(BRAW_COMMON_SOURCES) $(BRAW_SOURCE_DIR)/BRAWFormatReader.mm
BRAW_DECODER_SOURCES = $(BRAW_COMMON_SOURCES) $(BRAW_SOURCE_DIR)/BRAWVideoDecoder.mm
BRAW_FRAMEWORKS = -framework Foundation -framework CoreFoundation -framework CoreMedia -framework CoreVideo -framework VideoToolbox -framework MediaToolbox -framework Accelerate
BRAW_CFLAGS = $(ARCHS) $(MIN_VERSION) $(OBJCXX_FLAGS) $(DEBUG_FLAGS) -fvisibility=hidden -I $(BRAW_SOURCE_DIR) -I $(BRAW_PRIVATE_DIR)
BRAW_LDFLAGS = -bundle $(CPP_LIBS)
BRAW_RAWPROC_DIR = MediaExtensions/BRAWRAWProcessor
BRAW_RAWPROC_BUNDLE = $(BRAW_BUILD_DIR)/Extensions/SpliceKitBRAWRAWProcessor.appex
BRAW_RAWPROC_EXEC = $(BRAW_RAWPROC_BUNDLE)/Contents/MacOS/SpliceKitBRAWRAWProcessor
BRAW_RAWPROC_INFO = $(BRAW_RAWPROC_DIR)/Info.plist
BRAW_RAWPROC_ENTITLEMENTS = $(BRAW_RAWPROC_DIR)/BRAWRAWProcessor.entitlements
BRAW_RAWPROC_PROFILE = $(BRAW_RAWPROC_DIR)/embedded.provisionprofile
BRAW_RAWPROC_SOURCES = $(BRAW_COMMON_SOURCES) $(wildcard $(BRAW_RAWPROC_DIR)/Sources/*.mm)
BRAW_RAWPROC_FRAMEWORK_DEST = $(BRAW_RAWPROC_BUNDLE)/Contents/Frameworks/BlackmagicRawAPI.framework
BRAW_RAWPROC_SIGN_ID = $(shell security find-identity -v -p codesigning 2>/dev/null | awk '/"Developer ID Application:/ { print $$2; exit }')
BRAW_RAWPROC_FRAMEWORKS = -F "$(BRAW_SDK_FRAMEWORK_DIR)" -framework Foundation -framework CoreFoundation -framework CoreMedia -framework CoreVideo -framework MediaExtension -framework MediaToolbox -framework VideoToolbox -framework BlackmagicRawAPI
BRAW_RAWPROC_MIN_VERSION = -mmacosx-version-min=15.0
BRAW_RAWPROC_CFLAGS = $(ARCHS) $(BRAW_RAWPROC_MIN_VERSION) $(OBJCXX_FLAGS) $(DEBUG_FLAGS) -fvisibility=hidden -fapplication-extension -I $(BRAW_SOURCE_DIR) -I $(BRAW_PRIVATE_DIR)
BRAW_RAWPROC_LDFLAGS = $(CPP_LIBS) -Wl,-rpath,@executable_path/../Frameworks

# --- VP9 codec bundle (Plugins/VP9 → FCP.app/Contents/PlugIns/Codecs) --------
VP9_SOURCE_DIR = Plugins/VP9/Sources
VP9_PRIVATE_DIR = $(VP9_SOURCE_DIR)/Private
VP9_BUILD_DIR = $(BUILD_DIR)/vp9
VP9_DECODER_BUNDLE = $(VP9_BUILD_DIR)/Codecs/SpliceKitVP9Decoder.bundle
VP9_DECODER_EXEC = $(VP9_DECODER_BUNDLE)/Contents/MacOS/SpliceKitVP9Decoder
VP9_DECODER_INFO = Plugins/VP9/Codecs/SpliceKitVP9Decoder.bundle/Contents/Info.plist
VP9_DECODER_SOURCES = $(VP9_SOURCE_DIR)/VP9VideoDecoder.mm
VP9_FRAMEWORKS = -framework Foundation -framework CoreFoundation -framework CoreMedia -framework CoreVideo -framework VideoToolbox
VP9_CFLAGS = $(ARCHS) $(MIN_VERSION) $(OBJCXX_FLAGS) $(DEBUG_FLAGS) -fvisibility=hidden -I $(VP9_SOURCE_DIR) -I $(VP9_PRIVATE_DIR)
VP9_LDFLAGS = -bundle $(CPP_LIBS)

# --- MKV/WebM format reader (Plugins/MKV → FCP.app/Contents/PlugIns/FormatReaders) ---
MKV_SOURCE_DIR = Plugins/MKV/Sources
MKV_PRIVATE_DIR = $(MKV_SOURCE_DIR)/Private
MKV_LIBWEBM_DIR = $(MKV_SOURCE_DIR)/libwebm
MKV_BUILD_DIR = $(BUILD_DIR)/mkv
MKV_IMPORT_BUNDLE = $(MKV_BUILD_DIR)/FormatReaders/SpliceKitMKVImport.bundle
MKV_IMPORT_EXEC = $(MKV_IMPORT_BUNDLE)/Contents/MacOS/SpliceKitMKVImport
MKV_IMPORT_INFO = Plugins/MKV/FormatReaders/SpliceKitMKVImport.bundle/Contents/Info.plist
MKV_IMPORT_SOURCES = $(MKV_SOURCE_DIR)/MKVCommon.mm \
                      $(MKV_SOURCE_DIR)/MKVFormatReader.mm \
                      $(MKV_LIBWEBM_DIR)/mkvparser/mkvparser.cc \
                      $(MKV_LIBWEBM_DIR)/mkvparser/mkvreader.cc
MKV_FRAMEWORKS = -framework Foundation -framework CoreFoundation -framework CoreMedia -framework CoreVideo -framework MediaToolbox -framework AudioToolbox
# libwebm uses its own exceptions/assert flow; keep default C++ settings but
# disable ObjC ARC for the .mm so we can freely mix with C++ heap types.
MKV_CFLAGS = $(ARCHS) $(MIN_VERSION) -fno-objc-arc -fmodules -fmodules-cache-path=$(abspath $(MODULE_CACHE_DIR)) -std=c++17 $(DEBUG_FLAGS) -fvisibility=hidden -Wno-deprecated-declarations -I $(MKV_SOURCE_DIR) -I $(MKV_PRIVATE_DIR) -I $(MKV_LIBWEBM_DIR)
MKV_LDFLAGS = -bundle $(CPP_LIBS)

.PHONY: all clean deploy launch tools url-import-tools audio-bus-probe install-audio-bus-probe uninstall-audio-bus-probe symbols braw-prototype braw-raw-processor vp9-prototype mkv-prototype mcp-setup mcp-doctor

all: $(OUTPUT)

symbols: $(DSYM)

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

# ---------------------------------------------------------------------------
# MCP server setup (Python venv + dependencies)
# ---------------------------------------------------------------------------
MCP_VENV ?= $(HOME)/.venvs/splicekit-mcp
MCP_PYTHON = $(MCP_VENV)/bin/python
MCP_REQUIREMENTS = mcp/requirements.txt

mcp-setup:
	@PY="$$(command -v python3.13 || command -v python3.12 || command -v python3.11 || command -v python3)"; \
	if [ -z "$$PY" ]; then echo "[mcp-setup] python3 not found in PATH"; exit 1; fi; \
	echo "[mcp-setup] Using interpreter: $$PY ($$($$PY --version 2>&1))"; \
	if [ ! -x "$(MCP_PYTHON)" ]; then \
		echo "[mcp-setup] Creating venv at $(MCP_VENV)"; \
		"$$PY" -m venv "$(MCP_VENV)"; \
	else \
		echo "[mcp-setup] Reusing venv at $(MCP_VENV)"; \
	fi
	@"$(MCP_PYTHON)" -m pip install --upgrade --quiet pip
	@"$(MCP_PYTHON)" -m pip install --upgrade --quiet -r $(MCP_REQUIREMENTS)
	@echo "[mcp-setup] Installed:"; "$(MCP_PYTHON)" -m pip show mcp | awk '/^(Name|Version|Location):/'
	@echo "[mcp-setup] Done. Point your MCP client `command` at: $(MCP_PYTHON)"

mcp-doctor:
	@echo "== SpliceKit MCP doctor =="
	@if [ -x "$(MCP_PYTHON)" ]; then \
		echo "[ok] venv interpreter:    $(MCP_PYTHON) ($$($(MCP_PYTHON) --version 2>&1))"; \
	else \
		echo "[FAIL] venv interpreter missing at $(MCP_PYTHON) — run 'make mcp-setup'"; \
	fi
	@if [ -x "$(MCP_PYTHON)" ] && "$(MCP_PYTHON)" -c "import mcp.server.fastmcp" >/dev/null 2>&1; then \
		echo "[ok] mcp package:         $$($(MCP_PYTHON) -m pip show mcp | awk '/^Version:/{print $$2}')"; \
	else \
		echo "[FAIL] mcp package not importable in venv — run 'make mcp-setup'"; \
	fi
	@if [ -f .mcp.json ]; then \
		CMD=$$(/usr/bin/python3 -c "import json; print(json.load(open('.mcp.json'))['mcpServers']['splicekit']['command'])" 2>/dev/null); \
		if [ "$$CMD" = "$(MCP_PYTHON)" ]; then \
			echo "[ok] .mcp.json command:   $$CMD"; \
		else \
			echo "[warn] .mcp.json command: $$CMD (expected $(MCP_PYTHON))"; \
		fi; \
	else \
		echo "[warn] .mcp.json not found in repo root"; \
	fi
	@if /usr/sbin/lsof -nP -iTCP:9876 -sTCP:LISTEN 2>/dev/null | grep -q LISTEN; then \
		echo "[ok] FCP bridge listening on 127.0.0.1:9876"; \
	else \
		echo "[warn] No process listening on :9876 — launch the modded Final Cut Pro"; \
	fi

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
	@FFPROBE_PATH="$$(command -v ffprobe || true)"; \
	if [ -n "$$FFPROBE_PATH" ]; then \
		ln -sf "$$FFPROBE_PATH" "$(TOOLS_DIR)/ffprobe"; \
		echo "Linked ffprobe -> $$FFPROBE_PATH"; \
	else \
		echo "ffprobe not found in PATH. Install with: brew install ffmpeg"; \
	fi

$(BUILD_DIR):
	@mkdir -p $(BUILD_DIR)

$(SENTRY_FRAMEWORK): Scripts/ensure_sentry_framework.sh
	@bash Scripts/ensure_sentry_framework.sh

$(BUILD_DIR)/lua: | $(BUILD_DIR)
	@mkdir -p $(BUILD_DIR)/lua

$(BUILD_DIR)/obj: | $(BUILD_DIR)
	@mkdir -p $(BUILD_DIR)/obj

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

$(BUILD_DIR)/obj/%.o: Sources/%.m Sources/SpliceKit.h $(SENTRY_FRAMEWORK) | $(BUILD_DIR)/obj
	$(CC) $(ARCHS) $(MIN_VERSION) $(OBJC_FLAGS) $(DEBUG_FLAGS) $(VERSION_DEFINE) \
		-I Sources -I $(LUA_DIR) -F $(SENTRY_FRAMEWORK_DIR) -c $< -o $@

$(BUILD_DIR)/obj/%.o: Sources/%.mm Sources/SpliceKit.h $(SENTRY_FRAMEWORK) | $(BUILD_DIR)/obj
	$(CC) $(ARCHS) $(MIN_VERSION) $(OBJCXX_FLAGS) $(DEBUG_FLAGS) $(VERSION_DEFINE) \
		-I Sources -I $(LUA_DIR) -F $(SENTRY_FRAMEWORK_DIR) -c $< -o $@

$(OUTPUT): $(OBJS) $(LUA_LIB) $(SENTRY_FRAMEWORK) | $(BUILD_DIR)
	$(CC) $(ARCHS) $(MIN_VERSION) $(FRAMEWORKS) $(LINKER_FLAGS) \
		$(INSTALL_NAME) $(OBJS) $(LUA_LIB) $(SENTRY_FLAGS) $(CPP_LIBS) -o $(OUTPUT)
	@# -undefined dynamic_lookup lets calls into FCP internals resolve at load time,
	@# but it also silently permits unresolved SpliceKit_* symbols (missing .m files
	@# not listed in SOURCES.txt). Those become NULL in the host and crash FCP with
	@# pc=0 during init. Fail the build if any SpliceKit_ symbol is undefined.
	@undef="$$(nm -u $(OUTPUT) | awk '/^_SpliceKit_/ {print $$NF}' | sort -u)"; \
	if [ -n "$$undef" ]; then \
		echo "ERROR: undefined SpliceKit_* symbols in $(OUTPUT):" >&2; \
		echo "$$undef" | sed 's/^/  /' >&2; \
		echo "Add the missing .m file(s) to Sources/SOURCES.txt." >&2; \
		rm -f $(OUTPUT); \
		exit 1; \
	fi
	@echo "Built: $(OUTPUT)"
	@file $(OUTPUT)

$(DSYM): $(OUTPUT)
	dsymutil "$(OUTPUT)" -o "$(DSYM)"
	@echo "Built: $(DSYM)"

clean:
	rm -rf $(BUILD_DIR)

$(BRAW_BUILD_DIR): | $(BUILD_DIR)
	@mkdir -p "$(BRAW_BUILD_DIR)"

$(BRAW_IMPORT_EXEC): $(BRAW_IMPORT_SOURCES) $(BRAW_IMPORT_INFO) | $(BRAW_BUILD_DIR)
	@mkdir -p "$(BRAW_IMPORT_BUNDLE)/Contents/MacOS"
	@cp "$(BRAW_IMPORT_INFO)" "$(BRAW_IMPORT_BUNDLE)/Contents/Info.plist"
	$(CC) $(BRAW_CFLAGS) $(BRAW_FRAMEWORKS) $(BRAW_IMPORT_SOURCES) $(BRAW_LDFLAGS) -o "$(BRAW_IMPORT_EXEC)"
	@codesign --force --sign - "$(BRAW_IMPORT_BUNDLE)" >/dev/null
	@echo "Built: $(BRAW_IMPORT_BUNDLE)"

$(BRAW_DECODER_EXEC): $(BRAW_DECODER_SOURCES) $(BRAW_DECODER_INFO) | $(BRAW_BUILD_DIR)
	@mkdir -p "$(BRAW_DECODER_BUNDLE)/Contents/MacOS"
	@cp "$(BRAW_DECODER_INFO)" "$(BRAW_DECODER_BUNDLE)/Contents/Info.plist"
	$(CC) $(BRAW_CFLAGS) $(BRAW_FRAMEWORKS) $(BRAW_DECODER_SOURCES) $(BRAW_LDFLAGS) -o "$(BRAW_DECODER_EXEC)"
	@codesign --force --sign - "$(BRAW_DECODER_BUNDLE)" >/dev/null
	@echo "Built: $(BRAW_DECODER_BUNDLE)"

$(VP9_DECODER_EXEC): $(VP9_DECODER_SOURCES) $(VP9_DECODER_INFO) | $(BUILD_DIR)
	@mkdir -p "$(VP9_DECODER_BUNDLE)/Contents/MacOS"
	@cp "$(VP9_DECODER_INFO)" "$(VP9_DECODER_BUNDLE)/Contents/Info.plist"
	$(CC) $(VP9_CFLAGS) $(VP9_FRAMEWORKS) $(VP9_DECODER_SOURCES) $(VP9_LDFLAGS) -o "$(VP9_DECODER_EXEC)"
	@codesign --force --sign - "$(VP9_DECODER_BUNDLE)" >/dev/null
	@echo "Built: $(VP9_DECODER_BUNDLE)"

vp9-prototype: $(VP9_DECODER_EXEC)
	@echo "Staged: $(VP9_BUILD_DIR)"

$(MKV_IMPORT_EXEC): $(MKV_IMPORT_SOURCES) $(MKV_IMPORT_INFO) | $(BUILD_DIR)
	@mkdir -p "$(MKV_IMPORT_BUNDLE)/Contents/MacOS"
	@cp "$(MKV_IMPORT_INFO)" "$(MKV_IMPORT_BUNDLE)/Contents/Info.plist"
	$(CC) $(MKV_CFLAGS) $(MKV_FRAMEWORKS) $(MKV_IMPORT_SOURCES) $(MKV_LDFLAGS) -o "$(MKV_IMPORT_EXEC)"
	@codesign --force --sign - "$(MKV_IMPORT_BUNDLE)" >/dev/null
	@echo "Built: $(MKV_IMPORT_BUNDLE)"

mkv-prototype: $(MKV_IMPORT_EXEC)
	@echo "Staged: $(MKV_BUILD_DIR)"

$(BRAW_RAWPROC_EXEC): $(BRAW_RAWPROC_SOURCES) $(BRAW_RAWPROC_INFO) $(BRAW_RAWPROC_ENTITLEMENTS) $(BRAW_RAWPROC_PROFILE) | $(BRAW_BUILD_DIR)
	@mkdir -p "$(BRAW_RAWPROC_BUNDLE)/Contents/MacOS"
	@test -d "$(BRAW_SDK_FRAMEWORK)" || { echo "Missing BRAW SDK framework at $(BRAW_SDK_FRAMEWORK)"; exit 1; }
	@cp "$(BRAW_RAWPROC_INFO)" "$(BRAW_RAWPROC_BUNDLE)/Contents/Info.plist"
	@cp "$(BRAW_RAWPROC_PROFILE)" "$(BRAW_RAWPROC_BUNDLE)/Contents/embedded.provisionprofile"
	$(CC) $(BRAW_RAWPROC_CFLAGS) $(BRAW_RAWPROC_FRAMEWORKS) $(BRAW_RAWPROC_SOURCES) $(BRAW_RAWPROC_LDFLAGS) -o "$(BRAW_RAWPROC_EXEC)"
	@mkdir -p "$(BRAW_RAWPROC_BUNDLE)/Contents/Frameworks"
	@rm -rf "$(BRAW_RAWPROC_FRAMEWORK_DEST)"
	@cp -R "$(BRAW_SDK_FRAMEWORK)" "$(BRAW_RAWPROC_FRAMEWORK_DEST)"
	@sign_id="$(BRAW_RAWPROC_SIGN_ID)"; \
	if [ -n "$$sign_id" ]; then \
		echo "Signing appex with Developer ID: $$sign_id"; \
		codesign --force --sign "$$sign_id" --options runtime "$(BRAW_RAWPROC_FRAMEWORK_DEST)" >/dev/null; \
		codesign --force --sign "$$sign_id" --options runtime --entitlements "$(BRAW_RAWPROC_ENTITLEMENTS)" "$(BRAW_RAWPROC_BUNDLE)" >/dev/null; \
	else \
		echo "Warning: no Developer ID Application identity; ad-hoc signing (extension will NOT load pluginkit-registered)"; \
		codesign --force --sign - "$(BRAW_RAWPROC_FRAMEWORK_DEST)" >/dev/null; \
		if ! codesign --force --sign - --entitlements "$(BRAW_RAWPROC_ENTITLEMENTS)" "$(BRAW_RAWPROC_BUNDLE)" >/dev/null 2>&1; then \
			echo "Warning: ad-hoc signing with RAW processor entitlements failed; retrying without entitlements"; \
			codesign --force --sign - "$(BRAW_RAWPROC_BUNDLE)" >/dev/null; \
		fi; \
	fi
	@echo "Built: $(BRAW_RAWPROC_BUNDLE)"

BRAW_CLI_SRC = tools/braw-decoder/braw-decoder.mm
BRAW_CLI_BIN = $(BUILD_DIR)/braw-decoder
BRAW_CLI_FRAMEWORK_DIR = /Applications/Blackmagic RAW/Blackmagic RAW SDK/Mac/Libraries

# Subprocess CLI that hosts the BRAW SDK in its own process. FCP's SpliceKit
# framework talks to it over pipes; see tools/braw-decoder/braw-decoder.mm for
# the wire protocol.
$(BRAW_CLI_BIN): $(BRAW_CLI_SRC) | $(BUILD_DIR)
	$(CC) -arch arm64 -arch x86_64 $(MIN_VERSION) $(OBJCXX_FLAGS) -O2 \
		-F "$(BRAW_CLI_FRAMEWORK_DIR)" \
		-framework Foundation -framework CoreFoundation -framework BlackmagicRawAPI \
		-Wl,-rpath,"$(BRAW_CLI_FRAMEWORK_DIR)" \
		$(BRAW_CLI_SRC) $(CPP_LIBS) -o "$(BRAW_CLI_BIN)"
	@codesign --force --sign - "$(BRAW_CLI_BIN)" >/dev/null
	@echo "Built: $(BRAW_CLI_BIN)"

# Enable the BRAW prototype bundles by default during deploy; override with
# ENABLE_BRAW_PROTOTYPE=0 to skip copying them into the modded FCP app.
ENABLE_BRAW_PROTOTYPE ?= 1
ENABLE_BRAW_RAW_PROCESSOR ?= 0

braw-prototype: $(BRAW_IMPORT_EXEC) $(BRAW_DECODER_EXEC) $(BRAW_CLI_BIN)
	@echo "Staged: $(BRAW_BUILD_DIR)"

braw-raw-processor: $(BRAW_RAWPROC_EXEC)
	@echo "Staged: $(BRAW_RAWPROC_BUNDLE)"

deploy: $(OUTPUT) $(SILENCE_DETECTOR) $(STRUCTURE_ANALYZER) $(MIXER_APP) braw-prototype vp9-prototype mkv-prototype
	@echo "=== Deploying SpliceKit to modded FCP ==="
		@rm -rf "$(FW_DIR)"
		@mkdir -p "$(FW_DIR)/Versions/A/Resources"
	cp $(OUTPUT) "$(FW_DIR)/Versions/A/SpliceKit"
	@if [ -f "$(HOME)/Library/Application Support/SpliceKit/SpliceKitSentryConfig.plist" ]; then \
		cp "$(HOME)/Library/Application Support/SpliceKit/SpliceKitSentryConfig.plist" "$(FW_DIR)/Versions/A/Resources/SpliceKitSentryConfig.plist"; \
		echo "Copied runtime Sentry config into framework resources"; \
	fi
		@# Create framework symlinks. Use -n so repeated deploys replace the
		@# symlink itself instead of following it into Versions/A.
		@cd "$(FW_DIR)/Versions" && ln -sfn A Current
		@cd "$(FW_DIR)" && ln -sfn Versions/Current/SpliceKit SpliceKit
		@cd "$(FW_DIR)" && ln -sfn Versions/Current/Resources Resources
	@# Create Info.plist if missing
	@test -f "$(FW_DIR)/Versions/A/Resources/Info.plist" || \
		printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.splicekit.SpliceKit</string><key>CFBundleName</key><string>SpliceKit</string><key>CFBundleVersion</key><string>1.0.0</string><key>CFBundlePackageType</key><string>FMWK</string><key>CFBundleExecutable</key><string>SpliceKit</string></dict></plist>' \
		> "$(FW_DIR)/Versions/A/Resources/Info.plist"
	@# Add speech recognition usage description for transcript feature
	@/usr/libexec/PlistBuddy -c "Add :NSSpeechRecognitionUsageDescription string 'SpliceKit uses speech recognition to transcribe timeline audio for text-based editing.'" "$(MODDED_APP)/Contents/Info.plist" 2>/dev/null || true
	@/usr/libexec/PlistBuddy -c "Add :NSCameraUsageDescription string 'SpliceKit LiveCam uses the camera for native webcam recording inside Final Cut Pro.'" "$(MODDED_APP)/Contents/Info.plist" 2>/dev/null || true
	@/usr/libexec/PlistBuddy -c "Add :NSMicrophoneUsageDescription string 'SpliceKit LiveCam uses the microphone for native webcam capture inside Final Cut Pro.'" "$(MODDED_APP)/Contents/Info.plist" 2>/dev/null || true
	@# Local network + Bonjour for Vision Pro preview (required on macOS 15+).
	@# `_ivtpreviewclient._tcp` is Apple's service type for Vision Pro remote preview peers.
	@/usr/libexec/PlistBuddy -c "Add :NSLocalNetworkUsageDescription string 'SpliceKit discovers nearby Vision Pro headsets on your local network to send immersive preview video.'" "$(MODDED_APP)/Contents/Info.plist" 2>/dev/null || true
	@/usr/libexec/PlistBuddy -c "Add :NSBonjourServices array" "$(MODDED_APP)/Contents/Info.plist" 2>/dev/null || true
	@/usr/libexec/PlistBuddy -c "Add :NSBonjourServices: string '_ivtpreviewclient._tcp'" "$(MODDED_APP)/Contents/Info.plist" 2>/dev/null || true
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
	@cp -n Scripts/lua/examples/*.lua "$(HOME)/Library/Application Support/SpliceKit/lua/examples/" 2>/dev/null || true
	@cp -n Scripts/lua/menu/*.lua "$(HOME)/Library/Application Support/SpliceKit/lua/menu/" 2>/dev/null || true
	@cp -n Scripts/lua/lib/*.lua "$(HOME)/Library/Application Support/SpliceKit/lua/lib/" 2>/dev/null || true
	@if [ "$(ENABLE_BRAW_PROTOTYPE)" = "1" ]; then \
		$(MAKE) braw-prototype; \
		mkdir -p "$(MODDED_APP)/Contents/PlugIns/Codecs"; \
		mkdir -p "$(MODDED_APP)/Contents/PlugIns/FormatReaders"; \
		rm -rf "$(MODDED_APP)/Contents/PlugIns/Codecs/SpliceKitBRAWDecoder.bundle"; \
		rm -rf "$(MODDED_APP)/Contents/PlugIns/FormatReaders/SpliceKitBRAWImport.bundle"; \
		cp -R "$(BUILD_DIR)/braw-prototype/Codecs/SpliceKitBRAWDecoder.bundle" "$(MODDED_APP)/Contents/PlugIns/Codecs/SpliceKitBRAWDecoder.bundle"; \
		cp -R "$(BUILD_DIR)/braw-prototype/FormatReaders/SpliceKitBRAWImport.bundle" "$(MODDED_APP)/Contents/PlugIns/FormatReaders/SpliceKitBRAWImport.bundle"; \
		echo "Opt-in BRAW prototype bundles copied into FCP.app/Contents/PlugIns"; \
	fi
	@$(MAKE) vp9-prototype
	@mkdir -p "$(MODDED_APP)/Contents/PlugIns/Codecs"
	@rm -rf "$(MODDED_APP)/Contents/PlugIns/Codecs/SpliceKitVP9Decoder.bundle"
	@cp -R "$(VP9_DECODER_BUNDLE)" "$(MODDED_APP)/Contents/PlugIns/Codecs/SpliceKitVP9Decoder.bundle"
	@echo "VP9 decoder bundle copied into FCP.app/Contents/PlugIns"
	@$(MAKE) mkv-prototype
	@mkdir -p "$(MODDED_APP)/Contents/PlugIns/FormatReaders"
	@rm -rf "$(MODDED_APP)/Contents/PlugIns/FormatReaders/SpliceKitMKVImport.bundle"
	@cp -R "$(MKV_IMPORT_BUNDLE)" "$(MODDED_APP)/Contents/PlugIns/FormatReaders/SpliceKitMKVImport.bundle"
	@echo "MKV/WebM format reader copied into FCP.app/Contents/PlugIns"
	@if [ "$(ENABLE_BRAW_RAW_PROCESSOR)" = "1" ]; then \
		$(MAKE) braw-raw-processor; \
		mkdir -p "$(MODDED_APP)/Contents/Extensions"; \
		rm -rf "$(MODDED_APP)/Contents/Extensions/SpliceKitBRAWRAWProcessor.appex"; \
		cp -R "$(BUILD_DIR)/braw-prototype/Extensions/SpliceKitBRAWRAWProcessor.appex" "$(MODDED_APP)/Contents/Extensions/SpliceKitBRAWRAWProcessor.appex"; \
		echo "Opt-in BRAW RAW processor copied into FCP.app/Contents/Extensions"; \
	fi
	@sign_identity=$$(security find-identity -v -p codesigning 2>/dev/null | awk '/"Apple Development:/ { print $$2; exit } /"Developer ID Application:/ && developer == "" { developer = $$2 } /[0-9]+\) [0-9A-F]+ "/ && first == "" { first = $$2 } END { if (developer != "") print developer; else if (first != "") print first }'); \
	if [ -n "$$sign_identity" ]; then \
		echo "Using signing identity: $$sign_identity"; \
	else \
		sign_identity="-"; \
		echo "No local codesigning identity found; falling back to ad-hoc signing"; \
	fi; \
	if [ -d "$(MODDED_APP)/Contents/PlugIns/FormatReaders/SpliceKitBRAWImport.bundle" ]; then \
		codesign --force --sign "$$sign_identity" "$(MODDED_APP)/Contents/PlugIns/FormatReaders/SpliceKitBRAWImport.bundle"; \
	fi; \
	if [ -d "$(MODDED_APP)/Contents/PlugIns/Codecs/SpliceKitBRAWDecoder.bundle" ]; then \
		codesign --force --sign "$$sign_identity" "$(MODDED_APP)/Contents/PlugIns/Codecs/SpliceKitBRAWDecoder.bundle"; \
	fi; \
	if [ -d "$(MODDED_APP)/Contents/PlugIns/Codecs/SpliceKitVP9Decoder.bundle" ]; then \
		codesign --force --sign "$$sign_identity" "$(MODDED_APP)/Contents/PlugIns/Codecs/SpliceKitVP9Decoder.bundle"; \
	fi; \
	if [ -d "$(MODDED_APP)/Contents/Extensions/SpliceKitBRAWRAWProcessor.appex" ]; then \
		appex_sign_id="$(BRAW_RAWPROC_SIGN_ID)"; \
		if [ -n "$$appex_sign_id" ]; then \
			echo "Signing deployed appex with Developer ID: $$appex_sign_id"; \
			codesign --force --sign "$$appex_sign_id" --options runtime --entitlements "$(BRAW_RAWPROC_ENTITLEMENTS)" "$(MODDED_APP)/Contents/Extensions/SpliceKitBRAWRAWProcessor.appex"; \
		else \
			codesign --force --sign "$$sign_identity" --entitlements "$(BRAW_RAWPROC_ENTITLEMENTS)" "$(MODDED_APP)/Contents/Extensions/SpliceKitBRAWRAWProcessor.appex"; \
		fi; \
	fi; \
	if [ -d "$(PROAPP_SUPPORT_FRAMEWORK)" ]; then \
		codesign --force --sign "$$sign_identity" "$(PROAPP_SUPPORT_FRAMEWORK)"; \
	fi; \
	if [ -d "$(REGISTER_PRO_EXTENSION_APP)" ]; then \
		codesign --force --sign "$$sign_identity" --entitlements $(ENTITLEMENTS) "$(REGISTER_PRO_EXTENSION_APP)"; \
	fi; \
	if ! codesign --force --options runtime --sign "$$sign_identity" "$(FW_DIR)" || \
	   ! codesign --force --options runtime --sign "$$sign_identity" --entitlements $(ENTITLEMENTS) "$(MODDED_APP)"; then \
		if [ "$$sign_identity" = "-" ]; then \
			exit 1; \
		fi; \
		echo "Developer signing failed; retrying with ad-hoc signature"; \
		if [ -d "$(MODDED_APP)/Contents/PlugIns/FormatReaders/SpliceKitBRAWImport.bundle" ]; then \
			codesign --force --sign - "$(MODDED_APP)/Contents/PlugIns/FormatReaders/SpliceKitBRAWImport.bundle"; \
		fi; \
		if [ -d "$(MODDED_APP)/Contents/PlugIns/Codecs/SpliceKitBRAWDecoder.bundle" ]; then \
			codesign --force --sign - "$(MODDED_APP)/Contents/PlugIns/Codecs/SpliceKitBRAWDecoder.bundle"; \
		fi; \
		if [ -d "$(MODDED_APP)/Contents/PlugIns/Codecs/SpliceKitVP9Decoder.bundle" ]; then \
			codesign --force --sign - "$(MODDED_APP)/Contents/PlugIns/Codecs/SpliceKitVP9Decoder.bundle"; \
		fi; \
		if [ -d "$(MODDED_APP)/Contents/Extensions/SpliceKitBRAWRAWProcessor.appex" ]; then \
			codesign --force --sign - --entitlements "$(BRAW_RAWPROC_ENTITLEMENTS)" "$(MODDED_APP)/Contents/Extensions/SpliceKitBRAWRAWProcessor.appex" || \
			codesign --force --sign - "$(MODDED_APP)/Contents/Extensions/SpliceKitBRAWRAWProcessor.appex"; \
		fi; \
		if [ -d "$(PROAPP_SUPPORT_FRAMEWORK)" ]; then \
			codesign --force --sign - "$(PROAPP_SUPPORT_FRAMEWORK)"; \
		fi; \
		if [ -d "$(REGISTER_PRO_EXTENSION_APP)" ]; then \
			codesign --force --sign - --entitlements $(ENTITLEMENTS) "$(REGISTER_PRO_EXTENSION_APP)"; \
		fi; \
		codesign --force --options runtime --sign - "$(FW_DIR)"; \
		codesign --force --options runtime --sign - --entitlements $(ENTITLEMENTS) "$(MODDED_APP)"; \
	fi
	@codesign --verify --verbose "$(MODDED_APP)" 2>&1
	@echo "=== Deployed successfully ==="

launch: deploy
	@echo "=== Launching modded FCP with SpliceKit ==="
	DYLD_INSERT_LIBRARIES="$(FW_DIR)/Versions/A/SpliceKit" \
		"$(MODDED_APP)/Contents/MacOS/Final Cut Pro" &
	@echo "FCP launched. Check Console.app for [SpliceKit] messages."
	@echo "Connect: echo '{\"jsonrpc\":\"2.0\",\"method\":\"system.version\",\"id\":1}' | nc -U /tmp/splicekit.sock"
