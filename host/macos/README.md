# OrangeOS Mac Companion — read-only bridge milestone

`swift test --package-path host/macos` builds the CLI and runs protocol tests.
This is not yet a settings application or a Wi-Fi/Bluetooth controller.

The companion connects to a QEMU-owned Unix socket in a same-user 0700 directory.
It reads a 64-character lowercase hex credential from an owned, non-symlink,
0600 (or stricter) file; the launcher supplies the same per-run credential to
the guest. No TCP listener, host commands, files, radio changes or media capture
are exposed. Same-user hostile host processes and a compromised host are outside
this initial channel's isolation boundary; a guest credential is not app trust.

Protocol ORHB v1: 16-byte little-endian header (`ORHB`, version u8, flags u8,
method u16, request u32, payload length u32), followed by at most 4096 bytes.
This initial cap is tighter than the production plan's 64 KiB ceiling.
Flags: 0 request, 1 response, 2 error. Strictly increasing nonzero request IDs
within a connection; malformed headers, bad authentication or replay close it.

| Method | Request | Response |
|---|---|---|
| 1 hello | 64-byte private session credential | Read-only readiness |
| 2 capabilities | Empty | Actual allowlist; hardware controls not implemented |
| 3 snapshot | Empty | Host UTC seconds, timezone/offset, OS version |
| 4 ping | Empty | Pong |
| 5 hardware | Empty | Versioned, non-identifying Wi-Fi/Bluetooth/display readback, source, permission and freshness |
| Other | Any | Denied (or invalid argument); no host mutation |

Responses contain bounded JSON; framing itself is binary. Fragmentation and
coalescing are handled independently of device packet boundaries. A connection
permits at most 32 requests/second. Credential/payload content is never logged.
Streaming subscriptions, per-feature consent UI, service supervision,
credential rotation and production sandbox qualification are later 9a work.

## Verified host/guest vertical slice (7 September 2026)

The guest now includes a bounded legacy virtio-serial driver and `/bin/host-agent`.
Only the boot-launched Seed service manager can grant transport authority, and
only to that exact path on the current read-only filesystem. Ordinary processes
and their children do not inherit it. This is a narrow boot grant, **not** the
planned general capability broker or a substitute for future writable-file
identity checks. Syscall 110 validates all user buffers before copying or
consuming transport data. `/bin/host-probe` checks access denial at boot.

QEMU reserves port zero for consoles. This prototype deliberately requires
`virtio-serial-pci,disable-modern=on,max_ports=2` and named port **1**
(`virtserialport,nr=1,name=org.orange.host`). Modern-only PCI, MMIO, hotplug and
multiple named ports are not supported. Six bounded DMA queues reserve 864 KiB;
device failure resets the device and retains those pages until reboot. The
agent polls nonblocking I/O every 20 ms, uses 5-second response deadlines, and
re-authenticates on host-port generation changes. A failed session waits for a
reconnect; there is no silent authorization bypass.

Run the disposable, network-disabled integration test:

```sh
swift test --package-path host/macos
zig test userland/libs/host-services/protocol.zig
zig build
./scripts/mkdisk.sh
python3 tools/host_bridge_smoke.py
```

Do not rebuild the development disk while another VM is using it. The smoke
test uses a snapshot overlay, a private temporary socket directory, and a fresh
256-bit random credential passed through `opt/orange/session` in QEMU fw_cfg.
It removes the credential and stops its own child processes on exit. Private
diagnostic logs remain at the printed evidence path; no credentials are logged.

Passed on macOS 15.7 / arm64, QEMU 11.1.0, 3 GiB / 2 vCPU:

- Guest authentication, capabilities, real Mac UTC/timezone snapshot and ping.
- Ordinary-app denial for all four transport operations; invalid guest buffers.
- Companion termination/restart, fresh authentication and resumed heartbeat.
- No credential in guest/host logs; no guest network device attached.
- Swift protocol tests and Zig golden-wire/malformed-header tests.
- Normal boot without the opt-in device cleanly disables the agent; the full
  existing desktop interaction suite still passes with the bridge-enabled image.

The time snapshot is diagnostic output, **not connected to the guest clock**.
This completed the first transport proof within Phase 9a/9b, not their full
production acceptance gates. Transport layout follows the
[Virtio specification](https://docs.oasis-open.org/virtio/virtio/v1.2/virtio-v1.2.html).

## Hardware readback and native status view (9 September 2026)

Open **Appearance → Mac hardware status** (or run `/bin/hardware`). A normal VM
without the opt-in channel shows a disconnected explanation. There are no
pretend toggles: this milestone reads state and does not change Mac hardware.

After building, use `python3 tools/host_bridge_preview.py` for the full-screen
bridge-enabled preview. Closing QEMU stops its companion and deletes the
per-session key. VM disk changes are disposable; the Mac's existing network is
shared through QEMU NAT independently of the radio status panel. Do not rebuild
the image while this preview is running.

| Provider | Actual Mac result | Important boundary |
|---|---|---|
| CoreWLAN `powerOn()` | Wi-Fi on | A false return also permits query failure, so it is reported as unknown, never fabricated as off. No SSID, scan or network credentials. |
| CoreBluetooth authorization + IOBluetooth `powerState` | Permission already allowed; Bluetooth on | Permission is checked before querying the controller; no manager creation/prompt, discovery, pairing or device-name enumeration. |
| Public IOKit `IODisplayGetFloatParameter` | Unsupported on this Mac | No readable endpoint returned; no private API fallback or fake brightness slider. Multiple readable displays require selection rather than guessing. |

Queries run every two seconds on a dedicated serial worker. RPC reads a locked
cache instead of blocking on framework calls. Observations expire after six
seconds using wall and monotonic time; the timestamp starts before querying.
The guest agent publishes only method 5 into a bounded 4096-byte kernel cache.
Syscall 111 operation 0 reads this public, non-identifying snapshot; operation 1
publishes or clears it and requires the boot-issued agent grant. Ordinary apps
cannot forge snapshots or access transport/credentials. Copies validate user
pointers, capacity and maximum length. The guest cache expires independently
six seconds after guest publication and is cleared on disconnect, protocol
failure or reconnect. This is not a strict six-second end-to-end observation-age
guarantee: transport latency can add time after the host checks freshness.

The native window validates the schema/provider and capability fields. It
compares visible state, not observation timestamps: repeated host samples,
hover and empty clicks do not repaint. Relaunch focuses the existing window.
This retains the current staged client publication contract; it does not claim
the planned atomic surface-ownership protocol has been completed.

Additional qualification commands:

```sh
host/macos/.build/debug/orange-host --probe-hardware
zig test userland/apps/hardware/model.zig
python3 tools/host_bridge_smoke.py
```

The real guest test compares received hardware status with a direct Mac probe,
checks publication denial and invalid pointers/capacities, opens the native view,
checks no-op repaint stability and singleton launch, disconnects/restarts the
companion, compares restored pixels, freezes the companion to exercise response
timeout and recovery, and closes the window. These are read-only
checks on the existing Mac; permission revocation and physical radio changes
have not been exercised. No Mac setting is changed.

Remaining gates: host consent/revoke UI before any mutation, per-operation
permissions and adapters, Wi-Fi scan/association, Bluetooth discovery/services,
an actually supported brightness backend, battery/audio/media readback, and
production supervision/sandboxing. This is a verified **subset** of 9b and the
10a/11a/12a feasibility work, not completion of those full phases.

The live window test also exposed and fixed a shared process-entry ABI bug:
the kernel now supplies a zero return-address slot and correct C stack alignment
for OrangeOS's `callconv(.c)` entry functions. Inlined allocator instrumentation
previously read the unmapped upper stack guard page. The boot probe checks the
entry sentinel; a future POSIX/assembly entry will require its own stack layout.

Qualification evidence (same build): `orange-host-wszabwyw` in `/tmp` passed the
full hardware/timeout suite; `orange-daybreak-gv7vuq_e` in the macOS temporary
directory passed `tools/desktop_smoke.py`. Six Swift protocol tests, two Zig
wire tests and four Zig hardware-model tests passed. Connected/disconnected
screenshots from `orange-host-l25kw9u3` were visually inspected for clipping,
rounded corners and truthful labels. The six-second guest cache expired before
the frozen companion's separate RPC timeout; both fail-closed paths passed.
