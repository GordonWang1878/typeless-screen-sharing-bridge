"""Pure policy for routing a single completed local dictation.

This module performs no input monitoring, database access or delivery.
The caller must supply the currently observed destination at completion.
"""

import re

# A destination is the ssh alias of a remote Mac: lowercase letters, digits and "-".
DESTINATION = re.compile(r"[a-z0-9][a-z0-9-]{0,31}")


def valid_destination(name):
    return isinstance(name, str) and DESTINATION.fullmatch(name) is not None and name != "local"


def decide_completion(*, record, already_consumed, destination, remotes=frozenset()):
    """Return (action, text); never retry or forward ambiguous data."""
    if already_consumed:
        return "ignore", None
    if record.get("mode") != "voice_transcript" or record.get("synced_from_cloud"):
        return "ignore", None
    if record.get("status") != "completed":
        return "wait", None
    text = record.get("text")
    if not isinstance(text, str) or not text or "\0" in text or len(text.encode("utf-8")) > 65536:
        return "invalid", None
    if destination == "local":
        return "local", None
    if destination in remotes:
        return destination, text
    return "unknown", None
