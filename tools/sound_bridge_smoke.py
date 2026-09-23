#!/usr/bin/env python3
"""Real guest sound-command pipeline against an explicitly simulated host.

No Mac sound setting is touched. Real CoreAudio readback is tested separately
by host_bridge_smoke.py; this fixture tests controls/errors deterministically.
"""
import json
import os
import pathlib
import secrets
import socket
import struct
import tempfile
import threading
import time
from desktop_smoke import Guest


def main():
    directory = pathlib.Path(tempfile.mkdtemp(prefix="orange-sound-", dir="/tmp"))
    channel = directory / "agent.sock"
    key = directory / "key"
    secret = secrets.token_hex(32).encode()
    fd = os.open(key, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "wb") as stream:
        stream.write(secret)
    guest = None
    peer = None
    commands = []
    fixture = {"level": .31, "failure": None, "grant": True}
    stopping = threading.Event()
    errors = []

    def host():
        nonlocal peer
        try:
            peer = socket.socket(socket.AF_UNIX)
            peer.settimeout(.5)
            peer.connect(str(channel))
            data = bytearray()
            authenticated = False
            while not stopping.is_set():
                try:
                    block = peer.recv(4096)
                except socket.timeout:
                    continue
                if not block:
                    return
                data.extend(block)
                while len(data) >= 16:
                    magic, version, flags, method, request, length = struct.unpack("<4sBBHII", data[:16])
                    assert magic == b"ORHB" and version == 1 and flags == 0 and length <= 4096
                    if len(data) < 16 + length:
                        break
                    payload = bytes(data[16:16+length]); del data[:16+length]
                    error = False
                    if not authenticated:
                        assert method == 1 and payload == secret
                        authenticated = True
                        response = {"status": "ready"}
                    elif method == 2:
                        response = {"mode": "test_fixture"}
                    elif method == 3:
                        response = {"provider": "test_fixture", "unix_seconds": int(time.time())}
                    elif method == 4:
                        response = {"status": "pong"}
                    elif method == 5:
                        def state(source, **fields):
                            return {"source": source, "status": "available", "permission": "allowed", **fields}
                        response = {"schema": 1, "provider": "macos", "observed_unix_seconds": int(time.time()), "freshness": "fresh",
                                    "wifi": state("Fixture", power=True), "bluetooth": state("Fixture", power=True),
                                    "brightness": {"source": "Fixture", "status": "unsupported", "permission": "not_requested"},
                                    "audio": state("Fixture", level=fixture["level"], device=103, control=fixture["grant"]),
                                    "battery": state("Fixture", level=.71, power=True)}
                    elif method == 6:
                        operation, percent, device = struct.unpack("<III", payload)
                        assert operation == 1 and percent <= 100 and device == 103
                        commands.append(percent)
                        failure = fixture["failure"]
                        error = failure is not None
                        if not error:
                            fixture["level"] = percent / 100
                        response = {"status": failure or "applied"}
                    else:
                        raise AssertionError(f"Unexpected method {method}")
                    encoded = json.dumps(response, separators=(",", ":")).encode()
                    peer.sendall(struct.pack("<4sBBHII", b"ORHB", 1, 2 if error else 1, method, request, len(encoded)) + encoded)
        except Exception as exc:
            if not stopping.is_set():
                errors.append(exc)

    try:
        guest = Guest([
            "-device", "virtio-serial-pci,id=orangebus,disable-modern=on,max_ports=2",
            "-chardev", f"socket,id=orangechan,path={channel},server=on,wait=off",
            "-device", "virtserialport,bus=orangebus.0,nr=1,chardev=orangechan,name=org.orange.host",
            "-fw_cfg", f"name=opt/orange/session,file={key}",
        ])
        thread = threading.Thread(target=host, daemon=True); thread.start()
        print(f"Evidence (simulated host): {guest.output}", flush=True)
        guest.until(lambda: "host-agent: pong" in guest.log() and '"Welcome"' in guest.log(), "fixture and desktop ready", 60)
        guest.scale = 2
        guest.click(1015, 16)
        guest.until(lambda: "hardware: view snapshot" in guest.log(), "menu bar opens native Control Center", 15)
        # Window origin (390,145), title 36; slider x=78..420, y=321.
        guest.click(390 + 78 + 171, 145 + 36 + 321)
        guest.until(lambda: "hardware: sound result 0" in guest.log(), "slider command completes through guest kernel and agent", 15)
        assert len(commands) == 1 and 49 <= commands[-1] <= 51
        applied_level = commands[-1] / 100
        guest.until(lambda: f'"level":{applied_level}' in guest.log(), "new volume readback reaches guest", 10)
        offset = len(guest.log()); fixture["failure"] = "permission_denied"
        guest.click(390 + 78 + 239, 145 + 36 + 321)
        guest.until(lambda: "hardware: sound result -13" in guest.log()[offset:], "revoked grant is reported without optimistic success", 15)
        assert fixture["level"] == applied_level
        offset = len(guest.log()); fixture["failure"] = "route_changed"
        guest.click(390 + 78 + 205, 145 + 36 + 321)
        guest.until(lambda: "hardware: sound result -116" in guest.log()[offset:], "changed route rejects stale command", 15)
        fixture["grant"] = False
        guest.until(lambda: '"control":false' in guest.log(), "revocation reaches guest", 10)
        time.sleep(.5)
        before = len(commands)
        guest.click(390 + 78 + 171, 145 + 36 + 321)
        time.sleep(1)
        assert len(commands) == before, "disabled slider submitted a host request"
        assert not errors, errors
        assert secret.decode() not in guest.log()
        print("PASS disabled controls send nothing; no credentials logged", flush=True)
    finally:
        stopping.set()
        if peer:
            peer.close()
        if guest:
            guest.close()
        key.unlink(missing_ok=True)


if __name__ == "__main__":
    main()
