#!/usr/bin/env bash
# Build the setup window as "Screen Sharing Bridge Setup.app" in <output-dir> (this Mac's chip only,
# ad-hoc signed). Only the Mac you talk to needs it; it is not installed anywhere.
set -euo pipefail
[[ $# -ge 1 && -n $1 ]] || { echo "usage: $0 <output-dir>" >&2; exit 64; }
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p -- "$1"; OUT="$(cd "$1" && pwd)"
APP="$OUT/Screen Sharing Bridge Setup.app"
WORK="$(mktemp -d)"; trap 'rm -rf -- "$WORK"' EXIT
rm -rf -- "$APP"; mkdir -p -- "$APP/Contents/MacOS" "$APP/Contents/Resources"
(cd "$REPO_ROOT/apps" && swiftc -O -parse-as-library -target "$(uname -m)-apple-macos13" -module-name SetupWindow -module-cache-path "${TB_MODULE_CACHE:-$WORK}/modcache-window" \
  -o "$APP/Contents/MacOS/SetupWindow" setup-window.swift)
cp -- "$REPO_ROOT/apps/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cat >"$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>SetupWindow</string>
  <key>CFBundleIdentifier</key><string>org.local.typelessbridge.setup</string>
  <key>CFBundleName</key><string>Screen Sharing Bridge Setup</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null
codesign --force --sign - "$APP" 2>/dev/null
echo "$APP"
