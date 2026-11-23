"""Screen Sharing Bridge for Typeless: sender (LaunchAgent org.local.typelessbridge.sender).

Starts the paste guard, keeps its heartbeat fresh, and delivers each new local Typeless
dictation to the configured remote Mac whose Screen Sharing window is in front.
Transcripts never go to logs, notifications or command arguments.
"""
import argparse
import fcntl
import os
import signal
import sqlite3
import stat
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import identities  # noqa: E402
import watcher  # noqa: E402
from completion_dispatch import CompletionDispatcher  # noqa: E402
from completion_routing import valid_destination  # noqa: E402

DB = Path.home() / "Library/Application Support/Typeless/typeless.db"
# Results that mean the text did not reach the remote Mac. The user is not notified: the guard
# then leaves Typeless' copy popup open, which is the same sign Typeless itself gives.
UNDELIVERED = {"target-changed", "delivery-unconfirmed", "rejected", "no-active-session",
               "secure-field", "frontmost-changed", "journal-unavailable",
               "clipboard-write-failed", "event-unavailable", "already-consumed"}


class ShutdownRequested(BaseException):
    pass


def install_shutdown_handlers():
    def request_shutdown(_signum, _frame):
        raise ShutdownRequested()
    signal.signal(signal.SIGTERM, request_shutdown)
    signal.signal(signal.SIGINT, request_shutdown)


def acquire_instance_lock(path):
    fd = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise RuntimeError("unsafe lock file")
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return fd
    except BaseException:
        os.close(fd)
        raise


def guard_status(output):
    states = set(output.splitlines())
    if states.intersection({"NOT_READY", "TAP_UNAVAILABLE"}):
        return "failed"
    return "ready" if "READY" in states else "waiting"


def new_guard_lines(output, seen):
    """The guard's complete output lines after the first `seen`, and the new line count."""
    lines = output.split("\n")[:-1]
    return lines[seen:], len(lines)


# Results that close a paste the guard swallowed: the text went out, or the user was told.
CLOSES_SUPPRESSION = {"paste-sent-unconfirmed"} | UNDELIVERED
# A suppressed paste must meet such a result within this time (SSH can take up to 15 s).
SUPPRESSION_WINDOW = 20.0


class SuppressionLedger:
    """Pairs every paste the guard suppressed with a delivery result, in either order.

    A suppression left unpaired means Typeless' paste was swallowed but nothing was sent
    (focus probe disagreed with the guard, an ambiguous record was skipped, ...).
    A delivered sentence left unpaired means the guard never stopped Typeless' own paste: the
    remote Mac got a stray "V". Seen when macOS still reports the guard as allowed but its event
    tap no longer receives anything (cause unknown); switching the guard off and on in Device
    Control restored it that time.
    """

    def __init__(self, window=SUPPRESSION_WINDOW, now=time.monotonic):
        self.window, self.now = window, now
        self.suppressions, self.results = [], []   # moments; results are (moment, delivered)
        self.missed = 0
        self.lock = threading.Lock()

    def suppression(self):
        with self.lock:
            moment = self.now()
            for index, (other, _) in enumerate(self.results):
                if abs(moment - other) <= self.window:
                    del self.results[index]
                    return
            self.suppressions.append(moment)

    def result(self, delivered=False):
        with self.lock:
            moment = self.now()
            for index, other in enumerate(self.suppressions):
                if abs(moment - other) <= self.window:
                    del self.suppressions[index]
                    return
            self.results.append((moment, delivered))

    def expired(self):
        """Number of suppressions that will never be paired; they are forgotten.

        Delivered sentences that will never be paired are counted for take_missed()."""
        with self.lock:
            moment = self.now()
            lost = [s for s in self.suppressions if moment - s > self.window]
            self.suppressions = [s for s in self.suppressions if moment - s <= self.window]
            self.missed += sum(1 for at, delivered in self.results if delivered and moment - at > self.window)
            self.results = [r for r in self.results if moment - r[0] <= self.window]
            return len(lost)

    def take_missed(self):
        with self.lock:
            missed, self.missed = self.missed, 0
            return missed


LEDGER = SuppressionLedger()


def handle_guard_lines(lines, ledger=None):
    ledger = ledger or LEDGER
    for line in lines:
        if line.startswith("POPUP_") or line.startswith("TYPELESS_PASTE_PASSED"):
            print(time.strftime("%H:%M:%S"), line, flush=True)
        elif line == "TYPELESS_PASTE_SUPPRESSED":
            ledger.suppression()
    for _ in range(ledger.expired()):
        print(time.strftime("%H:%M:%S"), "RESULT not-sent", flush=True)
    for _ in range(ledger.take_missed()):
        print(time.strftime("%H:%M:%S"), "GUARD_MISSED", flush=True)


def find_one(marker, executable):
    """PID of the single process running `executable` with `marker` in its arguments."""
    result = subprocess.run(["pgrep", "-f", marker], capture_output=True, text=True)
    matches = []
    for line in result.stdout.splitlines():
        if not line.isdigit():
            continue
        command = subprocess.run(["ps", "-p", line, "-o", "command="],
                                 capture_output=True, text=True).stdout
        if command.startswith(str(executable)) and marker in command:
            matches.append(int(line))
    if len(matches) > 1:
        raise RuntimeError("ambiguous helper")
    return matches[0] if matches else None


def process_alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def parse_args(arguments):
    parser = argparse.ArgumentParser()
    parser.add_argument("--destinations", required=True,
                        help="comma list of ssh aliases of the remote Macs this sender serves")
    parser.add_argument("--focus-app", required=True)
    parser.add_argument("--guard-app", required=True)
    parser.add_argument("--lock-file", required=True)
    parser.add_argument("--identities-file", required=True,
                        help="where to keep the destination identities (host names, addresses)")
    options = parser.parse_args(arguments)
    names = tuple(x for x in options.destinations.split(",") if x)
    if not names or len(set(names)) != len(names) or not all(map(valid_destination, names)):
        parser.error("--destinations must be distinct ssh aliases (lowercase letters, digits, -)")
    options.destinations = names
    return options


def make_target(destinations, focus_app, identities_file, probe=None):
    probe = probe or watcher.probe_target
    def target():
        value = probe(focus_app, identities_file)
        print(time.strftime("%H:%M:%S"), "TARGET", value, flush=True)
        # Any other Screen Sharing window (another Mac, or one not recognised) is left to
        # Typeless' own paste: the guard does not suppress it either.
        return value if value == "local" or value in destinations else "unknown"
    return target


# One line per delivered sentence; the guard closes one copy popup per line.
DELIVERED = {"file": None}


def report(status):
    print(time.strftime("%H:%M:%S"), "RESULT", status, flush=True)
    if status in CLOSES_SUPPRESSION:
        LEDGER.result(delivered=status == "paste-sent-unconfirmed")
    if status == "paste-sent-unconfirmed" and DELIVERED["file"] is not None:
        try:
            with open(DELIVERED["file"], "a") as handle:
                handle.write("%.3f\n" % time.time())
        except OSError:
            pass   # the popup then simply stays open


def run(destinations, focus_app, guard_app, identities_file):
    destinations = tuple(destinations)
    identities.refresh(identities_file, destinations)
    with tempfile.TemporaryDirectory(prefix="typeless-bridge-") as directory:
        root = Path(directory)
        heartbeat, out = root / "heartbeat", root / "guard.out"
        DELIVERED["file"] = root / "delivered"
        DELIVERED["file"].touch(mode=0o600)
        heartbeat.touch(mode=0o600)
        executable = Path(guard_app) / "Contents" / "MacOS" / Path(guard_app).stem
        stop = threading.Event()
        guard = {"pid": None}

        def pulse():
            next_identity_check = 0.0
            seen = 0
            while not stop.wait(0.2):
                try:
                    pid = guard["pid"]
                    if pid is not None:
                        alive = process_alive(pid)
                        if alive and time.monotonic() >= next_identity_check:
                            alive = find_one(str(heartbeat), executable) == pid
                            next_identity_check = time.monotonic() + 5
                        output = out.read_text()
                        lines, seen = new_guard_lines(output, seen)
                        handle_guard_lines(lines)
                        if not alive or guard_status(output) != "ready":
                            print("GUARD_EXITED", flush=True)
                            stop.set()
                            return
                    os.utime(heartbeat, None)
                except (OSError, RuntimeError):
                    stop.set()
                    return

        def refresher():
            # Addresses can change; refresh off the heartbeat thread (SSH may be slow).
            while not stop.wait(identities.REFRESH_SECONDS):
                try:
                    identities.refresh(identities_file, destinations)
                except Exception:
                    pass

        thread = threading.Thread(target=pulse, daemon=True)
        thread.start()
        threading.Thread(target=refresher, daemon=True).start()
        try:
            subprocess.run(["open", "-n", "-g", "--stdout", str(out), guard_app,
                            "--args", str(heartbeat), ",".join(destinations), str(identities_file),
                            str(DELIVERED["file"])],
                           check=True, timeout=5)
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                try:
                    status = guard_status(out.read_text())
                    if status == "failed":
                        print("GUARD_NOT_READY", flush=True)
                        return False
                    pid = find_one(str(heartbeat), executable)
                    if status == "ready" and pid:
                        guard["pid"] = pid
                        break
                except FileNotFoundError:
                    pass
                time.sleep(0.1)
            else:
                print("GUARD_TIMEOUT", flush=True)
                return False

            dispatcher = CompletionDispatcher(make_target(destinations, focus_app, identities_file),
                                              watcher.send_remote, destinations)
            conn = sqlite3.connect(DB.as_uri() + "?mode=ro", uri=True)
            try:
                print(time.strftime("%H:%M:%S"), "PILOT_READY", flush=True)
                watcher.watch(conn, dispatcher, report=report, should_continue=lambda: not stop.is_set())
            finally:
                conn.close()
            return False
        finally:
            stop.set()
            thread.join(timeout=1)
            heartbeat.unlink(missing_ok=True)
            DELIVERED["file"] = None


def main(arguments):
    options = parse_args(arguments)
    install_shutdown_handlers()
    lock = acquire_instance_lock(options.lock_file)
    try:
        run(options.destinations, options.focus_app, options.guard_app, options.identities_file)
    finally:
        os.close(lock)
    # Any return means the guard is not running. Exit non-zero so launchd restarts us after
    # its throttle interval (covers permissions granted later and guard crashes).
    return 1


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except ShutdownRequested:
        print("PILOT_STOPPED", flush=True)
    except Exception as error:
        print("PILOT_ERROR", type(error).__name__, flush=True)
        sys.exit(1)
