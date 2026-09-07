# OrangeOS Mac Companion — read-only bridge milestone

`swift test --package-path host/macos` builds the CLI and runs protocol tests.
This is not yet a settings application or a Wi-Fi/Bluetooth controller.

The companion connects to a QEMU-owned Unix socket in a same-user 0700 directory.
It reads a 64-character lowercase hex credential from an owned, non-symlink,
0600 (or stricter) file; the launcher supplies the same per-run credential to
the guest. No TCP listener, host commands, files, radio or media operations are
exposed. Same-user hostile host processes and a compromised host are outside
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
| Other | Any | Denied (or invalid argument); no host mutation |

Responses contain bounded JSON; framing itself is binary. Fragmentation and
coalescing are handled independently of device packet boundaries. A connection
permits at most 32 requests/second. Credential/payload content is never logged.
Streaming subscriptions, per-feature consent UI, service supervision, snapshot
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

The returned state is currently diagnostic output, **not connected to Control
Centre or the guest clock**. Wi-Fi, Bluetooth, brightness, audio, battery and
media adapters remain unimplemented. No physical Mac settings were changed.
This completes the first transport proof within Phase 9a/9b, not their full
production acceptance gates. Transport layout follows the
[Virtio specification](https://docs.oasis-open.org/virtio/virtio/v1.2/virtio-v1.2.html).
