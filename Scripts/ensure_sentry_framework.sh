#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FRAMEWORKS_DIR="${REPO_ROOT}/patcher/Frameworks"
FRAMEWORK_PATH="${FRAMEWORKS_DIR}/Sentry.framework"
VERSION_FILE="${FRAMEWORKS_DIR}/.sentry-sdk-version"
SENTRY_COCOA_VERSION="${SENTRY_COCOA_VERSION:-9.10.0}"
ARCHIVE_URL="https://github.com/getsentry/sentry-cocoa/releases/download/${SENTRY_COCOA_VERSION}/Sentry.xcframework.zip"
SLICE_DIR="macos-arm64_arm64e_x86_64"

if [ -d "${FRAMEWORK_PATH}" ] && [ -f "${VERSION_FILE}" ] && [ "$(cat "${VERSION_FILE}")" = "${SENTRY_COCOA_VERSION}" ]; then
    exit 0
fi

mkdir -p "${FRAMEWORKS_DIR}"
TMP_DIR="$(mktemp -d)"
cleanup() {
    rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

ARCHIVE_PATH="${TMP_DIR}/Sentry.xcframework.zip"
echo "Fetching Sentry Cocoa ${SENTRY_COCOA_VERSION}..."
curl -L --fail --silent --show-error "${ARCHIVE_URL}" -o "${ARCHIVE_PATH}"

cd "${TMP_DIR}"
unzip -q "${ARCHIVE_PATH}"

SOURCE_FRAMEWORK="${TMP_DIR}/Sentry.xcframework/${SLICE_DIR}/Sentry.framework"
if [ ! -d "${SOURCE_FRAMEWORK}" ]; then
    echo "ERROR: macOS Sentry framework slice not found in ${ARCHIVE_URL}" >&2
    exit 1
fi

rm -rf "${FRAMEWORK_PATH}"
cp -R "${SOURCE_FRAMEWORK}" "${FRAMEWORK_PATH}"
printf '%s\n' "${SENTRY_COCOA_VERSION}" > "${VERSION_FILE}"
echo "Installed ${FRAMEWORK_PATH}"
