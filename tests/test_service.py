"""Offline checks for the sender service. No real guard, Typeless DB or SSH."""
import json
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "service"))
import identities  # noqa: E402
import sender  # noqa: E402
import watcher  # noqa: E402
from completion_dispatch import CompletionDispatcher  # noqa: E402
from completion_routing import decide_completion  # noqa: E402

RECORD = dict(status="completed", mode="voice_transcript", synced_from_cloud=0, text="你好\nhello")
REQUIRED = ["--focus-app", "/p.app", "--guard-app", "/g.app", "--lock-file", "/tmp/x.lock",
            "--identities-file", "/tmp/ids.json"]


class ParseArgs(unittest.TestCase):
    def test_destinations(self):
        self.assertEqual(sender.parse_args(["--destinations", "core,hub"] + REQUIRED).destinations, ("core", "hub"))
        self.assertEqual(sender.parse_args(["--destinations", "hub"] + REQUIRED).destinations, ("hub",))
        self.assertEqual(sender.parse_args(["--destinations", "studio-2"] + REQUIRED).destinations, ("studio-2",))

    def test_rejects_bad_local_duplicates_and_missing(self):
        for bad in (["--destinations", "Hub"] + REQUIRED, ["--destinations", "local"] + REQUIRED,
                    ["--destinations", "-oProxyCommand=x"] + REQUIRED, ["--destinations", "a b"] + REQUIRED,
                    ["--destinations", "hub,hub"] + REQUIRED, ["--destinations", ""] + REQUIRED,
                    ["--destinations", "hub"], REQUIRED):
            with self.assertRaises(SystemExit), mock.patch("sys.stderr"):
                sender.parse_args(bad)


class Target(unittest.TestCase):
    def results(self, destinations, observed):
        out = {}
        for value in observed:
            target = sender.make_target(destinations, "/p.app", "/ids.json", probe=lambda _app, _ids, v=value: v)
            with mock.patch("builtins.print"):
                out[value] = target()
        return out

    def test_core_sender_serves_hub_only(self):
        self.assertEqual(self.results(("hub",), ["hub", "core", "local", "unknown"]),
                         {"hub": "hub", "core": "unknown", "local": "local", "unknown": "unknown"})

    def test_air_sender_serves_core_and_hub(self):
        self.assertEqual(self.results(("core", "hub"), ["core", "hub", "unknown"]),
                         {"core": "core", "hub": "hub", "unknown": "unknown"})


class RoutingAndDispatch(unittest.TestCase):
    def test_routing(self):
        remotes = frozenset({"hub", "core"})
        def decide(where):
            return decide_completion(record=RECORD, already_consumed=False, destination=where, remotes=remotes)
        self.assertEqual(decide("local"), ("local", None))
        for remote in ("hub", "core"):
            self.assertEqual(decide(remote), (remote, RECORD["text"]))
        for other in ("air", "unknown", "unknown:no-trust"):
            self.assertEqual(decide(other)[0], "unknown")

    def test_sends_once(self):
        sent = []
        d = CompletionDispatcher(lambda: "core", lambda host, p: sent.append((host, p["text"])) or "paste-sent-unconfirmed",
                                 {"core"})
        self.assertEqual(d.complete("r1", RECORD), "paste-sent-unconfirmed")
        self.assertEqual(d.complete("r1", RECORD), "ignore")
        self.assertEqual(sent, [("core", RECORD["text"])])

    def test_local_and_unknown_never_send(self):
        for where in ("local", "unknown"):
            d = CompletionDispatcher(lambda w=where: w, lambda *a: self.fail("must not send"), {"hub"})
            self.assertEqual(d.complete("r", RECORD), where)

    def test_send_failure_is_unconfirmed(self):
        def boom(*_):
            raise OSError("ssh failed")
        self.assertEqual(CompletionDispatcher(lambda: "hub", boom, {"hub"}).complete("r", RECORD), "delivery-unconfirmed")

    def test_send_remote_rejects_unsafe_names(self):
        for bad in ("-oProxyCommand=x", "local", "Hub", "a b"):
            with self.assertRaises(ValueError):
                watcher.send_remote(bad, {})


class Deliveries(unittest.TestCase):
    def test_only_sent_sentences_are_reported_to_the_guard_and_nobody_is_notified(self):
        with tempfile.TemporaryDirectory() as directory, mock.patch("builtins.print"), \
                mock.patch.object(sender.subprocess, "run") as run, \
                mock.patch.dict(sender.DELIVERED, {"file": Path(directory) / "delivered"}):
            for status in ("paste-sent-unconfirmed", "local", "unknown", "delivery-unconfirmed",
                           "target-changed", "paste-sent-unconfirmed"):
                sender.report(status)
            lines = (Path(directory) / "delivered").read_text().splitlines()
        self.assertEqual(len(lines), 2)
        self.assertTrue(all(float(line) > 0 for line in lines))
        run.assert_not_called()

class Watch(unittest.TestCase):
    def setUp(self):
        self.db = sqlite3.connect(":memory:")
        self.db.execute("CREATE TABLE history_v2 (id TEXT, status TEXT, mode TEXT, synced_from_cloud INT,"
                        " created_at INT, refined_text TEXT)")
        self.db.execute("INSERT INTO history_v2 VALUES ('old','completed','voice_transcript',0,1,'old text')")

    def add(self, rid, status, mode="voice_transcript", text=None, synced=0, at=2):
        return lambda: self.db.execute("INSERT INTO history_v2 VALUES (?,?,?,?,?,?)", (rid, status, mode, synced, at, text))

    def complete(self, rid, text):
        return lambda: self.db.execute("UPDATE history_v2 SET status='completed', refined_text=? WHERE id=?", (text, rid))

    def drive(self, steps, **options):
        steps = list(steps)
        results, printed = [], []
        polls = {"n": 0}
        def sleep(_):
            polls["n"] += 1
            if steps:
                steps.pop(0)()
        def should_continue():
            return polls["n"] <= len(self.all_steps)
        self.all_steps = list(steps)
        dispatcher = CompletionDispatcher(lambda: "hub", lambda h, p: "sent:" + p["text"], {"hub"})
        with mock.patch("builtins.print", lambda *a, **k: printed.append(" ".join(map(str, a)))):
            watcher.watch(self.db, dispatcher, report=results.append, sleep=sleep, should_continue=should_continue,
                          **options)
        return results, printed

    def set_status(self, rid, status):
        return lambda: self.db.execute("UPDATE history_v2 SET status=? WHERE id=?", (status, rid))

    def test_record_that_errors_then_completes_is_delivered(self):
        results, printed = self.drive([self.add("r1", "transcribing"), self.set_status("r1", "error"), lambda: None,
                                       self.complete("r1", "重试成功"), lambda: None, lambda: None])
        self.assertEqual(results, ["sent:重试成功"])
        self.assertTrue(any(line.endswith("LATE_COMPLETION") for line in printed))

    def test_stalled_record_does_not_make_next_sentence_ambiguous(self):
        results, printed = self.drive([self.add("r1", "error"), self.add("r2", "transcribing", at=3),
                                       self.complete("r2", "下一句"), lambda: None])
        self.assertEqual(results, ["sent:下一句"])
        self.assertFalse(any("SKIP_AMBIGUOUS" in line for line in printed))

    def test_stalled_record_is_given_up_after_the_window(self):
        results, printed = self.drive([self.add("r1", "error"), lambda: None, self.complete("r1", "太晚了"),
                                       lambda: None], retry_window=0)
        self.assertEqual(results, [])
        self.assertTrue(any(line.endswith("GAVE_UP") for line in printed))

    def test_sentence_in_progress_at_start_is_delivered_when_it_completes(self):
        self.db.execute("INSERT INTO history_v2 VALUES ('r0','transcribing','voice_transcript',0,3,NULL)")
        results, _ = self.drive([lambda: None, self.complete("r0", "启动时正在说"), lambda: None])
        self.assertEqual(results, ["sent:启动时正在说"])

    def test_abandoned_old_records_are_history(self):
        self.db.execute("INSERT INTO history_v2 VALUES ('ancient','transcribing','voice_transcript',0,0,NULL)")
        results, printed = self.drive([lambda: None, self.complete("ancient", "老的"), lambda: None],
                                      retry_window=0)
        self.assertEqual(results, [])
        self.assertFalse(any("GAVE_UP" in line for line in printed))

    def test_old_stuck_record_never_blocks_new_sentences(self):
        self.db.execute("INSERT INTO history_v2 VALUES ('stuck','transcribing','voice_transcript',0,0,NULL)")
        results, printed = self.drive([self.add("r1", "transcribing"), self.complete("r1", "新句子"), lambda: None])
        self.assertEqual(results, ["sent:新句子"])
        self.assertFalse(any("SKIP_AMBIGUOUS" in line for line in printed))

    def test_existing_rows_are_never_delivered(self):
        results, _ = self.drive([lambda: None])
        self.assertEqual(results, [])

    def test_new_dictation_delivered_once_after_completion(self):
        results, _ = self.drive([self.add("n1", "transcribing"), self.complete("n1", "新句子"), lambda: None, lambda: None])
        self.assertEqual(results, ["sent:新句子"])

    def test_other_modes_logged_by_name_not_delivered(self):
        results, printed = self.drive([self.add("m1", "completed", mode="ask_anything", text="secret"), lambda: None])
        self.assertEqual(results, [])
        self.assertTrue(any(line.endswith("SKIP_MODE ask_anything") for line in printed))
        self.assertFalse(any("secret" in line for line in printed))

    def test_odd_mode_names_are_not_logged_verbatim(self):
        _, printed = self.drive([self.add("m2", "completed", mode="Some Text Here", text="x"), lambda: None])
        self.assertTrue(any(line.endswith("SKIP_MODE other") for line in printed))

    def test_cloud_synced_rows_ignored(self):
        results, printed = self.drive([self.add("c1", "completed", text="cloud", synced=1), lambda: None])
        self.assertEqual(results, [])
        self.assertFalse(any("SKIP_MODE" in line for line in printed))

    def test_stops_when_guard_unavailable(self):
        dispatcher = CompletionDispatcher(lambda: "hub", lambda *a: self.fail("must not send"), {"hub"})
        with mock.patch("builtins.print"):
            watcher.watch(self.db, dispatcher, report=self.fail, sleep=lambda _: None, should_continue=lambda: False)


class Probe(unittest.TestCase):
    def test_probe_maps_values(self):
        def fake_run(cmd, **kw):
            Path(cmd[cmd.index("--stdout") + 1]).write_text(self.value + "\n")
        for self.value, expected in (("other-frontmost", "local"), ("target=core", "core"), ("target=studio-2", "studio-2"),
                                     ("hub", "unknown:hub"), ("target=Bad!", "unknown"),
                                     ("name-not-recognized", "unknown:name-not-recognized"), ("Bad Value!", "unknown")):
            with mock.patch.object(watcher.subprocess, "run", fake_run):
                self.assertEqual(watcher.probe_target("/nonexistent.app", "/ids.json"), expected)

    def test_probe_gets_identities_file(self):
        seen = []
        def fake_run(cmd, **kw):
            seen.append(cmd)
            Path(cmd[cmd.index("--stdout") + 1]).write_text("target=hub\n")
        with mock.patch.object(watcher.subprocess, "run", fake_run):
            watcher.probe_target("/p.app", "/ids.json")
        self.assertEqual(seen[0][seen[0].index("--args") + 1:], ["/ids.json"])


class GuardStatus(unittest.TestCase):
    def test_states(self):
        self.assertEqual(sender.guard_status(""), "waiting")
        self.assertEqual(sender.guard_status("READY\n"), "ready")
        self.assertEqual(sender.guard_status("READY\nTAP_REENABLED\nTYPELESS_PASTE_SUPPRESSED\n"), "ready")
        self.assertEqual(sender.guard_status("NOT_READY\n"), "failed")

    def test_reads_only_complete_new_lines(self):
        lines, seen = sender.new_guard_lines("READY\nTYPELESS_PASTE_SUPPRESSED\nPOPUP_CLOSED\nPOPUP_LE", 0)
        self.assertEqual((lines, seen), (["READY", "TYPELESS_PASTE_SUPPRESSED", "POPUP_CLOSED"], 3))
        lines, seen = sender.new_guard_lines("READY\nTYPELESS_PASTE_SUPPRESSED\nPOPUP_CLOSED\nPOPUP_LEFT layout\n", seen)
        self.assertEqual((lines, seen), (["POPUP_LEFT layout"], 4))

    def test_logs_popup_lines_only(self):
        printed = []
        ledger = sender.SuppressionLedger(now=lambda: 0)
        with mock.patch("builtins.print", lambda *a, **k: printed.append(" ".join(map(str, a)))):
            sender.handle_guard_lines(["READY", "POPUP_CLOSED", "POPUP_LEFT layout"], ledger)
        self.assertEqual([line.split(" ", 1)[1] for line in printed], ["POPUP_CLOSED", "POPUP_LEFT layout"])


class SuppressionLedger(unittest.TestCase):
    def setUp(self):
        self.clock = [0.0]
        self.ledger = sender.SuppressionLedger(window=20, now=lambda: self.clock[0])

    def at(self, moment):
        self.clock[0] = moment

    def test_result_after_suppression_pairs(self):
        self.ledger.suppression(); self.at(3); self.ledger.result(); self.at(60)
        self.assertEqual(self.ledger.expired(), 0)

    def test_result_before_suppression_pairs(self):
        self.ledger.result(); self.at(1); self.ledger.suppression(); self.at(60)
        self.assertEqual(self.ledger.expired(), 0)

    def test_unpaired_suppression_is_reported_once_after_window(self):
        self.ledger.suppression()
        self.at(19); self.assertEqual(self.ledger.expired(), 0)
        self.at(21); self.assertEqual(self.ledger.expired(), 1)
        self.assertEqual(self.ledger.expired(), 0)

    def test_stale_result_does_not_pair_later_suppression(self):
        self.ledger.result(); self.at(30); self.ledger.suppression(); self.at(51)
        self.assertEqual(self.ledger.expired(), 1)

    def test_two_sentences_one_lost(self):
        self.ledger.suppression(); self.at(1); self.ledger.suppression(); self.at(2); self.ledger.result()
        self.at(25); self.assertEqual(self.ledger.expired(), 1)

    def test_unpaired_suppression_is_logged_not_sent(self):
        printed = []
        self.ledger.suppression(); self.at(21)
        with mock.patch("builtins.print", lambda *a, **k: printed.append(" ".join(map(str, a)))):
            sender.handle_guard_lines([], self.ledger)
        self.assertTrue(printed[0].endswith("RESULT not-sent"))

    def test_report_closes_suppression_for_sent_and_undelivered_only(self):
        with mock.patch.object(sender, "LEDGER", self.ledger), mock.patch("builtins.print"):
            for status in ("paste-sent-unconfirmed", "delivery-unconfirmed", "unknown", "local"):
                self.ledger.suppression()
                sender.report(status)
        self.at(30)
        self.assertEqual(self.ledger.expired(), 2)



class GuardLaunch(unittest.TestCase):
    def test_guard_receives_heartbeat_and_destinations(self):
        seen = []
        def fake_run(cmd, **kw):
            seen.append(cmd)
            raise RuntimeError("stop")
        with mock.patch.object(sender.subprocess, "run", fake_run), \
                mock.patch.object(sender.identities, "refresh"), self.assertRaises(RuntimeError):
            sender.run(("core", "hub"), "/p.app", "/g.app", "/ids.json")
        args = seen[0][seen[0].index("--args") + 1:]
        self.assertTrue(args[0].endswith("/heartbeat"))
        self.assertEqual(args[1:3], ["core,hub", "/ids.json"])
        self.assertTrue(args[3].endswith("/delivered"))

class Identities(unittest.TestCase):
    def test_names_from_remote_output(self):
        out = "hub\nHub\n127.0.0.1\n198.18.0.1\n192.0.2.10\n::1\nfe80::1%en0\nfdce::5\n"
        self.assertEqual(identities.names_from(out),
                         sorted(["hub", "hub.local", "hub._rfb._tcp.local", "192.0.2.10", "fdce::5"]))

    def test_incomplete_output_rejected(self):
        with self.assertRaises(ValueError):
            identities.names_from("hub\n")

    def test_refresh_keeps_cached_entry_for_unreachable_mac(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "identities.json"
            path.write_text(json.dumps({"core": ["core.local"]}))
            def fetch(host):
                if host == "core":
                    raise OSError("asleep")
                return ["hub.local"]
            with mock.patch("builtins.print"):
                result = identities.refresh(path, ("core", "hub"), fetch=fetch)
            self.assertEqual(result, {"core": ["core.local"], "hub": ["hub.local"]})
            self.assertEqual(json.loads(path.read_text()), result)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_refresh_without_cache_leaves_mac_out(self):
        with tempfile.TemporaryDirectory() as directory:
            printed = []
            def fail(_host):
                raise OSError("down")
            with mock.patch("builtins.print", lambda *a, **k: printed.append(" ".join(map(str, a)))):
                result = identities.refresh(Path(directory) / "ids.json", ("hub",), fetch=fail)
            self.assertEqual(result, {})
            self.assertTrue(printed[0].endswith("IDENTITY_UNAVAILABLE hub"))


if __name__ == "__main__":
    unittest.main()
