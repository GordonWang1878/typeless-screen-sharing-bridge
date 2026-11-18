#!/usr/bin/env bash
# One-line installer:
#   curl -fsSL https://raw.githubusercontent.com/GordonWang1878/typeless-screen-sharing-bridge/main/install.sh | bash
# Downloads the latest code into ~/.local/share/typeless-remote-bridge and starts the setup
# wizard. Nothing is installed before the wizard asks. Run it again to upgrade or uninstall.
set -euo pipefail

TARBALL="${TB_TARBALL:-https://codeload.github.com/GordonWang1878/typeless-screen-sharing-bridge/tar.gz/refs/heads/main}"
DEST="$HOME/.local/share/typeless-remote-bridge"

zh=0; defaults read -g AppleLanguages 2>/dev/null | tr -d ' \n"(' | cut -d, -f1 | grep -q '^zh' && zh=1
say() { if ((zh)); then echo "$1"; else echo "$2"; fi; }

[[ $(uname -s) == Darwin ]] || { echo "Screen Sharing Bridge for Typeless runs on macOS only." >&2; exit 1; }

work=$(mktemp -d "${TMPDIR:-/tmp}/typeless-remote-bridge.XXXXXX")
trap 'rm -rf "$work"' EXIT
say "正在下载 Screen Sharing Bridge for Typeless…" "Downloading Screen Sharing Bridge for Typeless…"
if [[ -d $TARBALL ]]; then
  cp -R "$TARBALL/." "$work/src"   # local checkout (development and tests)
else
  mkdir -p "$work/src"
  curl -fsSL "$TARBALL" | tar -xz -C "$work/src" --strip-components 1
fi
[[ -x "$work/src/setup" ]] || { echo "Download incomplete; try again." >&2; exit 1; }

cd "$HOME"   # never stand inside the folder that is about to be replaced
mkdir -p "$(dirname "$DEST")"
rm -rf "$DEST.new" && mv "$work/src" "$DEST.new"
rm -rf "$DEST" && mv "$DEST.new" "$DEST"

[[ ${TB_NO_SETUP:-} == 1 ]] && exit 0   # tests stop here

# The setup window is built on this Mac, which needs Apple's Command Line Tools.
if ! xcrun --find swiftc >/dev/null 2>&1; then
  say "需要先安装 Apple 的命令行开发工具：在弹出的窗口里点\"安装\"（可能要几分钟）。" \
      "Installing Apple's Command Line Tools first: click Install in the window that opens (can take minutes)."
  say "（如果你取消了它，按 Ctrl+C，之后再运行一次这行命令。）" "(If you cancelled it, press Ctrl+C and run this command again later.)"
  xcode-select --install >/dev/null 2>&1 || true
  waited=0
  until xcrun --find swiftc >/dev/null 2>&1; do
    sleep 5; waited=$((waited + 5))
    ((waited % 300 == 0)) && say "还在等命令行开发工具装好…" "Still waiting for the Command Line Tools…"
  done
fi
rm -rf "$work"; trap - EXIT
exec bash "$DEST/setup" --window
