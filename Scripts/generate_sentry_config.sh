#!/bin/bash
set -euo pipefail

if [ $# -ne 1 ]; then
    echo "Usage: $0 <output-plist>" >&2
    exit 1
fi

OUT_PATH="$1"
OUT_DIR="$(dirname "${OUT_PATH}")"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION_FILE="${REPO_ROOT}/patcher/SpliceKit/Configuration/Version.xcconfig"

read_version() {
    awk -F= '/SPLICEKIT_VERSION/ { gsub(/[ ;]/, "", $2); print $2; exit }' "${VERSION_FILE}"
}

PATCHER_DSN="${SPLICEKIT_SENTRY_PATCHER_DSN:-}"
RUNTIME_DSN="${SPLICEKIT_SENTRY_RUNTIME_DSN:-}"
ENVIRONMENT="${SPLICEKIT_SENTRY_ENVIRONMENT:-production}"
RELEASE_NAME="splicekit@$(read_version)"

mkdir -p "${OUT_DIR}"

cat > "${OUT_PATH}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>PatcherDSN</key>
    <string>${PATCHER_DSN}</string>
    <key>RuntimeDSN</key>
    <string>${RUNTIME_DSN}</string>
    <key>Environment</key>
    <string>${ENVIRONMENT}</string>
    <key>ReleaseName</key>
    <string>${RELEASE_NAME}</string>
    <key>PatcherEnabled</key>
    $( [ -n "${PATCHER_DSN}" ] && printf '<true/>' || printf '<false/>' )
    <key>RuntimeEnabled</key>
    $( [ -n "${RUNTIME_DSN}" ] && printf '<true/>' || printf '<false/>' )
</dict>
</plist>
EOF

echo "Generated ${OUT_PATH}"
