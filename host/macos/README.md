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
