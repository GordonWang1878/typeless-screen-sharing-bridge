"""Completion-time dispatcher; dependencies are injected for safe validation.

The caller supplies a record ID that is unique within a watcher lifetime.
The dispatch attempt is consumed before any remote side effect; unknown results
are deliberately not retried.
"""
import uuid
from completion_routing import decide_completion


class CompletionDispatcher:
    def __init__(self, target_probe, send, remotes):
        self.target_probe = target_probe
        self.send = send
        self.remotes = frozenset(remotes)
        self.consumed = set()

    def complete(self, record_id, record):
        if record_id in self.consumed:
            return "ignore"
        # Probe only when a fresh valid completed record might be delivered.
        status, _ = decide_completion(record=record, already_consumed=False, destination=None)
        if status in ("ignore", "wait", "invalid"):
            return status
        try:
            target = self.target_probe()
        except Exception:
            self.consumed.add(record_id)
            return "unknown"
        status, text = decide_completion(record=record, already_consumed=False, destination=target,
                                         remotes=self.remotes)
        self.consumed.add(record_id)
        if status not in self.remotes:
            return status
        # Recheck immediately before dispatch; never retarget this transcript.
        try:
            still_target = self.target_probe()
        except Exception:
            return "unknown"
        if still_target != status:
            return "target-changed"
        try:
            return self.send(status, {"op": "paste-current", "id": str(uuid.uuid4()), "text": text})
        except Exception:
            return "delivery-unconfirmed"
