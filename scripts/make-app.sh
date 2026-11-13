#!/bin/zsh
# Build dist/LocalBench.app — a self-contained, double-clickable app bundle
# wrapping the LocalBenchApp executable (ad-hoc signed; Gatekeeper accepts
# locally built apps).
#
# Usage: scripts/make-app.sh [--configuration release]
set -euo pipefail

CONFIG="release"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --configuration) CONFIG="$2"; shift 2 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Xcode 27+ toolchain required for Foundation Models; respect an existing
# DEVELOPER_DIR, otherwise point at /Applications/Xcode.app.
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  fi
fi
if ! command -v swift >/dev/null 2>&1; then
  echo "error: swift not found (install Xcode and set DEVELOPER_DIR)" >&2
  exit 1
fi

echo "==> swift build -c $CONFIG --product LocalBenchApp"
swift build -c "$CONFIG" --product LocalBenchApp

# Locate the built binary (layout differs between SwiftPM versions).
BIN=""
for candidate in \
  ".build/out/Products/$([ "$CONFIG" = "release" ] && echo Release || echo Debug)/LocalBenchApp" \
  ".build/$CONFIG/LocalBenchApp" \
  ".build/arm64-apple-macosx/$CONFIG/LocalBenchApp" \
  ".build/release/LocalBenchApp"; do
  if [[ -x "$candidate" ]]; then BIN="$candidate"; break; fi
done
if [[ -z "$BIN" ]]; then
  echo "error: could not locate the built LocalBenchApp binary" >&2
  exit 1
fi
echo "==> binary: $BIN"

APP="dist/LocalBench.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>LocalBench</string>
    <key>CFBundleDisplayName</key><string>LocalBench</string>
    <key>CFBundleIdentifier</key><string>local.localbench.app</string>
    <key>CFBundleExecutable</key><string>LocalBenchApp</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>Local-only inference benchmarking. No network egress.</string>
</dict>
</plist>
PLIST

cp "$BIN" "$APP/Contents/MacOS/LocalBenchApp"

echo "==> codesign (ad-hoc)"
codesign --force --sign - "$APP"

echo ""
echo "Built $APP"
echo "Open with: open $APP"
echo "App database: ~/Library/Application Support/LocalBench/localbench.sqlite"
