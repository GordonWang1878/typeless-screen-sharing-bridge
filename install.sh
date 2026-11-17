#!/usr/bin/env bash
# One-line installer:
#   curl -fsSL https://raw.githubusercontent.com/GordonWang1878/typeless-remote-bridge/main/install.sh | bash
# Downloads the latest code into ~/.local/share/typeless-remote-bridge and starts the setup
# wizard. Nothing is installed before the wizard asks. Run it again to upgrade or uninstall.
set -euo pipefail

TARBALL="${TB_TARBALL:-https://codeload.github.com/GordonWang1878/typeless-remote-bridge/tar.gz/refs/heads/main}"
DEST="$HOME/.local/share/typeless-remote-bridge"

[[ $(uname -s) == Darwin ]] || { echo "Typeless Remote Bridge runs on macOS only." >&2; exit 1; }

work=$(mktemp -d "${TMPDIR:-/tmp}/typeless-remote-bridge.XXXXXX")
trap 'rm -rf "$work"' EXIT
echo "Downloading Typeless Remote Bridge…"
if [[ -d $TARBALL ]]; then
  cp -R "$TARBALL/." "$work/src"   # local checkout (development and tests)
else
  mkdir -p "$work/src"
  curl -fsSL "$TARBALL" | tar -xz -C "$work/src" --strip-components 1
fi
[[ -x "$work/src/setup" ]] || { echo "Download incomplete; try again." >&2; exit 1; }

mkdir -p "$(dirname "$DEST")"
rm -rf "$DEST.new" && mv "$work/src" "$DEST.new"
rm -rf "$DEST" && mv "$DEST.new" "$DEST"

# The wizard reads answers from the terminal, also when this script itself came through a pipe.
[[ ${TB_NO_SETUP:-} == 1 ]] && exit 0   # tests stop here
exec bash "$DEST/setup" </dev/tty
