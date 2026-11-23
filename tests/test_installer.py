"""Isolated tests for install/typeless-bridge.sh.

Runs the installer with a temporary HOME, a stub launchctl and tiny ad-hoc-signed fake apps.
Never touches the real LaunchAgents, apps or Typeless data. Sender tests are skipped because
they need a working ssh alias; the sender plist is checked through the receiver+sender path
only when TB_TEST_SSH_DEST is set.
"""
import os
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "install" / "typeless-bridge.sh"
STUB = """#!/bin/bash
echo "$*" >> "$TB_STUB_DIR/calls"
case $1 in
  print) [[ -e "$TB_STUB_DIR/loaded.${2##*/}" ]] ;;
  bootstrap) touch "$TB_STUB_DIR/loaded.$(basename "$3" .plist)" ;;
  bootout) rm -f "$TB_STUB_DIR/loaded.${2##*/}" ;;
esac
"""
APPS = ("TypelessBridgeProbe", "TypelessBridgeGuard", "TypelessBridgeReceiver")


class InstallerTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.apps = Path(tempfile.mkdtemp(prefix="tb-apps-"))
        for name in APPS:
            macos = cls.apps / f"{name}.app" / "Contents" / "MacOS"
            macos.mkdir(parents=True)
            exe = macos / name
            exe.write_text("#!/bin/sh\nexit 0\n"); exe.chmod(0o755)
            (macos.parent / "Info.plist").write_bytes(plistlib.dumps(
                {"CFBundleExecutable": name, "CFBundleIdentifier": f"test.{name}",
                 "CFBundlePackageType": "APPL"}))
            subprocess.run(["codesign", "--force", "--sign", "-", str(macos.parent.parent)],
                           check=True, capture_output=True)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.apps)

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="tb-home-"))
        self.home = self.tmp / "home"
        (self.home / "Library/Application Support/Typeless").mkdir(parents=True)
        (self.home / "Library/Application Support/Typeless/typeless.db").touch()
        stub = self.tmp / "launchctl"
        stub.write_text(STUB); stub.chmod(0o755)
        self.env = dict(os.environ, HOME=str(self.home), TB_LAUNCHCTL=str(stub),
                        TB_STUB_DIR=str(self.tmp), PYTHONDONTWRITEBYTECODE="1")
        self.root = self.home / "Library/Application Support/TypelessRemoteBridge"
        self.agents = self.home / "Library/LaunchAgents"

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def run_script(self, *args):
        return subprocess.run(["bash", str(SCRIPT), *args], env=self.env,
                              capture_output=True, text=True)

    def calls(self):
        path = self.tmp / "calls"
        return [l for l in path.read_text().splitlines() if not l.startswith("print")] if path.exists() else []

    def test_requires_a_role(self):
        r = self.run_script("install", "--apps-dir", str(self.apps))
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("nothing to install", r.stderr)

    def test_rejects_unknown_destination(self):
        r = self.run_script("install", "--sender", "hub,mars", "--apps-dir", str(self.apps))
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("mars", r.stderr)
        self.assertFalse(self.root.exists())

    def test_rejects_unsafe_destination_names(self):
        for bad in ("Hub", "local", "-oProxyCommand=x", "a b", "hub,hub"):
            r = self.run_script("install", "--sender", bad, "--apps-dir", str(self.apps))
            self.assertNotEqual(r.returncode, 0, bad)
            self.assertFalse(self.root.exists())

    def test_option_without_value_explains(self):
        r = self.run_script("install", "--sender")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("--sender needs a value", r.stderr)

    def test_rejects_duplicate_destination(self):
        r = self.run_script("install", "--sender", "hub,hub", "--apps-dir", str(self.apps))
        self.assertIn("duplicate", r.stderr)

    def test_receiver_install_status_uninstall_round_trip(self):
        r = self.run_script("install", "--receiver", "--apps-dir", str(self.apps))
        self.assertEqual(r.returncode, 0, r.stderr)
        plist = plistlib.loads((self.agents / "org.local.typelessbridge.receiver.plist").read_bytes())
        self.assertEqual(plist["KeepAlive"], {"SuccessfulExit": False})
        self.assertEqual(plist["LimitLoadToSessionType"], "Aqua")
        self.assertTrue(plist["ProgramArguments"][0].startswith(str(self.root / "Apps")))
        self.assertTrue((self.root / "Apps/TypelessBridgeReceiver.app").is_dir())
        self.assertFalse((self.root / "Apps/TypelessBridgeGuard.app").exists())
        self.assertIn("bootstrap", self.calls()[0])

        again = self.run_script("install", "--receiver", "--apps-dir", str(self.apps))
        self.assertIn("already installed", again.stderr)

        status = self.run_script("status")
        self.assertIn("org.local.typelessbridge.receiver", status.stdout)

        state = self.home / ".local/state/typeless-remote-bridge"
        state.mkdir(parents=True); (state / "consumed.json").write_text("{}")
        u = self.run_script("uninstall")
        self.assertEqual(u.returncode, 0, u.stderr)
        self.assertFalse(self.root.exists())
        self.assertFalse((self.agents / "org.local.typelessbridge.receiver.plist").exists())
        self.assertFalse((self.home / "Library/Logs/TypelessRemoteBridge").exists())
        self.assertTrue(state.exists(), "state kept without --purge-state")
        self.assertIn("bootout gui/", self.calls()[-1])

    def test_uninstall_forgets_device_control_entries(self):
        stub = self.tmp / "tccutil"
        stub.write_text('#!/bin/bash\necho "$*" >> "$TB_STUB_DIR/tcc"\n'); stub.chmod(0o755)
        self.env["TB_TCCUTIL"] = str(stub)
        self.assertEqual(self.run_script("install", "--receiver", "--apps-dir", str(self.apps)).returncode, 0)
        r = self.run_script("uninstall")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual((self.tmp / "tcc").read_text().splitlines(),
                         ["reset Accessibility test.TypelessBridgeReceiver"])

    def tcc_stub(self):
        stub = self.tmp / "tccutil"
        stub.write_text('#!/bin/bash\necho "$*" >> "$TB_STUB_DIR/tcc"\n'); stub.chmod(0o755)
        self.env["TB_TCCUTIL"] = str(stub)
        return self.tmp / "tcc"

    def test_configure_adds_and_removes_roles_keeping_permissions(self):
        tcc = self.tcc_stub()
        r = self.run_script("configure", "--receiver", "on", "--apps-dir", str(self.apps))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("receiver=1", (self.root / "manifest").read_text())
        version = (Path(__file__).resolve().parent.parent / "VERSION").read_text().strip()
        self.assertIn(f"version {version}\n", (self.root / "manifest").read_text())
        self.assertIn(f"version {version}", self.run_script("status").stdout)
        r = self.run_script("configure", "--receiver", "on", "--apps-dir", str(self.apps))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertFalse(tcc.exists(), "a reconfigure must not reset approvals")
        r = self.run_script("configure", "--receiver", "off")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertFalse((self.root / "manifest").exists())
        self.assertTrue(tcc.exists(), "removing the last role is a real uninstall")

    def test_configure_checks_before_touching_the_working_install(self):
        self.assertEqual(self.run_script("install", "--receiver", "--apps-dir", str(self.apps)).returncode, 0)
        before = (self.root / "manifest").read_text()
        r = self.run_script("configure", "--add-sender", "no-such-mac-xyz", "--apps-dir", str(self.apps))
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual((self.root / "manifest").read_text(), before)
        self.assertTrue((self.agents / "org.local.typelessbridge.receiver.plist").exists())

    def test_uninstall_keep_permissions(self):
        tcc = self.tcc_stub()
        self.run_script("install", "--receiver", "--apps-dir", str(self.apps))
        self.assertEqual(self.run_script("uninstall", "--keep-permissions").returncode, 0)
        self.assertFalse(tcc.exists())

    def test_purge_state_removes_receiver_journal(self):
        self.run_script("install", "--receiver", "--apps-dir", str(self.apps))
        state = self.home / ".local/state/typeless-remote-bridge"
        state.mkdir(parents=True)
        self.run_script("uninstall", "--purge-state")
        self.assertFalse(state.exists())

    def test_failed_install_explains_recovery(self):
        stub = Path(self.env["TB_LAUNCHCTL"])
        stub.write_text(STUB.replace("  bootstrap) touch", "  bootstrap) exit 5; touch"))
        r = self.run_script("install", "--receiver", "--apps-dir", str(self.apps))
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("install failed part-way", r.stderr)
        self.assertIn("uninstall", r.stderr)

    def test_uninstall_when_not_installed(self):
        r = self.run_script("uninstall")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("not installed", r.stderr)

    @unittest.skipUnless(os.environ.get("TB_TEST_SSH_DEST"), "needs a working ssh alias")
    def test_sender_plist(self):
        dest = os.environ["TB_TEST_SSH_DEST"]
        r = self.run_script("install", "--sender", dest, "--apps-dir", str(self.apps))
        self.assertEqual(r.returncode, 0, r.stderr)
        plist = plistlib.loads((self.agents / "org.local.typelessbridge.sender.plist").read_bytes())
        self.assertIs(plist["KeepAlive"], True)
        args = plist["ProgramArguments"]
        self.assertEqual(args[args.index("--destinations") + 1], dest)
        self.assertEqual(args[args.index("--lock-file") + 1], str(self.root / "sender.lock"))
        self.assertEqual(args[args.index("--identities-file") + 1], str(self.root / "identities.json"))
        self.assertNotIn("--service", args)
        self.assertTrue(args[2].endswith("/service/sender.py"))
        for name in ("sender.py", "watcher.py", "completion_dispatch.py", "completion_routing.py"):
            self.assertTrue((self.root / "service" / name).exists())


if __name__ == "__main__":
    unittest.main()


SSH_STUB = """#!/bin/bash
# Stub ssh: works without a password only once ssh-copy-id has "installed" the key.
echo "ssh $*" >> "$TB_STUB_DIR/ssh-calls"
last="${@: -1}"
[[ -e "$TB_STUB_DIR/authorized" ]] || exit 255
case $last in
  true) exit 0 ;;
  *health*) echo '{"status":"ready"}' ;;
esac
"""
COPY_STUB = """#!/bin/bash
echo "ssh-copy-id $*" >> "$TB_STUB_DIR/ssh-calls"
touch "$TB_STUB_DIR/authorized"
"""
KEYSCAN_STUB = """#!/bin/bash
echo "$2 $(cat "$TB_STUB_DIR/hostkey.pub" | cut -d' ' -f1-2)" | sed "s/^[^ ]* /$6 /"
"""


class PairTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="tb-pair-"))
        self.home = self.tmp / "home"
        self.home.mkdir()
        bin_dir = self.tmp / "bin"
        bin_dir.mkdir()
        for name, body in (("ssh", SSH_STUB), ("ssh-copy-id", COPY_STUB), ("ssh-keyscan", KEYSCAN_STUB)):
            (bin_dir / name).write_text(body); (bin_dir / name).chmod(0o755)
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(self.tmp / "hostkey")], check=True)
        self.fingerprint = subprocess.run(["ssh-keygen", "-lf", str(self.tmp / "hostkey.pub")], check=True,
                                          capture_output=True, text=True).stdout.split()[1]
        self.env = dict(os.environ, HOME=str(self.home), TB_STUB_DIR=str(self.tmp),
                        PATH=f"{bin_dir}:{os.environ['PATH']}")
        self.config = self.home / ".ssh/config"
        self.known = self.home / ".ssh/known_hosts"

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def run_script(self, *args):
        return subprocess.run(["bash", str(SCRIPT), *args], env=self.env, capture_output=True, text=True,
                              stdin=subprocess.DEVNULL)

    def test_pair_writes_alias_key_and_host_key(self):
        r = self.run_script("pair", "studio", "alice@studio.local", "--fingerprint", self.fingerprint)
        self.assertEqual(r.returncode, 0, r.stderr)
        config = self.config.read_text()
        for line in ("Host studio", "HostName studio.local", "User alice", "IdentitiesOnly yes",
                     "HostKeyAlias typeless-bridge-studio", "StrictHostKeyChecking yes"):
            self.assertIn(line, config)
        self.assertTrue((self.home / ".ssh/typeless_bridge_ed25519").exists())
        self.assertTrue(self.known.read_text().startswith("typeless-bridge-studio ssh-ed25519 "))
        self.assertIn("ssh-copy-id", (self.tmp / "ssh-calls").read_text())
        self.assertIn("receiver is ready", r.stdout)
        self.assertEqual(self.config.stat().st_mode & 0o777, 0o600)

    def test_wrong_fingerprint_changes_nothing(self):
        r = self.run_script("pair", "studio", "alice@studio.local", "--fingerprint", "SHA256:wrong")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("not pairing", r.stderr)
        self.assertFalse(self.config.exists() and "Host studio" in self.config.read_text())
        self.assertFalse((self.home / ".ssh/typeless_bridge_ed25519").exists())

    def test_unconfirmed_without_fingerprint_refuses(self):
        r = self.run_script("pair", "studio", "alice@studio.local")
        self.assertNotEqual(r.returncode, 0)
        self.assertFalse(self.config.exists() and "Host studio" in self.config.read_text())

    def test_existing_user_alias_is_left_alone(self):
        self.config.parent.mkdir()
        self.config.write_text("Host studio\n  HostName 192.0.2.5\n")
        (self.tmp / "authorized").touch()
        r = self.run_script("pair", "studio", "alice@studio.local", "--fingerprint", self.fingerprint)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.config.read_text(), "Host studio\n  HostName 192.0.2.5\n")
        self.assertIn("already in", r.stdout)

    def test_repair_replaces_block_and_unpair_removes_it(self):
        self.config.parent.mkdir()
        self.config.write_text("Host other\n  HostName 192.0.2.9\n")
        for _ in range(2):
            r = self.run_script("pair", "studio", "alice@studio.local", "--fingerprint", self.fingerprint)
            self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.config.read_text().count("Host studio"), 1)
        self.assertEqual(self.known.read_text().count("typeless-bridge-studio"), 1)
        r = self.run_script("unpair", "studio")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.config.read_text(), "Host other\n  HostName 192.0.2.9\n")
        self.assertNotIn("typeless-bridge-studio", self.known.read_text())
        self.assertNotEqual(self.run_script("unpair", "studio").returncode, 0)

    def test_damaged_block_leaves_the_config_alone(self):
        self.config.parent.mkdir()
        damaged = "# >>> typeless-bridge studio\nHost studio\n  HostName x\nHost mine\n  HostName 192.0.2.7\n"
        self.config.write_text(damaged)
        r = self.run_script("unpair", "studio")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("no end marker", r.stderr)
        self.assertEqual(self.config.read_text(), damaged)

    def test_symlinked_config_stays_a_symlink(self):
        dotfiles = self.home / "dotfiles"; dotfiles.mkdir()
        real = dotfiles / "ssh_config"; real.write_text("Host other\n  HostName 192.0.2.9\n")
        self.config.parent.mkdir(); self.config.symlink_to(real)
        r = self.run_script("pair", "studio", "alice@studio.local", "--fingerprint", self.fingerprint)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(self.config.is_symlink())
        self.assertIn("Host studio", real.read_text())
        self.assertEqual(self.run_script("unpair", "studio").returncode, 0)
        self.assertTrue(self.config.is_symlink())
        self.assertEqual(real.read_text(), "Host other\n  HostName 192.0.2.9\n")

    def test_rejects_bad_names_and_targets(self):
        for args in (("pair", "Studio", "alice@h"), ("pair", "studio", "nouser"), ("pair", "studio", "a@b;rm"),
                     ("pair", "local", "a@b")):
            self.assertNotEqual(self.run_script(*args).returncode, 0, args)
