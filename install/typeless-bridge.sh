#!/usr/bin/env bash
# Screen Sharing Bridge for Typeless installer. Runs on the Mac being set up, as the logged-in user. No sudo.
#
#   typeless-bridge.sh install [--sender DESTS] [--receiver] [--apps-dir DIR]
#   typeless-bridge.sh uninstall [--purge-state] [--keep-permissions]
#   typeless-bridge.sh configure [--add-sender NAME] [--remove-sender NAME] [--receiver on|off] [--apps-dir DIR]
#   typeless-bridge.sh status
#   typeless-bridge.sh pair NAME USER@HOST [--fingerprint SHA256:...]
#   typeless-bridge.sh unpair NAME
#
#   --sender DESTS   this Mac dictates into Screen Sharing windows of DESTS: a comma list of
#                    ssh aliases (lowercase letters, digits, -), e.g. studio,office. Each must
#                    already work without a password (see the pair command).
#   --receiver       this Mac accepts text from senders and pastes it at its current focus.
#   --apps-dir DIR   use prebuilt apps from DIR instead of building with install/build_apps.sh.
#   --purge-state    also delete the receiver's consumed-id journal and socket folder.
#   --keep-permissions  leave the Device Control approvals (used when reinstalling).
#   configure        change roles on top of what is installed (installs if nothing is), keeping
#                    the Device Control approvals; removing the last role uninstalls.
#   pair             on a sender: set up passwordless ssh alias NAME to the receiver Mac
#                    USER@HOST (Remote Login must be on there). Asks to confirm the host key
#                    fingerprint, then for the remote password once. --fingerprint skips the
#                    question by comparing automatically.
#   unpair           remove the ssh setup that pair added for NAME.
#
# Everything installed is listed in "$ROOT/manifest"; uninstall removes exactly that.
# After install, grant Privacy & Security -> Device Control to the apps printed at the end.
set -euo pipefail

ROOT="$HOME/Library/Application Support/TypelessRemoteBridge"
APPS="$ROOT/Apps"
SERVICE="$ROOT/service"
LOGS="$HOME/Library/Logs/TypelessRemoteBridge"
AGENTS="$HOME/Library/LaunchAgents"
SENDER_LABEL="org.local.typelessbridge.sender"
RECEIVER_LABEL="org.local.typelessbridge.receiver"
RECEIVER_STATE="$HOME/.local/state/typeless-remote-bridge"
LAUNCHCTL="${TB_LAUNCHCTL:-launchctl}"
DOMAIN="gui/$(id -u)"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVICE_FILES=(sender.py watcher.py identities.py completion_dispatch.py completion_routing.py)
SENDER_APPS=(TypelessBridgeProbe TypelessBridgeGuard)
RECEIVER_APPS=(TypelessBridgeReceiver)

die() { echo "error: $*" >&2; exit 1; }
say() { echo "== $*"; }
loaded() { "$LAUNCHCTL" print "$DOMAIN/$1" >/dev/null 2>&1; }
xml() { local s=${1//&/&amp;}; s=${s//</&lt;}; s=${s//>/&gt;}; printf '%s' "$s"; }

plist() {  # plist <label> <keepalive: always|on-failure> <stdout> <stderr> <program args...>
  local label=$1 keep=$2 out=$3 err=$4; shift 4
  echo '<?xml version="1.0" encoding="UTF-8"?>'
  echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
  echo '<plist version="1.0"><dict>'
  echo "  <key>Label</key><string>$label</string>"
  echo '  <key>ProgramArguments</key><array>'
  local a; for a in "$@"; do echo "    <string>$(xml "$a")</string>"; done
  echo '  </array>'
  echo "  <key>WorkingDirectory</key><string>$(xml "$HOME")</string>"
  echo '  <key>RunAtLoad</key><true/>'
  # The sender must keep retrying until permissions are granted (GUARD_NOT_READY) and after
  # any guard exit; the receiver only needs a restart after a crash.
  if [[ $keep == always ]]; then echo '  <key>KeepAlive</key><true/>'
  else echo '  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>'; fi
  echo '  <key>ThrottleInterval</key><integer>30</integer>'
  echo '  <key>ProcessType</key><string>Interactive</string>'
  echo '  <key>LimitLoadToSessionType</key><string>Aqua</string>'
  echo "  <key>StandardOutPath</key><string>$(xml "$out")</string>"
  echo "  <key>StandardErrorPath</key><string>$(xml "$err")</string>"
  echo '</dict></plist>'
}

receiver_health() {
  printf '{"op":"health"}\n' | /usr/bin/nc -U -w 5 "$RECEIVER_STATE/receiver.sock" 2>/dev/null || true
}

install_failed() {
  echo "error: install failed part-way." >&2
  if [[ -e "$ROOT/manifest" ]]; then
    echo "  run: $0 uninstall   to remove what was installed" >&2
  else
    echo "  remove the partial install: rm -rf \"$APPS\" \"$SERVICE\" \"$ROOT/manifest.tmp\"" >&2
  fi
}

cmd_install() {
  local dests="" receiver=0 apps_dir=""
  while (($#)); do
    case $1 in
      --sender) (($# >= 2)) || die "--sender needs a value"; dests=$2; shift 2 ;;
      --receiver) receiver=1; shift ;;
      --apps-dir) (($# >= 2)) || die "--apps-dir needs a value"; apps_dir=$2; shift 2 ;;
      *) die "unknown option: $1" ;;
    esac
  done
  [[ -n $dests || $receiver == 1 ]] || die "nothing to install: give --sender DESTS and/or --receiver"
  [[ "$HOME" =~ ^/[A-Za-z0-9._/\ -]+$ ]] || die "unsupported HOME path: $HOME"

  if [[ -n $dests ]]; then
    local d seen=","
    IFS=, read -ra list <<< "$dests"
    ((${#list[@]})) || die "--sender needs at least one destination"
    for d in "${list[@]}"; do
      [[ $d =~ ^[a-z0-9][a-z0-9-]{0,31}$ && $d != local ]] \
        || die "destination must be an ssh alias of lowercase letters, digits and -: '$d'"
      [[ $seen != *",$d,"* ]] || die "duplicate destination: $d"; seen+="$d,"
    done
    [[ -e "$HOME/Library/Application Support/Typeless/typeless.db" ]] \
      || die "Typeless database not found; install and sign in to Typeless first"
    /usr/bin/python3 -c 'import sqlite3' 2>/dev/null || die "/usr/bin/python3 unavailable (xcode-select --install)"
    for d in "${list[@]}"; do
      [[ ",${SSH_ALREADY_OK:-}," == *",$d,"* ]] && continue   # set by configure for existing ones
      ssh -T -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=5 "$d" true </dev/null \
        || die "ssh $d failed; run: $0 pair $d USER@HOST"
    done
  fi

  [[ ! -e "$ROOT/manifest" ]] || die "already installed; run uninstall first"

  local built
  if [[ -n $apps_dir ]]; then
    built=$(cd "$apps_dir" && pwd)
  else
    built=$(mktemp -d "${TMPDIR:-/tmp}/typeless-bridge-build.XXXXXX")
    BUILD_TMP=$built
    trap 'rm -rf "${BUILD_TMP:-}"' EXIT
    say "building apps"
    local build_log="$built.log"
    "$REPO/install/build_apps.sh" "$built" >"$build_log" 2>&1 || { cat "$build_log" >&2; rm -f "$build_log"; die "building the apps failed"; }
    rm -f "$build_log"
  fi
  local want=() a
  [[ -n $dests ]] && want+=("${SENDER_APPS[@]}")
  ((receiver)) && want+=("${RECEIVER_APPS[@]}")
  for a in "${want[@]}"; do
    codesign --verify --strict "$built/$a.app" 2>/dev/null || die "missing or unsigned app: $built/$a.app"
  done

  # From here on a failure leaves a partial install; say exactly how to get back.
  trap 'install_failed' ERR

  say "installing into $ROOT"
  mkdir -p "$APPS" "$LOGS" "$AGENTS"; chmod 700 "$ROOT" "$LOGS"
  local manifest="$ROOT/manifest.tmp"; : > "$manifest"
  for a in "${want[@]}"; do
    ditto "$built/$a.app" "$APPS/$a.app"
  done
  echo "dir $ROOT" >> "$manifest"
  echo "dir $LOGS" >> "$manifest"

  if [[ -n $dests ]]; then
    mkdir -p "$SERVICE"
    for a in "${SERVICE_FILES[@]}"; do cp "$REPO/service/$a" "$SERVICE/$a"; done
    plist "$SENDER_LABEL" always "$LOGS/sender.log" "$LOGS/sender.err.log" \
      /usr/bin/python3 -u "$SERVICE/sender.py" --destinations "$dests" \
      --focus-app "$APPS/TypelessBridgeProbe.app" --guard-app "$APPS/TypelessBridgeGuard.app" \
      --lock-file "$ROOT/sender.lock" --identities-file "$ROOT/identities.json" \
      > "$AGENTS/$SENDER_LABEL.plist"
    plutil -lint "$AGENTS/$SENDER_LABEL.plist" >/dev/null
    echo "agent $SENDER_LABEL" >> "$manifest"
  fi
  if ((receiver)); then
    plist "$RECEIVER_LABEL" on-failure /dev/null "$LOGS/receiver.err.log" \
      "$APPS/TypelessBridgeReceiver.app/Contents/MacOS/TypelessBridgeReceiver" \
      > "$AGENTS/$RECEIVER_LABEL.plist"
    plutil -lint "$AGENTS/$RECEIVER_LABEL.plist" >/dev/null
    echo "agent $RECEIVER_LABEL" >> "$manifest"
    echo "state $RECEIVER_STATE" >> "$manifest"
  fi
  echo "options sender=${dests:-none} receiver=$receiver" >> "$manifest"
  # Which release is installed (shown by the setup window; installs before 1.0.1 have no line).
  [[ -f "$REPO/VERSION" ]] && echo "version $(tr -d '[:space:]' < "$REPO/VERSION")" >> "$manifest"
  mv "$manifest" "$ROOT/manifest"

  # launchd can refuse a bootstrap right after a bootout of the same label: retry once. Kept inline
  # (not in a function) so a final failure still reaches the ERR trap with its recovery advice.
  if ((receiver)); then
    "$LAUNCHCTL" bootstrap "$DOMAIN" "$AGENTS/$RECEIVER_LABEL.plist" 2>/dev/null \
      || { sleep 1; "$LAUNCHCTL" bootstrap "$DOMAIN" "$AGENTS/$RECEIVER_LABEL.plist"; }
  fi
  if [[ -n $dests ]]; then
    "$LAUNCHCTL" bootstrap "$DOMAIN" "$AGENTS/$SENDER_LABEL.plist" 2>/dev/null \
      || { sleep 1; "$LAUNCHCTL" bootstrap "$DOMAIN" "$AGENTS/$SENDER_LABEL.plist"; }
  fi

  trap - ERR
  say "installed. Grant Privacy & Security -> Device Control to:"
  for a in "${want[@]}"; do echo "   $APPS/$a.app"; done
  echo "then run: $0 status"
}

cmd_uninstall() {
  local purge=0 keep=0
  while (($#)); do
    case $1 in --purge-state) purge=1; shift ;; --keep-permissions) keep=1; shift ;; *) die "unknown option: $1" ;; esac
  done
  [[ -e "$ROOT/manifest" ]] || die "not installed (no $ROOT/manifest)"
  local kind value
  while read -r kind value; do
    [[ $kind == agent ]] || continue
    say "stopping $value"
    loaded "$value" && "$LAUNCHCTL" bootout "$DOMAIN/$value" || true
    rm -f "$AGENTS/$value.plist"
  done < "$ROOT/manifest"
  # Helpers started by the sender (the guard, a probe) outlive its agent for a few seconds. A
  # running helper that asks for its permission puts its Device Control entry right back, so
  # stop them before forgetting the approvals.
  pkill -f "$APPS/" 2>/dev/null || true
  local wait_n; for wait_n in 1 2 3 4 5 6 7 8 9 10; do pgrep -f "$APPS/" >/dev/null 2>&1 || break; sleep 0.5; done
  # Forget the Device Control approvals of our apps, so a reinstall starts clean. tccutil only
  # knows an app while it is on disk, so this runs before the apps are deleted.
  local app id
  ((keep)) || for app in "$APPS"/*.app; do
    [[ -e $app ]] || continue
    id=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$app/Contents/Info.plist" 2>/dev/null) || continue
    "${TB_TCCUTIL:-tccutil}" reset Accessibility "$id" >/dev/null 2>&1 && say "removed the Device Control entry of $(basename "$app" .app)"
  done
  if ((purge)) && grep -q "^state " "$ROOT/manifest"; then
    say "removing receiver state $RECEIVER_STATE"
    rm -rf "$RECEIVER_STATE"
  fi
  rm -rf "$ROOT"
  rm -rf "$LOGS"
  say "uninstalled."
}

current_option() { sed -n "s/^options .*$1=\([^ ]*\).*/\1/p" "$ROOT/manifest" 2>/dev/null || true; }

cmd_configure() {
  local add="" remove="" receiver="" apps_dir=""
  while (($#)); do
    case $1 in
      --add-sender) (($# >= 2)) || die "--add-sender needs a value"; add=$2; shift 2 ;;
      --remove-sender) (($# >= 2)) || die "--remove-sender needs a value"; remove=$2; shift 2 ;;
      --receiver) [[ ${2:-} == on || ${2:-} == off ]] || die "--receiver needs on or off"; receiver=$2; shift 2 ;;
      --apps-dir) (($# >= 2)) || die "--apps-dir needs a value"; apps_dir=$2; shift 2 ;;
      *) die "unknown option: $1" ;;
    esac
  done
  local dests rec d list=""
  dests=$(current_option sender); [[ $dests == none ]] && dests=""
  rec=$(current_option receiver); rec=${rec:-0}
  for d in $(printf '%s' "$dests" | tr ',' ' '); do
    [[ $d == "$remove" || $d == "$add" ]] || list="${list:+$list,}$d"
  done
  [[ -n $add ]] && list="${list:+$list,}$add"
  local old_rec=$rec
  [[ $receiver == on ]] && rec=1
  [[ $receiver == off ]] && rec=0
  if [[ -z $list && $rec == 0 ]]; then
    [[ -e "$ROOT/manifest" ]] && cmd_uninstall --purge-state
    return 0
  fi
  # Check everything that could fail before touching the working install, so a Mac that is asleep
  # or a bad build never leaves this one with nothing. Only a newly added Mac needs an ssh check.
  if [[ -n $list ]]; then
    [[ -e "$HOME/Library/Application Support/Typeless/typeless.db" ]] \
      || die "Typeless database not found; install and sign in to Typeless first"
    if [[ -n $add ]]; then
      ssh -T -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=5 "$add" true </dev/null \
        || die "ssh $add failed; run: $0 pair $add USER@HOST"
    fi
  fi
  if [[ -n $apps_dir ]]; then
    local need=()
    [[ -n $list ]] && need+=("${SENDER_APPS[@]}")
    ((rec)) && need+=("${RECEIVER_APPS[@]}")
    for d in "${need[@]}"; do
      codesign --verify --strict "$apps_dir/$d.app" 2>/dev/null || die "missing or unsigned app: $apps_dir/$d.app"
    done
  fi
  # A role that goes away takes its Device Control entries with it (while its apps still exist).
  local gone=()
  [[ $old_rec == 1 && $rec == 0 ]] && gone+=("${RECEIVER_APPS[@]}")
  [[ -n $dests && -z $list ]] && gone+=("${SENDER_APPS[@]}")
  if ((${#gone[@]})); then
    # A running helper would put its entry right back: stop the agents and helpers first.
    local kind value
    while read -r kind value; do
      [[ $kind == agent ]] && { loaded "$value" && "$LAUNCHCTL" bootout "$DOMAIN/$value" || true; }
    done < "$ROOT/manifest"
    pkill -f "$APPS/" 2>/dev/null || true
    for d in 1 2 3 4 5 6 7 8 9 10; do pgrep -f "$APPS/" >/dev/null 2>&1 || break; sleep 0.5; done
  fi
  for d in ${gone[@]+"${gone[@]}"}; do
    local id; id=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APPS/$d.app/Contents/Info.plist" 2>/dev/null) \
      && "${TB_TCCUTIL:-tccutil}" reset Accessibility "$id" >/dev/null 2>&1
  done
  [[ -e "$ROOT/manifest" ]] && cmd_uninstall --keep-permissions >/dev/null
  SSH_ALREADY_OK=$(printf '%s' "$list" | tr ',' '\n' | grep -vx -- "$add" | paste -sd, - || true)
  local args=()
  [[ -n $list ]] && args+=(--sender "$list")
  ((rec)) && args+=(--receiver)
  [[ -n $apps_dir ]] && args+=(--apps-dir "$apps_dir")
  cmd_install "${args[@]}"
}

SSH_DIR="$HOME/.ssh"
BRIDGE_KEY="$SSH_DIR/typeless_bridge_ed25519"
REMOTE_HEALTH="printf '{\"op\":\"health\"}\\n' | /usr/bin/nc -U -w 5 \"\$HOME/.local/state/typeless-remote-bridge/receiver.sock\""

valid_name() { [[ $1 =~ ^[a-z0-9][a-z0-9-]{0,31}$ && $1 != local ]]; }
block_begin() { echo "# >>> typeless-bridge $1"; }
block_end() { echo "# <<< typeless-bridge $1"; }

remove_block() {  # remove_block <name> <file>
  [[ -e $2 ]] || return 0
  local begin end; begin=$(block_begin "$1"); end=$(block_end "$1")
  grep -qxF "$begin" "$2" || return 0
  # A block whose end marker was edited away would swallow the rest of the file: leave it alone.
  grep -qxF "$end" "$2" || die "the typeless-bridge block for $1 in $2 has no end marker; fix it by hand"
  # Write to the real file, so a symlinked config (dotfiles) stays a symlink.
  local real=$2 link
  while [[ -L $real ]]; do link=$(readlink "$real"); [[ $link == /* ]] && real=$link || real=$(dirname "$real")/$link; done
  local tmp; tmp=$(mktemp "$real.XXXXXX")
  awk -v b="$begin" -v e="$end" '$0==b{skip=1; next} $0==e{skip=0; next} !skip' "$real" > "$tmp" \
    && chmod 600 "$tmp" && mv "$tmp" "$real" || { rm -f "$tmp"; die "could not update $2"; }
}

remote_check() {  # remote_check <name>: passwordless login and receiver health
  ssh -T -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=5 "$1" true </dev/null \
    || die "ssh $1 still asks for a password or fails"
  local health; health=$(ssh -T -o BatchMode=yes -o ConnectTimeout=5 "$1" "$REMOTE_HEALTH" </dev/null || true)
  case $health in
    *'"ready"'*) say "$1: ssh works and the receiver is ready" ;;
    *needs-accessibility*) say "$1: ssh works; on $1 grant Device Control to TypelessBridgeReceiver" ;;
    *) say "$1: ssh works, but no receiver answers there yet; run 'install --receiver' on $1" ;;
  esac
}

cmd_pair() {
  local name=${1:-} target=${2:-} want=""
  (($# >= 2)) || die "usage: pair NAME USER@HOST [--fingerprint SHA256:...]"
  shift 2
  while (($#)); do
    case $1 in
      --fingerprint) (($# >= 2)) || die "--fingerprint needs a value"; want=$2; shift 2 ;;
      *) die "unknown option: $1" ;;
    esac
  done
  valid_name "$name" || die "NAME must be lowercase letters, digits and -: '$name'"
  if grep -qxF "$(block_begin "$name")" "$HOME/.ssh/config" 2>/dev/null && ! grep -qxF "$(block_end "$name")" "$HOME/.ssh/config"; then
    die "the typeless-bridge block for $name in ~/.ssh/config has no end marker; fix it by hand"
  fi
  [[ $target =~ ^([A-Za-z0-9._-]+)@([A-Za-z0-9.:-]+)$ ]] || die "give the receiver as USER@HOST, e.g. alice@studio.local"
  local user=${BASH_REMATCH[1]} host=${BASH_REMATCH[2]}
  mkdir -p "$SSH_DIR"; chmod 700 "$SSH_DIR"
  local config="$SSH_DIR/config" known="$SSH_DIR/known_hosts"

  if [[ -e $config ]] && grep -qE "^[[:space:]]*Host([[:space:]].*)?[[:space:]]$name([[:space:]]|\$)" "$config" \
      && ! grep -qxF "$(block_begin "$name")" "$config"; then
    say "Host $name is already in $config (not written by this script); checking it"
    remote_check "$name"; return 0
  fi

  # Host key: show it, have it confirmed, and remember it under a fixed alias so a changed
  # address does not invalidate it.
  local scanned fp
  scanned=$(ssh-keyscan -T 5 -t ed25519 "$host" 2>/dev/null | grep -v '^#' | head -1) || true
  [[ -n $scanned ]] || die "cannot reach $host on port 22; turn on Remote Login on that Mac (System Settings > General > Sharing)"
  fp=$(printf '%s\n' "$scanned" | ssh-keygen -lf - | awk '{print $2}')
  [[ $fp == SHA256:* ]] || die "could not read the host key of $host"
  if [[ -n $want ]]; then
    [[ $fp == "$want" ]] || die "host key of $host is $fp, not $want; not pairing"
  else
    echo "Host key fingerprint of $host:  $fp"
    echo "On that Mac, check it with:  ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub"
    local answer; read -r -p "Does it match exactly? (yes/no) " answer </dev/tty || answer=""
    [[ $answer == yes ]] || die "not confirmed; not pairing"
  fi

  [[ -e $BRIDGE_KEY ]] || ssh-keygen -q -t ed25519 -N "" -C "typeless-bridge" -f "$BRIDGE_KEY"

  local alias="typeless-bridge-$name"
  touch "$known"; chmod 600 "$known"
  ssh-keygen -R "$alias" -f "$known" >/dev/null 2>&1 || true
  printf '%s %s\n' "$alias" "$(printf '%s\n' "$scanned" | cut -d' ' -f2-)" >> "$known"

  touch "$config"; chmod 600 "$config"
  remove_block "$name" "$config"
  { block_begin "$name"
    echo "Host $name"
    echo "  HostName $host"
    echo "  User $user"
    echo "  IdentityFile $BRIDGE_KEY"
    echo "  IdentitiesOnly yes"
    echo "  HostKeyAlias $alias"
    echo "  StrictHostKeyChecking yes"
    block_end "$name"; } >> "$config"
  say "added Host $name to $config"

  if ! ssh -T -o BatchMode=yes -o ConnectTimeout=5 "$name" true </dev/null 2>/dev/null; then
    say "copying the bridge key to $name; enter the password of $user on that Mac"
    ssh-copy-id -i "$BRIDGE_KEY.pub" "$name" || die "could not copy the key to $name"
  fi
  remote_check "$name"
}

cmd_unpair() {
  local name=${1:-}
  valid_name "$name" || die "usage: unpair NAME"
  grep -qxF "$(block_begin "$name")" "$SSH_DIR/config" 2>/dev/null || die "$name was not paired by this script"
  remove_block "$name" "$SSH_DIR/config"
  ssh-keygen -R "typeless-bridge-$name" -f "$SSH_DIR/known_hosts" >/dev/null 2>&1 || true
  say "removed Host $name. Its key stays in ~/.ssh/authorized_keys on that Mac (comment: typeless-bridge)."
}

cmd_status() {
  [[ -e "$ROOT/manifest" ]] || { echo "not installed"; return 0; }
  grep '^options' "$ROOT/manifest"
  grep '^version' "$ROOT/manifest" || true
  local kind value
  while read -r kind value; do
    [[ $kind == agent ]] || continue
    if loaded "$value"; then
      echo "$value: $("$LAUNCHCTL" print "$DOMAIN/$value" | awk '/^\tstate =/{s=$3} /^\tpid =/{p=$3} END{print "state=" s, "pid=" (p?p:"-")}')"
    else
      echo "$value: not loaded"
    fi
  done < "$ROOT/manifest"
  if grep -q "^agent $RECEIVER_LABEL" "$ROOT/manifest"; then
    echo "receiver health: $(receiver_health)"
  fi
  if [[ -e "$LOGS/sender.log" ]]; then
    echo "sender log (last 3):"; tail -3 "$LOGS/sender.log" | sed 's/^/   /'
  fi
}

case "${1:-}" in
  install) shift; cmd_install "$@" ;;
  uninstall) shift; cmd_uninstall "$@" ;;
  configure) shift; cmd_configure "$@" ;;
  status) shift; cmd_status ;;
  pair) shift; cmd_pair "$@" ;;
  unpair) shift; cmd_unpair "$@" ;;
  *) sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
