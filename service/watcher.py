"""Typeless history watcher, focus probe call and SSH delivery for the sender.

Reads Typeless' history_v2 read-only. Transcripts are read only for the one completed
record being delivered and travel only over SSH stdin, never in logs or arguments.
"""
import json
import re
import subprocess
import tempfile
import time
from pathlib import Path

from completion_routing import valid_destination

# Fixed command run on the receiver: pass stdin to its socket and print the reply. Uses the
# system nc, so receivers need no Python.
REMOTE_RELAY = '/usr/bin/nc -U -w 5 "$HOME/.local/state/typeless-remote-bridge/receiver.sock"'


def probe_target(app_path, identities_file):
    with tempfile.TemporaryDirectory(prefix="typeless-bridge-target-") as directory:
        path = Path(directory) / "result"
        subprocess.run(["open", "-n", "-g", "--stdout", str(path), app_path,
                        "--args", str(identities_file)],
                       check=True, capture_output=True, timeout=3)
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            try:
                value = path.read_text().strip()
                if value:
                    # The machine running this service is always "local".
                    if value == "other-frontmost":
                        return "local"
                    name = value[len("target="):] if value.startswith("target=") else None
                    if name is not None and valid_destination(name):
                        return name
                    # Otherwise a fixed reason word from the probe, kept for the log.
                    return ("unknown:" + value) if re.fullmatch(r"[a-z][a-z-]{0,39}", value) else "unknown"
            except FileNotFoundError:
                pass
            time.sleep(0.05)
    return "unknown"


def send_remote(host, payload):
    if not valid_destination(host):
        raise ValueError("invalid destination")
    # The relay is fixed code. The transcript goes only over stdin.
    command = ["ssh", "-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
               "-o", "ClearAllForwardings=yes", "-o", "ConnectTimeout=5", host,
               REMOTE_RELAY]
    result = subprocess.run(command, input=json.dumps(payload, ensure_ascii=False) + "\n",
                            text=True, capture_output=True, timeout=15, check=True)
    reply = json.loads(result.stdout)
    return reply.get("status", "delivery-unconfirmed")


def safe_mode(mode):
    return mode if isinstance(mode, str) and re.fullmatch(r"[a-z0-9_]{1,32}", mode) else "other"


# A record Typeless marked error/dismissed may still complete (Typeless retries a failed
# transcription in place). Keep watching it this long before giving up on it.
RETRY_WINDOW = 180.0
STALLED = ("error", "dismissed")


FINISHED = ("completed",) + STALLED


def watch(conn, dispatcher, report, now=time.monotonic, sleep=time.sleep, interval=0.1,
          limit=None, should_continue=lambda: True, retry_window=RETRY_WINDOW):
    """Deliver each new local voice transcript once. Returns when should_continue() is false."""
    # Records still being transcribed when we start belong to a sentence spoken just now:
    # watch them like stalled ones instead of treating them as history.
    # Only rows newer than the newest finished one can be a sentence in progress; older
    # unfinished rows are long abandoned and are treated as history.
    waiting = {}   # record id -> time to give up on it; never counted as ambiguous
    known = set()
    rows = conn.execute("SELECT id,status,mode,created_at FROM history_v2").fetchall()
    newest_finished = max((r[3] for r in rows if r[1] in FINISHED and r[3] is not None), default=None)
    for record_id, status, mode, created in rows:
        recent = newest_finished is None or (created is not None and created >= newest_finished)
        if mode == "voice_transcript" and status not in FINISHED and recent:
            waiting[record_id] = now() + retry_window
        else:
            known.add(record_id)
    deadline = None if limit is None else now() + limit
    while deadline is None or now() < deadline:
        if not should_continue():
            print("STOP_GUARD_UNAVAILABLE", flush=True)
            return
        rows = conn.execute("SELECT id,status,mode,synced_from_cloud FROM history_v2 "
                            "ORDER BY created_at DESC LIMIT 30").fetchall()
        for row in rows:
            # Other Typeless features are not bridged. Log only the mode name, so a missing
            # sentence in a remote window can be traced to this.
            if row[0] not in known and row[2] != "voice_transcript" and not row[3]:
                known.add(row[0])
                print(time.strftime("%H:%M:%S"), "SKIP_MODE", safe_mode(row[2]), flush=True)
        fresh = [row for row in rows if row[0] not in known and row[2] == "voice_transcript" and not row[3]]
        for record_id, status, _mode, _synced in fresh:
            if status in STALLED:
                waiting.setdefault(record_id, now() + retry_window)
        for record_id, give_up in list(waiting.items()):
            if now() >= give_up:
                known.add(record_id)
                waiting.pop(record_id)
                print(time.strftime("%H:%M:%S"), "GAVE_UP", flush=True)
        # Waiting records count only once they complete, so they cannot block a new sentence.
        active = [row for row in fresh if row[0] not in known
                  and (row[0] not in waiting or row[1] == "completed")]
        if len(active) > 1:
            known.update(row[0] for row in active)
            for row in active:
                waiting.pop(row[0], None)
            # If the guard swallowed Typeless' paste for one of these, the sender's
            # suppression ledger reports it as not-sent.
            print(time.strftime("%H:%M:%S"), "SKIP_AMBIGUOUS", flush=True)
        elif active:
            record_id, status, mode, synced = active[0]
            if status == "completed":
                # Read text only for this completed local record.
                textrow = conn.execute(
                    "SELECT refined_text FROM history_v2 WHERE id=? AND status='completed' "
                    "AND mode='voice_transcript' AND NOT COALESCE(synced_from_cloud,0)",
                    (record_id,)).fetchone()
                if textrow is not None:
                    known.add(record_id)
                    if waiting.pop(record_id, None) is not None:
                        print(time.strftime("%H:%M:%S"), "LATE_COMPLETION", flush=True)
                    if not should_continue():
                        print("STOP_GUARD_UNAVAILABLE", flush=True)
                        return
                    record = dict(status=status, mode=mode, synced_from_cloud=synced, text=textrow[0])
                    report(dispatcher.complete(record_id, record))
        sleep(interval)
