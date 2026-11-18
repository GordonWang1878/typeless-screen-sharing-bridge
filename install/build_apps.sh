#!/usr/bin/env bash
# Build the Swift helper apps as ad-hoc-signed LSUIElement .app bundles.
#
# Usage: install/build_apps.sh <output-dir>
#
# Writes only inside <output-dir> (plus a mktemp work dir that is removed on exit). Set
# TB_MODULE_CACHE to a folder to keep Swift's module cache between builds (saves ~25 s each).
# Never installs, launches, or touches ~/Library or ~/Applications.
# Only --self-test is ever executed.
set -euo pipefail

if [[ $# -lt 1 || -z "${1}" ]]; then
  echo "usage: $0 <output-dir>" >&2
  exit 64
fi
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "error: macOS only" >&2
  exit 1
fi
for tool in swiftc codesign plutil lipo; do
  command -v "$tool" >/dev/null 2>&1 || { echo "error: missing tool: $tool" >&2; exit 1; }
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

mkdir -p -- "$1"
OUT="$(cd "$1" && pwd)"

WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT

# make_bundle <AppName> <Exec> <BundleID> <swiftc inputs...>
make_bundle() {
  local name="$1" exec="$2" id="$3"
  shift 3
  local app="$OUT/$name.app"
  local module="${exec//-/_}"

  rm -rf -- "$app"
  mkdir -p -- "$app/Contents/MacOS"

  # Compile from apps/ with relative source names: swiftc embeds the source path as given, and
  # an absolute path would make the CDHash depend on where the checkout lives (each new hash
  # needs a new Device Control grant).
  # Universal (Apple silicon + Intel): the receiver is built here and copied to the Macs this one
  # controls, which may have the other kind of chip.
  local arch slices=()
  for arch in arm64 x86_64; do
    (cd "$REPO_ROOT/apps" && swiftc -target "$arch-apple-macos13" -module-name "$module" \
      -module-cache-path "${TB_MODULE_CACHE:-$WORK}/modcache-$arch" -o "$WORK/$exec-$arch" "$@")
    slices+=("$WORK/$exec-$arch")
  done
  lipo -create -output "$app/Contents/MacOS/$exec" "${slices[@]}"

  cat >"$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>${exec}</string>
  <key>CFBundleIdentifier</key>
  <string>${id}</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleName</key>
  <string>${name}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSUIElement</key>
  <true/>
</dict>
</plist>
PLIST
  plutil -lint "$app/Contents/Info.plist" >/dev/null
  # Same icon for all three, so they are easy to spot in the Device Control list.
  mkdir -p -- "$app/Contents/Resources"
  cp -- "$REPO_ROOT/apps/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"

  codesign --force --sign - "$app"
  codesign --verify --strict "$app"
  echo "built: $app"
}

# 1. Receiver: pastes text it is sent at the current focus.
make_bundle TypelessBridgeReceiver TypelessBridgeReceiver \
  org.local.typelessbridge.receiver \
  receiver.swift

# 2. Guard: stops Typeless' own paste into a destination's Screen Sharing window.
make_bundle TypelessBridgeGuard TypelessBridgeGuard \
  org.local.typelessbridge.guard \
  guard.swift

# 3. Probe: tells which destination the focused Screen Sharing window shows.
make_bundle TypelessBridgeProbe TypelessBridgeProbe \
  org.local.typelessbridge.probe \
  probe.swift

# Self-tests. These exit before any Accessibility, event tap, or socket setup.
self_test() {
  local name="$1" exec="$2"
  echo "self-test: $name"
  "$OUT/$name.app/Contents/MacOS/$exec" --self-test
}
self_test TypelessBridgeReceiver TypelessBridgeReceiver
self_test TypelessBridgeGuard TypelessBridgeGuard
self_test TypelessBridgeProbe TypelessBridgeProbe

echo "all 3 apps built and self-tests passed into: $OUT"
