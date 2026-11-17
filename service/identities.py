"""Identities of the destination Macs, used to recognise their Screen Sharing windows.

A Screen Sharing window's connection document is named after the remote Mac
("Hub (user).vncloc"). The sender asks each destination for its names (computer name,
local host name) and addresses over SSH and writes them to a JSON file the guard and the
focus probe match that name against. No user names are involved.
"""
import ipaddress
import json
import os
import subprocess
import tempfile
import time
from pathlib import Path

QUERY = "scutil --get LocalHostName; scutil --get ComputerName; ifconfig | awk '/inet6? /{print $2}'"
REFRESH_SECONDS = 30 * 60
# Benchmark range used by proxy/VPN tools for virtual interfaces; never a real LAN address.
VIRTUAL = ipaddress.ip_network("198.18.0.0/15")


def names_from(output):
    lines = [line.strip() for line in output.splitlines()]
    if len(lines) < 2 or not lines[0] or not lines[1]:
        raise ValueError("incomplete identity")
    local, computer = lines[0].lower(), lines[1].lower()
    names = {local, local + ".local", computer, computer + "._rfb._tcp.local"}
    for item in lines[2:]:
        try:
            address = ipaddress.ip_address(item.split("%")[0])
        except ValueError:
            continue
        if not (address.is_loopback or address.is_link_local or address in VIRTUAL):
            names.add(str(address))
    return sorted(names)


def fetch(host):
    result = subprocess.run(["ssh", "-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
                             "-o", "ConnectTimeout=5", host, QUERY],
                            capture_output=True, text=True, timeout=15, check=True)
    return names_from(result.stdout)


def valid_entry(value):
    return isinstance(value, list) and value and all(isinstance(x, str) and x for x in value)


def refresh(path, destinations, fetch=fetch):
    """Update the identities file; keep the last known entry for a Mac that is unreachable."""
    path = Path(path)
    try:
        cached = json.loads(path.read_text())
    except (OSError, ValueError):
        cached = {}
    identities = {}
    for name in destinations:
        try:
            identities[name] = fetch(name)
        except Exception:
            if isinstance(cached, dict) and valid_entry(cached.get(name)):
                identities[name] = cached[name]
                print(time.strftime("%H:%M:%S"), "IDENTITY_CACHED", name, flush=True)
            else:
                print(time.strftime("%H:%M:%S"), "IDENTITY_UNAVAILABLE", name, flush=True)
    descriptor, temporary = tempfile.mkstemp(dir=path.parent, prefix=".identities-")
    try:
        with os.fdopen(descriptor, "w") as handle:
            json.dump(identities, handle, sort_keys=True)
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    except BaseException:
        Path(temporary).unlink(missing_ok=True)
        raise
    return identities
