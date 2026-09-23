# OrangeOS Mac Companion

`swift test --package-path host/macos` builds the CLI and runs protocol tests.
The default CLI connection is read-only. An optional menu-bar app provides a
revocable sound-control grant; Wi-Fi/Bluetooth control is still unfinished.

The companion connects to a QEMU-owned Unix socket in a same-user 0700 directory.
It reads a 64-character lowercase hex credential from an owned, non-symlink,
0600 (or stricter) file; the launcher supplies the same per-run credential to
the guest. No TCP listener, host commands, files, radio changes or media capture
are exposed by the default mode. Same-user hostile host processes and a compromised host are outside
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
| 6 audio.set_volume | 12 bytes: operation=1, percent 0–100, observed device ID (u32 little-endian) | Applied only with a live host sound grant and matching current route; status/error, never an implicit grant |
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
| Public IOKit `IODisplayGetFloatParameter` | Unsupported on this Mac | Initial public-API probe returned no endpoint. Superseded for this MacBook by the separately qualified compatibility adapter below; remains a read-only fallback. |

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

## Control Center, sound and battery (23 September 2026)

The menu-bar controls button now launches the native **Control Center**. Its
original SVG Wi-Fi/Bluetooth/sun/speaker/battery symbols accompany real cached
observations. CoreAudio supplies default-output volume, mute state and a route
identifier; IOPowerSources supplies internal battery capacity and AC state.
Unavailable hardware has no fabricated percentage. Battery changes legitimately
repaint the panel; timestamps and empty clicks do not.

Build the optional menu-bar companion and launch the preview:

```sh
sh host/macos/bundle.sh
python3 tools/host_bridge_preview.py
```

The local bundle is ad-hoc signed and stays in `build/OrangeOS Companion.app`.
Its speaker menu contains **Allow OrangeOS to change Mac volume** (off by
default) and **Disconnect and quit**. The grant lasts only for this companion
process; clearing it synchronizes with any current setter before returning.
It affects the Mac's selected output, not a guest-only mixer. Disconnecting the
companion leaves QEMU running. CLI mode without `--controls` denies mutations.

Dragging/releasing the guest slider submits a bounded sound request through
syscall 112. Only `/bin/hardware` gets that request capability on the current
read-only system image; ordinary apps cannot submit or acknowledge it. Only the
boot-authorized host agent can claim/complete the single pending request. IDs,
owner checks, strict lengths, six-second expiry and no automatic retry prevent
accidental replay. This path-based grant must be replaced before writable system
binaries are supported. It is not a completed general application sandbox.

The host checks live consent, command range and the observed device ID, calls
CoreAudio, then reads back the level. A route change fails the command rather
than redirecting it silently. Denial and command failure do not tear down
read-only services. A timeout can mean the final physical outcome is unknown;
the UI refreshes observations and does not retry a mutation automatically.

Qualification: seven Swift protocol tests, five Zig model tests, real Mac
readback/reconnect/expiry/no-op-redraw checks in `tools/host_bridge_smoke.py`, and
the real guest command pipeline against an explicitly simulated host in
`tools/sound_bridge_smoke.py`. The latter verifies slider dispatch, readback,
denial, route-change rejection and disabled controls without changing Mac audio.
`orange-host --verify-audio-write` also passed on this Mac: the production
CoreAudio setter wrote the exact existing level back and verified its readback,
without rounding or changing loudness.
The Mac menu's interactive grant/revoke check remains manual: the computer-use
inspector timed out on the status app in this session. End-to-end physical
volume adjustment through that menu has not yet been certified.

Wi-Fi association, Bluetooth discovery/pairing and guest PCM audio remain
separate unfinished work.

## Built-in display control (23 September 2026)

Control Center now includes a second, independent slider. Enable **Allow built-in
display brightness control** in the companion menu; this grant is off by default
and is separate from sound permission. Method 7 `display.set_brightness` has the
same 12-byte command shape as method 6, with a 5–100 percent range and the observed
CGDisplayID. Guest syscall 112 operation 5 submits display requests; the mailbox
kind selects display versus audio. No optimistic readback or automatic retry.

The new adapter dynamically resolves DisplayServices get/set symbols and accepts
only one online built-in panel. This is a **private macOS compatibility API**, not
a stable public driver contract. Missing symbols, failed reads, an ambiguous
display or device changes fail closed. External monitors are not controlled.
The public IOKit probe remains a read-only fallback. The adapter's ABI was checked
against [the upstream brightness implementation](https://github.com/nriley/brightness/pull/36).
No screen overlay is used to simulate a physical brightness change.

This Mac returned display 1 at about 67%; `orange-host --verify-brightness-write`
applied the exact existing value and verified it, without intentionally changing
the panel level. Eight Swift protocol tests and six Zig model tests pass. The
simulated-host suite exercises real guest dispatch, independent grants, the 5%
floor, denial and disabled controls. Real hardware snapshot, reconnect, expiry
and no-op-redraw tests passed in `/tmp/orange-host-aiwcgw8g`; fixture evidence is
`orange-daybreak-uq5hb4_1` in the macOS temporary directory. The physical slider
and interactive menu grant still need manual acceptance, as with sound.

The guest menu bar now shares the bounded Control Center snapshot parser. Its
Wi-Fi/Bluetooth/sound symbols and battery percentage follow real observations,
expire to `?` when disconnected, and open Control Center when clicked. No query
timestamp-only repaint; updates damage only the bar. The symbols use original
SVG alpha masks with theme-specific ink, and the battery bolt appears only with
host power connected. Small display modes omit the compact cluster rather than
overlap the menus. Live expiry/reconnect pixels were checked in
`/tmp/orange-host-tzhuadzl`; SVG tests cover clipped masks at 1x and 2x.
The full desktop interaction suite passed (`orange-daybreak-uqvymvea`). The
six-app blank-click/hover audit passed (`orange-daybreak-hol130o1`): 144 sampled
frames showed no transient pixel changes; Welcome, About, Files and Trash issued
zero blank-click repaints. Sampling does not certify every scanout frame.
