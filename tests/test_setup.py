"""Scripted runs of the setup wizard with stubbed system commands and a fake HOME.

Never touches real apps, settings, ssh or launchd: the engine, builder, open, dns-sd, ssh,
ssh-keyscan, scutil, xcrun, tccutil and launchctl are stubs. The ssh stub plays the remote Mac.
Answers come from a file instead of the terminal.
"""
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SETUP = REPO / "setup"

STUBS = {
    "open": r"""#!/bin/bash
echo "open $*" >> "$STUB/calls"
out=""; prev=""
for a in "$@"; do [[ $prev == --stdout ]] && out=$a; prev=$a; done
[[ " $* " == *" --check-trust "* && -n $out ]] && cat "$STUB/trust_local" > "$out"
# The user switches the apps on a while after Settings opened.
[[ $* == *Privacy_Accessibility* ]] && (sleep "${GRANT_DELAY:-2}"; echo trusted > "$STUB/trust_local") &
exit 0
""",
    "xcrun": "#!/bin/bash\nexit 0\n",
    "scutil": "#!/bin/bash\necho Core\n",
    "dns-sd": r"""#!/bin/bash
if [[ $1 == -B ]]; then
  echo "Timestamp     A/R    Flags  if Domain               Service Type         Instance Name"
  echo "10:00:00.000  Add        3  14 local.               _rfb._tcp.           Core"
  echo " 9:00:00.000  Add        3  14 local.               _rfb._tcp.           Studio Mac"   # before 10:00: padded
else
  echo "10:00:01.000  $2._rfb._tcp.local. can be reached at studio.local.:5900 (interface 14)"
fi
""",
    "ssh-keyscan": r"""#!/bin/bash
echo "studio.local $(cut -d' ' -f1-2 "$STUB/hostkey.pub")"
""",
    "ssh": r"""#!/bin/bash
args=("$@"); i=0
while [[ ${args[$i]} == -* ]]; do [[ ${args[$i]} == -o ]] && i=$((i + 2)) || i=$((i + 1)); done
host=${args[$i]}; cmd="${args[*]:$((i + 1))}"
echo "ssh $host $cmd" >> "$STUB/calls"
[[ -n ${UNREACHABLE:-} ]] && exit 255
case $cmd in
  true) [[ -e "$STUB/paired" ]] ;;
  *"scutil --get ComputerName"*) echo "${REMOTE_NAME:-Studio Mac}" ;;
  *"tar -C"*) cat > /dev/null ;;
  *--check-trust*) grep -qx trusted "$STUB/trust_remote" || echo TypelessBridgeReceiver ;;
  *"nc -U"*) cat > /dev/null; echo '{"status":"ready"}' ;;
  *"s/^version //p"*) echo "${REMOTE_VERSION:-}" ;;
  *Privacy_Accessibility*) (sleep "${GRANT_DELAY:-2}"; echo trusted > "$STUB/trust_remote") & ;;
  *) : ;;
esac
""",
    "engine": r"""#!/bin/bash
echo "engine $*" >> "$STUB/calls"
root="$HOME/Library/Application Support/TypelessRemoteBridge"; m="$root/manifest"
dests=$(sed -n 's/^options .*sender=\([^ ]*\).*/\1/p' "$m" 2>/dev/null); [[ $dests == none ]] && dests=""
rec=$(sed -n 's/^options .*receiver=\([^ ]*\).*/\1/p' "$m" 2>/dev/null); rec=${rec:-0}
case $1 in
  pair) [[ -n ${FAIL_PAIR:-} ]] && exit 1
        echo "askpass=${SSH_ASKPASS_REQUIRE:-}:${TB_PASSWORD:-}" >> "$STUB/calls"; touch "$STUB/paired" ;;
  configure) shift
    while (($#)); do case $1 in
      --add-sender) dests="${dests:+$dests,}$2"; shift 2 ;;
      --remove-sender) dests=$(printf '%s' "$dests" | tr ',' '\n' | grep -vx "$2" | paste -sd, -); shift 2 ;;
      *) shift 2 ;; esac; done
    mkdir -p "$root"
    if [[ -n $dests || $rec == 1 ]]; then echo "options sender=${dests:-none} receiver=$rec" > "$m"; else rm -f "$m"; fi
    rm -rf "$root/Apps"; mkdir -p "$root/Apps"
    [[ -n $dests ]] && mkdir -p "$root/Apps/TypelessBridgeGuard.app" "$root/Apps/TypelessBridgeProbe.app"
    [[ $rec == 1 ]] && mkdir -p "$root/Apps/TypelessBridgeReceiver.app"
    true ;;
esac
exit 0
""",
    "builder": "#!/bin/bash\nmkdir -p \"$1\"\n",
    "tccutil": "#!/bin/bash\necho \"tccutil $*\" >> \"$STUB/calls\"\n",
    "launchctl": r"""#!/bin/bash
echo "launchctl $*" >> "$STUB/calls"
if [[ $* == *typelessbridge.sender* ]]; then
  log="$HOME/Library/Logs/TypelessRemoteBridge/sender.log"; mkdir -p "$(dirname "$log")"
  echo "PILOT_READY" >> "$log"
  # The user "speaks" every second for a while, so a slow machine cannot miss the only sentence.
  (for _ in $(seq 1 30); do sleep 1; [ -d "$(dirname "$log")" ] || exit 0
     printf 'TARGET studio-mac\nRESULT paste-sent-unconfirmed\n' >> "$log"; done) >/dev/null 2>&1 &
fi
""",
}


class StubbedMac(unittest.TestCase):
    """Fake HOME and stubbed system commands; no tests of its own."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="tb-setup-"))
        self.home = self.tmp / "home"
        (self.home / "Library/Application Support/Typeless").mkdir(parents=True)
        (self.home / "Library/Application Support/Typeless/typeless.db").touch()
        bin_dir = self.tmp / "bin"; bin_dir.mkdir()
        for name, body in STUBS.items():
            path = bin_dir / name; path.write_text(body); path.chmod(0o755)
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(self.tmp / "hostkey")], check=True)
        (self.tmp / "trust_local").write_text("trusted\n")
        (self.tmp / "trust_remote").write_text("trusted\n")
        self.env = dict(os.environ, HOME=str(self.home), STUB=str(self.tmp), PATH=f"{bin_dir}:{os.environ['PATH']}",
                        TB_ENGINE=str(bin_dir / "engine"), TB_BUILDER=str(bin_dir / "builder"),
                        TB_LAUNCHCTL=str(bin_dir / "launchctl"), TB_TCCUTIL=str(bin_dir / "tccutil"),
                        TB_LANG="en", TB_HINT_AFTER="2")

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def run_setup(self, answers, **env):
        (self.tmp / "answers").write_text(answers)
        env = dict(self.env, TB_TTY=str(self.tmp / "answers"), **env)
        return subprocess.run(["bash", str(SETUP)], env=env, capture_output=True, text=True, timeout=90,
                              errors="replace")

    def calls(self):
        path = self.tmp / "calls"
        return path.read_text().splitlines() if path.exists() else []

    def installed_with(self, dests):
        root = self.home / "Library/Application Support/TypelessRemoteBridge"; root.mkdir(parents=True)
        (root / "manifest").write_text(f"options sender={dests} receiver=0\n")


class SetupWizard(StubbedMac):
    def test_add_a_mac_end_to_end(self):
        r = self.run_setup("1\n")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("1) Studio Mac", r.stdout)
        self.assertNotIn(") Core", r.stdout)                       # this Mac is not offered
        self.assertNotIn("Pairing code", r.stdout)                  # nothing to compare by eye
        calls = self.calls()
        self.assertTrue(any(c.startswith("engine pair studio-mac") and "@studio.local --fingerprint SHA256:" in c
                            for c in calls))
        self.assertTrue(any("configure --receiver on" in c for c in calls if c.startswith("ssh studio-mac")))
        self.assertTrue(any(c.startswith("engine configure --add-sender studio-mac") for c in calls))
        self.assertIn("Delivered to Studio Mac", r.stdout)
        self.assertFalse(any(c.startswith("tccutil") for c in calls))   # approvals already valid: untouched

    def test_remote_permission_is_given_through_screen_sharing(self):
        (self.tmp / "trust_remote").write_text("untrusted\n")
        r = self.run_setup("1\n")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("Switch to the Screen Sharing window of Studio Mac", r.stdout)
        calls = self.calls()
        self.assertTrue(any("tccutil reset Accessibility" in c and "TypelessBridgeReceiver.app" in c
                            for c in calls if c.startswith("ssh studio-mac")))
        self.assertTrue(any("Privacy_Accessibility" in c for c in calls if c.startswith("ssh studio-mac")))

    def test_local_permission_clears_stale_approvals_and_waits(self):
        (self.tmp / "trust_local").write_text("untrusted\n")
        r = self.run_setup("1\n\n")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(sum(c.startswith("tccutil reset Accessibility") for c in self.calls()), 2)
        self.assertIn("background item", r.stdout)
        self.assertIn("Allowed on this Mac", r.stdout)

    def test_mac_that_is_also_a_receiver_rechecks_its_receiver(self):
        root = self.home / "Library/Application Support/TypelessRemoteBridge"; root.mkdir(parents=True)
        (root / "manifest").write_text("options sender=none receiver=1\n")
        (self.tmp / "trust_local").write_text("untrusted\n")
        r = self.run_setup("1\n\n")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("• TypelessBridgeReceiver", r.stdout)
        self.assertEqual(sum(c.startswith("tccutil reset Accessibility") for c in self.calls()), 3)

    def test_hint_when_waiting_long(self):
        (self.tmp / "trust_remote").write_text("untrusted\n")
        r = self.run_setup("1\n", GRANT_DELAY="16")
        self.assertIn("If you cannot find them", r.stdout)

    def test_wrong_machine_stops_before_installing(self):
        r = self.run_setup("1\n", REMOTE_NAME="Somebody Else")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('Reached "Somebody Else", not "Studio Mac"', r.stderr)
        calls = self.calls()
        self.assertIn("engine unpair studio-mac", calls)
        self.assertFalse(any("configure" in c for c in calls))

    def test_menu_marks_added_macs_and_refuses_them_again(self):
        self.installed_with("studio-mac")
        r = self.run_setup("a\n1\n")
        self.assertIn("Already controlling: studio-mac", r.stdout)
        self.assertIn("Studio Mac  (already added)", r.stdout)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("already added", r.stderr)

    def test_remove_a_mac(self):
        self.installed_with("studio-mac,office")
        r = self.run_setup("r\n1\n\n")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        calls = self.calls()
        self.assertIn("engine configure --remove-sender studio-mac", calls)
        self.assertTrue(any(c.startswith("ssh studio-mac") and "configure --receiver off" in c for c in calls))
        self.assertIn("engine unpair studio-mac", calls)

    def test_upgrade_updates_remote_then_local(self):
        self.installed_with("studio-mac")
        r = self.run_setup("u\n")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        calls = self.calls()
        remote = next(i for i, c in enumerate(calls) if c.startswith("ssh studio-mac") and "configure --receiver on" in c)
        local = next(i for i, c in enumerate(calls) if c.startswith("engine configure --apps-dir"))
        self.assertLess(remote, local)

    def test_uninstall_everything(self):
        self.installed_with("studio-mac")
        r = self.run_setup("x\n\n")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        calls = self.calls()
        self.assertTrue(any(c.startswith("ssh studio-mac") and "configure --receiver off" in c for c in calls))
        self.assertIn("engine configure --remove-sender studio-mac", calls)

    def test_without_typeless_explains_where_to_run(self):
        (self.home / "Library/Application Support/Typeless/typeless.db").unlink()
        r = self.run_setup("1\n")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("Run this on the Mac you talk to", r.stderr)

    def test_chinese(self):
        r = self.run_setup("1\n", TB_LANG="zh")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("这个终端窗口就是安装向导", r.stdout)
        self.assertIn("已送达 Studio Mac", r.stdout)

    def test_helpers(self):
        out = subprocess.run(["bash", "-c", 'TB_SETUP_LIBRARY=1 source "$0"; slug "Alice’s Mac Studio!!"; echo;'
                              ' same_name Hub hub && echo same', str(SETUP)], capture_output=True, text=True).stdout
        self.assertEqual(out.split(), ["alice-s-mac-studio", "same"])



class StepMode(StubbedMac):
    """setup --step …: the non-interactive steps the setup window calls."""

    def step(self, *args, **env):
        e = dict(self.env, **env)
        return subprocess.run(["bash", str(SETUP), "--step", *args], env=e, capture_output=True, text=True, timeout=60)

    def test_preflight(self):
        out = self.step("preflight").stdout
        for line in ("typeless=1", "tools=1", "python=1", "version="):
            self.assertIn(line, out)

    def test_versions_reports_downloaded_local_and_remote(self):
        self.installed_with("studio-mac")
        manifest = self.home / "Library/Application Support/TypelessRemoteBridge/manifest"
        manifest.write_text(manifest.read_text() + "version 1.0.0\n")
        available = (REPO / "VERSION").read_text().strip()
        out = self.step("versions", REMOTE_VERSION="0.9.2").stdout
        self.assertEqual(out, f"available={available}\nlocal=1.0.0\nremote studio-mac=0.9.2\n")
        out = self.step("versions", UNREACHABLE="1").stdout
        self.assertIn("remote studio-mac=unreachable\n", out)

    def test_versions_before_they_were_recorded_are_empty(self):
        self.installed_with("studio-mac")
        out = self.step("versions").stdout
        self.assertIn("local=\n", out)
        self.assertIn("remote studio-mac=\n", out)

    def test_discover_marks_added(self):
        self.installed_with("studio-mac")
        self.assertEqual(self.step("discover").stdout, "Studio Mac\tstudio.local\tadded\n")

    def test_connect_passes_password_only_through_askpass(self):
        r = self.step("connect", "Studio Mac", "studio.local", "alice", TB_PASSWORD="s3cret")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("dest=studio-mac", r.stdout)
        self.assertNotIn("s3cret", r.stdout + r.stderr)
        self.assertIn("askpass=force:s3cret", self.calls())

    def test_connect_login_failure(self):
        r = self.step("connect", "Studio Mac", "studio.local", "alice", FAIL_PAIR="1")
        self.assertEqual((r.returncode, r.stdout.strip()), (2, "error=login"))

    def test_connect_wrong_machine(self):
        r = self.step("connect", "Studio Mac", "studio.local", "alice", "check-name", REMOTE_NAME="Other Mac")
        self.assertEqual(r.returncode, 3)
        self.assertIn("remote=Other Mac", r.stdout)
        self.assertIn("engine unpair studio-mac", self.calls())

    def test_manual_address_skips_the_name_check(self):
        r = self.step("connect", "studio", "studio.local", "alice", REMOTE_NAME="Studio Mac")
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertIn("dest=studio", r.stdout)

    def test_name_check_ignores_apostrophes_and_bonjour_suffix(self):
        r = self.step("connect", "Alice’s Mac (2)", "studio.local", "alice", "check-name", REMOTE_NAME="Alice's Mac")
        self.assertEqual(r.returncode, 0, r.stdout)

    def test_chinese_and_address_names_get_distinct_destinations(self):
        r = self.step("connect", "我的电脑", "wodediannao.local", "alice")
        self.assertIn("dest=wodediannao", r.stdout)
        r = self.step("connect", "我的电脑", "192.0.2.20", "alice")
        self.assertIn("dest=mac-192-0-2-20", r.stdout)

    def test_already_added_and_bad_address(self):
        self.installed_with("studio-mac")
        self.assertEqual(self.step("connect", "Studio Mac", "studio.local", "alice").returncode, 5)
        self.assertEqual(self.step("connect", "x", "-oProxyCommand=evil", "alice").returncode, 6)
        self.assertEqual(self.step("ssh-open", "-oProxyCommand=evil").returncode, 3)

    def test_remove_reports_an_unreachable_remote(self):
        self.installed_with("studio-mac")
        r = self.step("remove", "studio-mac", "--remote", UNREACHABLE="1")
        self.assertEqual(r.returncode, 0)
        self.assertIn("unreachable=studio-mac", r.stdout)

    def test_typed_name_that_does_not_resolve(self):
        self.assertEqual(self.step("ssh-open", "no-such-mac-xyz.invalid").returncode, 3)
        # a discovered host is never rejected for not resolving (ssh-keyscan decides)
        self.assertNotEqual(self.step("ssh-open", "no-such-mac-xyz.invalid", "discovered").returncode, 3)

    def test_own_alias_pointing_elsewhere_is_refused(self):
        ssh_dir = self.home / ".ssh"; ssh_dir.mkdir()
        (ssh_dir / "config").write_text("Host studio\n  HostName 192.0.2.99\n")
        r = self.step("connect", "studio", "studio.local", "alice", REMOTE_NAME="Somewhere Else")
        self.assertEqual(r.returncode, 7, r.stdout)
        self.assertIn("error=alias-conflict", r.stdout)

    def test_remote_prepare_lists_what_to_switch_on(self):
        (self.tmp / "trust_remote").write_text("untrusted\n")
        r = self.step("remote-prepare", "studio-mac")
        self.assertIn("missing=TypelessBridgeReceiver", r.stdout)

    def test_test_result(self):
        log = self.home / "Library/Logs/TypelessRemoteBridge/sender.log"; log.parent.mkdir(parents=True)
        log.write_text("PILOT_READY\n")
        self.assertEqual(self.step("test-result", "1").stdout.strip(), "none")
        log.write_text("PILOT_READY\nTARGET local\nRESULT local\n")
        self.assertEqual(self.step("test-result", "1").stdout.strip(), "local")
        log.write_text("PILOT_READY\nTARGET local\nRESULT local\nRESULT paste-sent-unconfirmed\n")
        self.assertEqual(self.step("test-result", "3").stdout.strip(), "delivered")

    def test_local_missing_lists_untrusted_apps(self):
        (self.tmp / "trust_local").write_text("untrusted\n")
        apps = self.home / "Library/Application Support/TypelessRemoteBridge/Apps"
        for name in ("TypelessBridgeGuard", "TypelessBridgeProbe"):
            (apps / f"{name}.app").mkdir(parents=True)
        self.assertEqual(self.step("local-missing").stdout.split(), ["TypelessBridgeGuard", "TypelessBridgeProbe"])

    def test_unknown_step(self):
        self.assertEqual(self.step("nope").returncode, 64)

class Bootstrap(unittest.TestCase):
    def test_install_sh_fetches_code_and_replaces_an_old_copy(self):
        home = Path(tempfile.mkdtemp(prefix="tb-boot-"))
        try:
            dest = home / ".local/share/typeless-remote-bridge"
            dest.mkdir(parents=True); (dest / "stale-file").write_text("old")
            env = dict(os.environ, HOME=str(home), TB_TARBALL=str(REPO), TB_NO_SETUP="1")
            r = subprocess.run(["bash", str(REPO / "install.sh")], env=env, capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertTrue((dest / "setup").exists() and (dest / "install/typeless-bridge.sh").exists())
            self.assertFalse((dest / "stale-file").exists())
        finally:
            shutil.rmtree(home)


if __name__ == "__main__":
    unittest.main()
