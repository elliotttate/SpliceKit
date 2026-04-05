#!/bin/bash
#
# SpliceKit Patcher
# Patches Final Cut Pro to load the SpliceKit dylib for programmatic control.
#
# Usage:
#   ./patch_fcp.sh                     # Patch using defaults
#   ./patch_fcp.sh --dest ~/Desktop    # Custom destination
#   ./patch_fcp.sh --uninstall         # Remove the modded copy
#
set -euo pipefail

# ============================================================
# Configuration
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# Auto-detect FCP edition: prefer standard, fall back to Creator Studio
CREATOR_STUDIO_APP="/Applications/Final Cut Pro Creator Studio.app"
STANDARD_APP="/Applications/Final Cut Pro.app"
if [[ -z "${SOURCE_APP:-}" ]]; then
    if [[ -d "$STANDARD_APP" ]]; then
        SOURCE_APP="$STANDARD_APP"
    elif [[ -d "$CREATOR_STUDIO_APP" ]]; then
        SOURCE_APP="$CREATOR_STUDIO_APP"
    else
        SOURCE_APP="$STANDARD_APP"  # will fail with a clear error later
    fi
fi
DEFAULT_DEST="$HOME/Library/Application Support/SpliceKit"
DEST_DIR="${DEST_DIR:-$DEFAULT_DEST}"
APP_NAME="$(basename "$SOURCE_APP")"
BRIDGE_PORT=9876
VERSION="2.0.0"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()   { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
err()   { echo -e "${RED}[X]${NC} $*"; }
info()  { echo -e "${BLUE}[i]${NC} $*"; }
step()  { echo -e "\n${CYAN}${BOLD}=== $* ===${NC}"; }

# ============================================================
# Help
# ============================================================
usage() {
    cat << 'EOF'

  SpliceKit Patcher v2.0.0

  Creates a modded copy of Final Cut Pro with SpliceKit injected
  for direct programmatic control via JSON-RPC and MCP.

  Usage:
    ./patch_fcp.sh [options]

  Options:
    --dest DIR       Destination directory (default: ~/Desktop/FinalCutPro_Modded)
    --source APP     Source FCP app (default: /Applications/Final Cut Pro.app)
    --no-copy        Skip copying (use existing modded copy)
    --rebuild        Rebuild dylib only and redeploy
    --uninstall      Remove the modded copy
    --help           Show this help

  What it does:
    1. Copies Final Cut Pro to a writable location
    2. Builds the SpliceKit dylib from source
    3. Injects it into the FCP binary (LC_LOAD_DYLIB)
    4. Re-signs everything with custom entitlements (no sandbox)
    5. Patches CloudContent/ImagePlayground crash points
    6. Sets up the MCP server config

  After patching:
    - Launch: ~/Desktop/FinalCutPro_Modded/Final Cut Pro.app
    - Connect: 127.0.0.1:9876 (JSON-RPC)
    - MCP config: .mcp.json is created in current directory

  Requirements:
    - macOS 14+
    - Xcode Command Line Tools
    - Final Cut Pro installed
    - ~7 GB free disk space

EOF
    exit 0
}

# ============================================================
# Parse arguments
# ============================================================
NO_COPY=false
REBUILD_ONLY=false
UNINSTALL=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --dest)     DEST_DIR="$2"; shift 2 ;;
        --source)   SOURCE_APP="$2"; shift 2 ;;
        --no-copy)  NO_COPY=true; shift ;;
        --rebuild)  REBUILD_ONLY=true; shift ;;
        --uninstall) UNINSTALL=true; shift ;;
        --help|-h)  usage ;;
        *)          err "Unknown option: $1"; usage ;;
    esac
done

MODDED_APP="$DEST_DIR/$APP_NAME"

# ============================================================
# Uninstall
# ============================================================
if $UNINSTALL; then
    step "Uninstalling SpliceKit"
    if [[ -d "$DEST_DIR" ]]; then
        info "Removing $DEST_DIR"
        rm -rf "$DEST_DIR"
        log "Modded FCP removed"
    else
        warn "Nothing to uninstall at $DEST_DIR"
    fi
    exit 0
fi

# ============================================================
# Banner
# ============================================================
echo -e "${BOLD}"
cat << 'BANNER'

  ╔═══════════════════════════════════════════════╗
  ║         SpliceKit Patcher v2.0.0              ║
  ║  Direct programmatic control of Final Cut Pro ║
  ╚═══════════════════════════════════════════════╝

BANNER
echo -e "${NC}"

# ============================================================
# Prerequisites
# ============================================================
step "Checking prerequisites"

# Xcode tools
if ! xcode-select -p &>/dev/null; then
    err "Xcode Command Line Tools not installed"
    info "Install with: xcode-select --install"
    exit 1
fi
log "Xcode Command Line Tools: $(xcode-select -p)"

# codesign
if ! command -v codesign &>/dev/null; then
    err "codesign not found"; exit 1
fi
log "codesign: $(which codesign)"

# clang
if ! command -v clang &>/dev/null; then
    err "clang not found"; exit 1
fi
log "clang: $(which clang)"

# Source app
if [[ ! -d "$SOURCE_APP" ]]; then
    err "Final Cut Pro not found at: $SOURCE_APP"
    info "Install from the Mac App Store or specify --source"
    exit 1
fi
FCP_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$SOURCE_APP/Contents/Info.plist" 2>/dev/null || echo "unknown")
log "Final Cut Pro: v$FCP_VERSION at $SOURCE_APP"

# Disk space
AVAIL_GB=$(df -g "$HOME" | tail -1 | awk '{print $4}')
if [[ $AVAIL_GB -lt 8 ]]; then
    warn "Low disk space: ${AVAIL_GB}GB available (need ~7GB)"
    read -p "Continue anyway? [y/N] " -n 1 -r
    echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
fi
log "Disk space: ${AVAIL_GB}GB available"

# ============================================================
# Step 1: Copy FCP
# ============================================================
if ! $NO_COPY && ! $REBUILD_ONLY; then
    step "Step 1: Copying Final Cut Pro"

    if [[ -d "$MODDED_APP" ]]; then
        warn "Modded copy already exists at $MODDED_APP"
        read -p "Overwrite? [y/N] " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            rm -rf "$MODDED_APP"
        else
            NO_COPY=true
            log "Using existing copy"
        fi
    fi

    if ! $NO_COPY; then
        mkdir -p "$DEST_DIR"
        info "Copying $(du -sh "$SOURCE_APP" | cut -f1) ... (this takes a minute)"
        cp -R "$SOURCE_APP" "$MODDED_APP"
        log "Copied to $MODDED_APP"

        # Copy MAS receipt
        if [[ -f "$SOURCE_APP/Contents/_MASReceipt/receipt" ]]; then
            mkdir -p "$MODDED_APP/Contents/_MASReceipt"
            cp "$SOURCE_APP/Contents/_MASReceipt/receipt" "$MODDED_APP/Contents/_MASReceipt/"
            log "MAS receipt copied"
        fi

        # Remove quarantine
        xattr -cr "$MODDED_APP" 2>/dev/null || true
        log "Quarantine attributes removed"
    fi
else
    if [[ ! -d "$MODDED_APP" ]]; then
        err "No modded copy found at $MODDED_APP"
        info "Run without --no-copy or --rebuild first"
        exit 1
    fi
    log "Using existing copy at $MODDED_APP"
fi

# ============================================================
# Step 2: Build SpliceKit dylib
# ============================================================
step "Step 2: Building SpliceKit dylib"

BUILD_DIR="$REPO_DIR/build"
mkdir -p "$BUILD_DIR"

SOURCES=(
    "$REPO_DIR/Sources/SpliceKit.m"
    "$REPO_DIR/Sources/SpliceKitRuntime.m"
    "$REPO_DIR/Sources/SpliceKitSwizzle.m"
    "$REPO_DIR/Sources/SpliceKitServer.m"
    "$REPO_DIR/Sources/SpliceKitTranscriptPanel.m"
    "$REPO_DIR/Sources/SpliceKitCommandPalette.m"
)

info "Compiling ${#SOURCES[@]} source files..."
clang -arch arm64 -arch x86_64 \
    -mmacosx-version-min=14.0 \
    -framework Foundation -framework AppKit \
    -fobjc-arc -fmodules \
    -undefined dynamic_lookup -dynamiclib \
    -install_name @rpath/SpliceKit.framework/Versions/A/SpliceKit \
    -I "$REPO_DIR/Sources" \
    "${SOURCES[@]}" \
    -o "$BUILD_DIR/SpliceKit" 2>&1

log "Built: $(file "$BUILD_DIR/SpliceKit" | grep -o 'universal.*')"

# ============================================================
# Step 3: Create framework bundle
# ============================================================
step "Step 3: Installing SpliceKit framework"

FW_DIR="$MODDED_APP/Contents/Frameworks/SpliceKit.framework"
mkdir -p "$FW_DIR/Versions/A/Resources"

# Copy dylib
cp "$BUILD_DIR/SpliceKit" "$FW_DIR/Versions/A/SpliceKit"

# Create symlinks
cd "$FW_DIR/Versions" && ln -sf A Current
cd "$FW_DIR" && ln -sf Versions/Current/SpliceKit SpliceKit
cd "$FW_DIR" && ln -sf Versions/Current/Resources Resources

# Create Info.plist
cat > "$FW_DIR/Versions/A/Resources/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.splicekit.SpliceKit</string>
    <key>CFBundleName</key><string>SpliceKit</string>
    <key>CFBundleVersion</key><string>2.0.0</string>
    <key>CFBundleShortVersionString</key><string>2.0.0</string>
    <key>CFBundlePackageType</key><string>FMWK</string>
    <key>CFBundleExecutable</key><string>SpliceKit</string>
</dict>
</plist>
PLIST

log "Framework installed"

# ============================================================
# Step 4: Inject LC_LOAD_DYLIB
# ============================================================
step "Step 4: Injecting dylib into FCP binary"

BINARY="$MODDED_APP/Contents/MacOS/Final Cut Pro"

# Check if already injected
if otool -L "$BINARY" 2>/dev/null | grep -q SpliceKit; then
    log "Already injected (skipping)"
else
    # Build insert_dylib if needed
    INSERT_DYLIB="/tmp/splicekit_insert_dylib"
    if [[ ! -f "$INSERT_DYLIB" ]]; then
        info "Building insert_dylib tool..."
        TMPDIR_ID=$(mktemp -d)
        git clone --quiet https://github.com/tyilo/insert_dylib.git "$TMPDIR_ID/insert_dylib" 2>/dev/null
        clang -o "$INSERT_DYLIB" "$TMPDIR_ID/insert_dylib/insert_dylib/main.c" -framework Foundation 2>/dev/null
        rm -rf "$TMPDIR_ID"
        log "insert_dylib built"
    fi

    "$INSERT_DYLIB" --inplace --all-yes \
        "@rpath/SpliceKit.framework/Versions/A/SpliceKit" \
        "$BINARY" 2>/dev/null

    log "LC_LOAD_DYLIB injected"
fi

# ============================================================
# Step 5: Create entitlements and re-sign
# ============================================================
step "Step 5: Re-signing (this takes a moment)"

# Create entitlements
ENTITLEMENTS="$BUILD_DIR/entitlements.plist"
cat > "$ENTITLEMENTS" << 'ENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.cs-disable-library-validation</key><true/>
    <key>com.apple.security.cs-allow-dyld-environment-variables</key><true/>
    <key>com.apple.security.get-task-allow</key><true/>
</dict>
</plist>
ENT

# Only sign the SpliceKit framework (ours) and the main app bundle.
# Apple's own frameworks must keep their original signatures or internal
# integrity checks (e.g. ProAppSupport +[PCApp isiMovie]) abort on launch.
info "Signing SpliceKit framework..."
codesign --force --sign - "$MODDED_APP/Contents/Frameworks/SpliceKit.framework" 2>/dev/null || true

# Sign main app with entitlements (disables library validation so our
# ad-hoc-signed SpliceKit framework loads alongside Apple-signed frameworks)
info "Signing main application..."
codesign --force --sign - --entitlements "$ENTITLEMENTS" "$MODDED_APP" 2>/dev/null

# Verify
VERIFY_OUT=$(codesign --verify --verbose "$MODDED_APP" 2>&1)
if echo "$VERIFY_OUT" | grep -q "valid on disk"; then
    log "Signature valid"
elif echo "$VERIFY_OUT" | grep -q "satisfies"; then
    log "Signature valid"
else
    # Mixed signatures (Apple + ad-hoc) may report issues but the app can
    # still launch with library validation disabled via entitlements.
    log "Signature note: $VERIFY_OUT"
fi

# Verify entitlements applied
if codesign -d --entitlements - "$MODDED_APP" 2>&1 | grep -q "cs-disable-library-validation"; then
    log "Entitlements applied (no sandbox, library validation disabled)"
else
    err "Entitlements not applied correctly"
    exit 1
fi

# ============================================================
# Step 6: Set up NSUserDefaults
# ============================================================
step "Step 6: Configuring defaults"

defaults write com.apple.FinalCut CloudContentFirstLaunchCompleted -bool true 2>/dev/null || true
defaults write com.apple.FinalCut FFCloudContentDisabled -bool true 2>/dev/null || true
log "CloudContent defaults set"

# Add speech recognition usage description for transcript feature
/usr/libexec/PlistBuddy -c "Add :NSSpeechRecognitionUsageDescription string 'SpliceKit uses speech recognition to transcribe timeline audio for text-based editing.'" "$MODDED_APP/Contents/Info.plist" 2>/dev/null || true
log "Speech recognition permission configured"

# ============================================================
# Step 7: Create MCP config
# ============================================================
step "Step 7: Setting up MCP server"

MCP_SERVER="$REPO_DIR/mcp/server.py"
if [[ -f "$MCP_SERVER" ]]; then
    MCP_CONFIG=".mcp.json"
    cat > "$MCP_CONFIG" << MCPJSON
{
  "mcpServers": {
    "fcpbridge": {
      "command": "python3",
      "args": ["$MCP_SERVER"]
    }
  }
}
MCPJSON
    log "MCP config written to $MCP_CONFIG"
else
    warn "MCP server not found at $MCP_SERVER"
fi

# ============================================================
# Done!
# ============================================================
step "Patching complete!"

echo -e "
${GREEN}${BOLD}SpliceKit has been installed successfully!${NC}

${BOLD}Launch:${NC}
  $MODDED_APP/Contents/MacOS/Final\\ Cut\\ Pro

${BOLD}Or double-click:${NC}
  $MODDED_APP

${BOLD}JSON-RPC server:${NC}
  127.0.0.1:$BRIDGE_PORT (starts automatically)

${BOLD}Check logs:${NC}
  ~/Library/Logs/SpliceKit/splicekit.log

${BOLD}Python client:${NC}
  python3 $REPO_DIR/Scripts/fcpbridge_client.py

${BOLD}MCP server:${NC}
  Configured in .mcp.json (restart Claude Code to load)

${BOLD}Quick test:${NC}
  echo '{\"jsonrpc\":\"2.0\",\"method\":\"system.version\",\"id\":1}' | nc 127.0.0.1 $BRIDGE_PORT

${BOLD}Uninstall:${NC}
  $0 --uninstall
"
