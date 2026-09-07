# OrangeOS Aurora: production desktop and platform plan

Status: proposed implementation roadmap, not a claim of completed features.
Created: 2026-09-07. Target: native OrangeOS on Zest, not a website or Linux reskin.
Requested outcome: a distinctive, beautiful, responsive desktop with a real
modern browser, useful applications, and truthful hardware controls.

Revision: MacBook-first host integration, 2026-09-07. The user has no second
test machine. **The primary product/test target is OrangeOS running in QEMU on
their MacBook, with a native macOS companion bridging host services.** Wi-Fi,
Bluetooth, brightness, audio and other host integrations are explicitly in
scope. Standalone PC drivers are a later optional track, not a prerequisite for
using these features in the VM. This revision supersedes the earlier exclusion
of a host settings bridge; the bridge itself is not implemented yet.

This document governs the next desktop/platform programme. The numbered phases
below are **Aurora Phase 1, Phase 2, ...**, independent of the historical kernel
phases in [ARCHITECTURE.md](../../ARCHITECTURE.md). Existing implemented kernel
work is preserved. This plan refines [Daybreak](007-daybreak.md),
[browser feasibility](008-browser.md), and [performance](009-desktop-performance.md).

## 1. Non-negotiable delivery rules

- A feature is done only when its real backend, UI, failure states, automated
  tests, and manual acceptance evidence exist. A mockup is a design artefact.
- Each verified milestone gets a descriptive **local Git commit**. Record its
  hash, test commands, measurements, screenshots and outstanding limitations.
  Never push without the user's explicit permission.
- Preserve the from-scratch kernel. Existing browser engines/libraries may be
  ported with attribution and license compliance. The old blanket claims
  "every line ours" and "zero copyleft" must be reconciled before importing
  third-party engine code; the project's license does not replace theirs.
- No fake Wi-Fi signal, battery percentage, Bluetooth pairing, audio slider,
  browser page, or permanent-delete button. Unsupported is a valid UI state.
- No Unicode emoji as icons. Use original SVG artwork and licensed font assets;
  platform-inspired hierarchy, not copied Apple branding or restricted fonts.
- Keep changes reviewable. Separate UI work from ABI changes and migrations.
  Do not call an untested phase production-ready or mark it done in README.
- No second PC or new peripheral is required to progress the MacBook release.
  Test existing hardware/services on the user's Mac; unavailable peripheral
  scenarios use protocol fixtures and remain explicitly unqualified physically.
- Bridge controls may change the **Mac's** state, affecting other applications.
  Obtain per-capability host consent, expose scope in the UI, and provide an
  always-reachable host disconnect control. Planning permission is not permission
  to turn off the user's Wi-Fi, unpair devices, capture media, or erase disks now.

## 2. Baseline: what exists, what does not

Source-audited on 2026-09-07; source presence is not physical-device certification.

| Area | Current evidence | Gap |
|---|---|---|
| Display | Peel CPU compositor, damage tracking, 2x backing, glass and overview caches | Atomic frame ownership, vblank/presentation feedback, GPU backend, real resize |
| Apps | Welcome, Terminal, Clock, About, read-only Files and Trash | Browser, editor, search, settings services, app lifecycle robustness |
| Network | e1000, IPv4/DHCP/DNS/TCP in `kernel/net/` | Wi-Fi driver/802.11 management, TLS/trust/entropy, asynchronous socket API |
| Audio | `kernel/drivers/audio/hda.zig`: tone playback, stop, position | PCM streams, mixer, routes, userspace service, volume UI |
| USB | xHCI and HID input | General hotplug/transfer lifecycle, Bluetooth HCI transport, broad class support |
| Power | ACPI table discovery, MADT/MCFG | AML device methods, battery, backlight, suspend/resume and thermal policies |
| Runtime | Static Zig ELF, Pulp syscall wrappers and bump arena | Reclaimable VM, C/C++ runtime, threads/TLS, FPU/SIMD task isolation |
| Storage | CitrusFS/AHCI/NVMe, read-only Files API | Durable user writes, file authority, trash transactions, profiles, recovery |
| Browser | `008-browser.md` only | No engine port, browser executable, modern web rendering or HTTPS UI |
| Mac integration | Parallels 2.0 reference has Swift host/Windows guest agents and QEMU virtio-serial wiring | OrangeOS virtio-console driver, Zig agent, Swift companion and host capability adapters |

### Current redraw audit and unfinished work

- Welcome blank-click fix: local commit `9835784`. QEMU eight-click test
  observed zero client repaint entries and identical settled pixels.
- About: `old.down != pointer.down` triggers whole-surface painting on empty
  presses/releases. Files and Trash share this pattern in `files-view/files.zig`.
  These are source-confirmed redundant repaints; transient visible flicker still
  needs per-app frame capture and instrumentation, not just final screenshots.
- Clock ignores mouse input, but rebuilds its entire gradient/glass once a
  second. That is a timer-driven publication risk, not the same click bug.
- Terminal ignores mouse-only client events and repaints on input/output work.
  This does not certify its title controls, overlap or drag paths flicker-free.
- Direct writes into shared client pixels can be sampled by unrelated compositor
  redraws. A private staging buffer reduces exposure, but a final memcpy is
  **not** an atomic buffer ownership protocol. Correct this centrally.
- The uncommitted Welcome/calendar design experiment has working shortcuts and
  month navigation, but a repeat test exposed approximately 600 ms calendar
  hover frame work under QEMU TCG. It must pass Phase 1 before shipping.

Live audit evidence: `orange-daybreak-d0z18l8q` in the host temporary directory,
reproduced with `python3 tools/app_redraw_audit.py` on the profile build. Each
app received four blank clicks, sampled 24 times. Large-scene counts exclude
menu-bar-only damage but include legitimate timer work; they are not per-app
commit counters. The stable Clock probe excludes its changing time text.

| App | Large-scene redraws during blank-click probe | Transient changed samples | Hover leaves original pixels |
|---|---:|---:|---|
| Welcome | 0 | 0/24 | Yes |
| Terminal | 0 | 0/24 | No client hover control tested |
| About | 8 | 0/24 | Yes |
| Files | 8 | 1/24 | Yes |
| Trash | 8 | 0/24 | Yes |
| Clock | 3 (timer-driven) | 0/24 in stable region | No client hover control tested |

All six settled probes restored their initial pixels. About/Files/Trash still
need no-op redraw fixes; Files' transient change warrants frame-publication
repair. Zero sampled changes is not proof of no sub-sample or physical-display
flicker. Existing desktop smoke covers title controls, dock, overview, Appearance,
cursor trails and dragging; the new calendar repeat test exposed the slow-hover
failure above. Further stress and presentation-level instrumentation remain open.

Calendar follow-up (`orange-daybreak-tv5u2zf7`): navigation, Today, blank-click
stability and Clock launch passed after adding a material cache, but warmed
scene work still included 449–491 ms frames. The optimisation is insufficient:
keep the experiment uncommitted and the Phase 1 performance gate open. Do not
report a median including cursor-only frames as calendar hover performance.

## 3. Experience direction: colour with purpose

Working design name: **Aurora**, retaining OrangeOS's citrus identity. Aim for
warmth, depth and readable structure, not additional blur over the existing UI.
Use the supplied React reference for material layering, sidebar hierarchy,
date tiles and app discovery. Its simulated services are not backend evidence.

### Design system to build once, reuse everywhere

| Layer | Proposed specification | Validation |
|---|---|---|
| Palette | Warm ivory content, deep aubergine dark mode, coral primary accent; mint/cyan supporting accents | Semantic error/success states, no colour-only communication |
| Materials | Clear glass for floating shell; softly frosted navigation; opaque reading surfaces | Text contrast over every wallpaper; reduced-transparency fallback |
| Geometry | 4-point spacing base, 8/12/16/24 spacing rhythm; 10 control, 16 window, 24 floating-panel radii | Unified AA silhouette/mask and hit regions, no corner wedges |
| Typography | Licensed Inter and JetBrains Mono initially; native shaping/fallback before multilingual UI | 1x/2x, fractional positions, long labels, Indic/RTL later |
| Icons | Original SVG family with consistent stroke, optical size, lighting and silhouette | 16/20/24 symbols; 32/48/64/128 app assets, light/dark contrast |
| Motion | 100–180 ms purposeful hover/open transitions; restrained springs only after frame pacing | No input blocked by animation; reduced motion; cancellation/reversal |
| Layout | Resizable content and genuine sidebar/toolbars, not stretching existing bitmaps | Minimum size, scrolling, zoom, keyboard focus and clipped content |

### Visible deliverables

- Shell: a calmer app-aware menu bar, compact real status indicators, beautifully
  grouped dock with running/attention states and accessible labels, useful
  launcher/search, contextual menus and a coherent notification/date centre.
- Welcome: replace the generic permanent greeting with a usable start space:
  recent files, pinned apps, personalisation, and an onboarding checklist driven
  by actual capabilities. Empty states teach; unavailable services explain why.
- Files: frosted navigation sidebar, crisp content pane, breadcrumbs, grid/list
  views, preview pane, metadata, selection and progress for real file operations.
- Browser: restrained native toolbar, clear URL/security state, vertical or
  horizontal tabs after evaluation, content-first reading and real downloads.
- Settings: searchable categories and detail panes; capability-led controls,
  pending/error states, device diagnostics and a reliable path to recovery.
- Widgets: real calendar and system data first. Weather requires an explicit
  provider, configured location, privacy policy and stale/offline indicators.
  No fabricated city, forecast, battery or notifications.

Design acceptance: review desktop, Welcome, Files, Browser, Settings, control
centre, dialogs and failure states as one contact sheet. User approval of this
coherent direction precedes an OS-wide restyle. A web prototype may communicate
the design but does not count as the native implementation.

## 4. Architecture and service ownership

```text
Native apps / Aurora shell / Browser chrome
             |
Segment components + typography + accessibility semantics
             |
Versioned Pulp client APIs / capability-scoped IPC
             |
Peel | Settings | Files | Network | Audio | Devices | Power | Secrets
             |
Zest: process/VM, scheduler, IPC, VFS, sockets, driver interfaces
             |
QEMU virtual devices OR explicitly supported physical devices
```

The primary MacBook backend extends this stack as follows:

```text
OrangeOS Settings / Control Centre / applications
       | versioned, capability-scoped guest IPC
OrangeOS integration service + Zig guest agent
       | virtio-serial (control/events; independent of guest networking)
QEMU per-VM Unix socket
       | bounded authenticated session
OrangeOS Mac Companion (Swift, user session, visible permissions)
       | allowlisted adapters and macOS consent
CoreWLAN | Bluetooth APIs | CoreAudio | display/power | approved file/media APIs
       | macOS-owned drivers
The user's MacBook hardware

Separate data paths:
Guest TCP/TLS -> e1000 virtual NIC -> QEMU NAT -> Mac's active network
Guest PCM -> HDA -> QEMU CoreAudio -> selected Mac speaker/headphone route
Guest display/input -> QEMU presentation/input backend -> Mac screen/keyboard
```

Control bridging does not require pretending the guest owns Apple's radio or
GPU driver. macOS retains the hardware drivers; OrangeOS implements the virtual
drivers and explicit service adapters. The guest browser still runs its native
engine and TLS; the companion is not a hidden remote web renderer.

These service names describe **planned logical ownership**, not existing
executables. Small services may initially share a supervised process; public
contracts must not depend on that placement. Peel owns rendering/window policy,
not Wi-Fi credentials, TLS validation or filesystem mutation. Seed supervises
services with bounded restart/backoff and health reporting.

### Common API contract (proposed, not the current ABI)

- Version negotiation and feature discovery precede use. Bounded messages carry
  `version`, `opcode`, `request_id`, `payload_length`; kernel-provided peer
  identity/capabilities are authoritative, never caller-supplied admin flags.
- Query snapshot plus subscribe for changes; include generation/sequence and
  resynchronise after missed events or service restart. Bound queue memory.
- Long operations return an operation ID and states: queued, running, succeeded,
  failed, cancelled. Deadlines, cancellation and disconnect cleanup are required.
- Stable device/object IDs include generations to reject stale handles after
  hotplug/reuse. Validate lengths, shared-memory ranges and integer overflow.
- Errors distinguish unsupported, absent, permission denied, busy, timed out,
  invalid argument, disconnected and internal failure. UI maps these explicitly.
- Sliders coalesce/rate-limit requests; keep desired and observed values separate.
  Only observed state drives the final switch/slider indicator. Roll back or
  display failure; never make an unsupported operation appear successful.
- Secrets are opaque handles, not broadcast event payloads or serial logs.
  Audit privileged changes without passwords, cookies or browsing content.

### UI-to-backend connection matrix

| UI | Planned operations/events | Backend/device path | Required failure checks |
|---|---|---|---|
| App launcher/dock | list, launch, activate, close; lifecycle events | App registry → Seed/process manager → Peel | missing binary, OOM, crash, hung close |
| Window controls | configure/ack, present/release, focus, minimize | libpeel v2 → Peel → display backend | stale buffer, dead client, resize race |
| Files/Trash | list/watch, open, atomic write, move, trash, restore | Files service → VFS/CitrusFS/block driver | full disk, name collision, unplug, crash |
| Search/recent files | scoped query, indexing progress | bounded index + Files/app registry | no access, stale entry, cancelled query |
| Appearance | get/set/watch theme, wallpaper, scale | Settings store → Peel/toolkit subscriptions | corrupt image, failed persistence, mode rollback |
| Network menu | enumerate links, link state, DHCP/DNS state | Network service → sockets/e1000 or NIC driver | link loss, no lease, DNS failure, captive portal |
| Wi-Fi panel | scan, connect, disconnect, radio state | guest network service → Mac bridge → CoreWLAN; guest packets continue through virtual NIC | denied/redacted location data, bad key, host-wide disconnect, timeout |
| Bluetooth panel | discover, pair/connect where supported, service operations | guest Bluetooth broker → Mac bridge → CoreBluetooth/IOBluetooth adapters | denied access, unsupported profile/control, pairing rejected, host-owned device conflict |
| Volume/sound | enumerate routes, PCM stream, gain/mute | guest Audio service → HDA/QEMU/CoreAudio; host route metadata/control through bridge | absent codec, underrun, permission denied, route loss |
| Brightness/display | enumerate capability/range, set/get backlight | guest display service → Mac bridge → validated host display backend | unsupported OS/display API, denied access, invalid range, timeout |
| Battery/power | host battery/AC status, VM suspend/resume policy | guest Power service → Mac bridge → IOPowerSources and host lifecycle notifications | no battery, stale snapshot, sleep disconnect, permission denied |
| Airplane mode | aggregate requested radio policy and readback | Network + Bluetooth services → radio controls | partial failure; Ethernet is not a radio |
| Date/calendar | wall clock, timezone, calendar state | Time/settings service → RTC, later time synchronisation | invalid clock, timezone change, offline sync |
| Notifications | post/list/dismiss, action handles | notification service + app identity policy | flood, stale action, denied source |
| Browser | sockets/TLS, fonts, surfaces, file picker, permissions | engine adapters + network/process/file brokers | invalid cert, renderer crash, denied device access |
| Clipboard/file picker | offer/request typed data, scoped file grants | session broker → capability handles | oversized data, cross-app leakage, expired grant |

### Frame publication v2

Create two or three validated buffers per surface. Clients draw only into owned
buffers; `present(buffer_id, generation, damage, sequence)` transfers ownership.
Peel adopts a complete buffer at a composition boundary and sends a release
before the client may reuse it. Define acquire/release memory ordering across
CPUs. No compositor sampling from a buffer currently writable by a client.
Validate dimensions, stride, scale, quotas, dirty rectangles and stale IDs.
Coalesce obsolete frames; never lose key/button transitions. A resize has
configure/ack and buffer-generation transitions, not an in-place size mutation.
Start with a compatibility bridge for old clients; remove after migration.

## 5. MacBook-first hardware integration

### Supported modes and development priority

| Mode | Purpose | Qualification |
|---|---|---|
| MacBook + QEMU + Mac Companion | Primary desktop product, host service integration and all current development | End-to-end tests on the user's existing MacBook |
| MacBook + QEMU without companion | Safe basic desktop/network fallback | Bridge loss must not hang or prevent guest boot |
| User-selected USB passthrough | Optional exclusive device access where host/QEMU support it | Per-device consent and driver tests; never required for built-in host bridges |
| Standalone x86 PC / native Apple Silicon | Future independent deployment tracks | Deferred; no second computer purchase or physical-driver gate for the VM release |

Record the actual host OS, architecture, QEMU build and adapter versions for each
test; do not infer them from screenshots or an older project's README. Read-only
checks this revision reported macOS 15.7 (24G222), arm64, QEMU 11.1.0; model/RAM
sysctl access was denied in the current tool environment. These are provisional
tool-environment observations, not a complete inventory or device certification.

The UI can say **Mac Wi-Fi**, **Mac Bluetooth**, **Mac display brightness** and
**Mac battery** with live bridge data. Guest virtual-network status remains
separate: host Wi-Fi connected does not prove the guest has DHCP, DNS or internet.
If the companion is missing, show unavailable/stale and reconnect guidance—not
fabricated values or a generic claim that the VM can never access those services.

### Reference implementation to adapt, not blindly copy

User's project: `/Volumes/Tahoe/Users/vishwatejasb/Desktop/Parallels 2.0`.
Source inspection found `QemuRunner.swift` virtio-serial/socket setup,
`AgentServer.swift` transport/handshake, `AgentProtocol.swift` capability/RPC
messages, `VMInstance.swift` lifecycle wiring, `ClipboardBridge.swift` echo
suppression, and `guest-agent/p2agent.ps1` Windows handlers. Audio arguments
connect HDA to CoreAudio. No host Wi-Fi/Bluetooth/brightness adapters were found.

Reuse the architecture and reviewed project-owned code where appropriate; do
not import proprietary files from that project's research/extraction directories.
Windows drivers/PowerShell cannot substitute for an OrangeOS Zig agent. Review
protocol authority carefully: P2 primarily lets the host call the guest; guest
requests to change host hardware introduce a new, stronger trust boundary.

### Transport, guest drivers and lifecycle

1. Add virtio PCI discovery, bounded descriptor rings, interrupt/poll integration,
   virtio-console multiport negotiation and a named `org.orange.host` port.
   Keep kernel debug serial separate. No driver claim until fragmented traffic,
   ring exhaustion, reset and disconnect tests pass on actual QEMU.
2. QEMU creates the channel in a private per-run directory; the companion opens
   its Unix socket. No LAN listener and no unauthenticated TCP fallback. If a
   temporary development transport is necessary, document its isolation and
   removal gate; network-dependent control is not the release transport.
3. Use a versioned, bounded RPC schema with distinct request/result/event types.
   Initial control-message limit: 64 KiB, limited nesting/collections, strict
   method enums and range validation. Chunk bounded large listings; never send
   audio/video/framebuffers or arbitrary file bodies as giant JSON messages.
4. Launcher pins VM identity and provisions a short-lived session credential via
   a private boot configuration path. Verify identity/session before enabling
   operations; rotate on relaunch/restore, reject replay/stale generation IDs.
   A guest-held credential binds the VM, not a trusted app: host consent and
   method allowlists remain mandatory against a fully compromised guest.
5. Expose `host.hello`, `host.capabilities`, `host.subscribe`, `host.snapshot`,
   `host.cancel`; return capability status, provider, scope, permissions and
   supported operations. Do not confuse an open socket with completed handshake.
6. Seed supervises the Zig agent; companion reconnects with backoff. Requests
   have deadlines, cancellation, queue quotas and single-writer framing.
   Disconnect expires pending actions and marks data stale; reconnect resyncs
   state. Do not replay a radio-off, pairing or sleep request after reconnect.
7. Control plane is independent of the virtual NIC. Test it while Wi-Fi is off,
   guest DHCP fails, the Mac sleeps/wakes and the VM or companion restarts.

Planned locations: `host/macos/` (Swift companion and native adapter tests),
`userland/servers/host-agent/` (Zig agent), `userland/libs/host-services/` (typed
guest API), `kernel/drivers/virtio/` (transport), and `tools/host_bridge/`
(integration/fault tests). These paths are proposals, not installed components.

Example control flow: clicking Join in OrangeOS requests `wifi.join` with a
session-scoped network handle and host credential reference, not a shell command.
The companion verifies the VM grant and a current user gesture, obtains any
needed host consent, then returns an operation ID. Progress events distinguish
associating, connected, failed and cancelled; a fresh interface snapshot confirms
completion. The guest separately waits for virtual NIC/DHCP/DNS/HTTPS readiness.
Changing Wi-Fi in macOS updates OrangeOS through the same state subscription.
Concurrent joins are serialised per interface; stale requests cannot reconnect
over a newer user selection. The pattern applies to other host mutations.

### Complete host-service coverage register

Each row must end as implemented+tested, permission-gated, unsupported by the
tested platform, or deferred with a reason. "Complete" means this inventory and
qualified useful integration—not raw ownership of every internal Apple device.

| Capability | Proposed host/backend path | Guest implementation and MacBook test |
|---|---|---|
| Wi-Fi state/scan/join/power | CoreWLAN; host location/other permissions as required | `wifi.state/scan/join/disconnect/set_power`; confirm host readback, guest DNS/HTTPS separately; consent before disrupting connectivity |
| Bluetooth state/device management | CoreBluetooth and relevant public IOBluetooth operations, per-operation capability probe | `bluetooth.state/devices/discover/connect/disconnect`; real authorisation/events; pairing/forget/power separately qualified, never assumed from scan support |
| BLE service access | Brokered CoreBluetooth service/characteristic operations | Scoped service/device grants; read/write/notify, cancellation and payload limits; real peripheral tests only if one is already available |
| Bluetooth headphones/input | Keep device paired to macOS; share selected CoreAudio route or QEMU input | Guest audio/input works through Mac-owned peripheral when available; do not advertise raw HCI access or guest ownership |
| Speaker/output volume | HDA/QEMU CoreAudio data plane plus CoreAudio route metadata | Guest stream gain separate from host master volume; audible playback, mute, route change, device loss |
| Microphone | Explicit macOS recording consent plus per-guest/app permission | Bounded PCM transport, input meter, visible capture state; test revoke, stop, reconnect; no automatic recording |
| Built-in display brightness | Host adapter feasibility spike using documented supported interfaces first | `display.brightness.get/set`; verify physical change/readback and safe minimum; API restriction remains explicit, not a fake dim overlay |
| External monitor brightness | Display-specific supported API/DDC path if device exists | Optional; not a built-in display prerequisite or tested claim without that monitor |
| Display modes/Retina/colour | QEMU backend + guest configure/ack; CoreGraphics/AppKit host geometry | Native backing scale, resize, fullscreen, colour/ICC policy and multi-monitor metadata; no stretched framebuffer presented as real resize |
| GPU | Investigate host-supported virtual GPU/graphics transport and Metal presentation | Guest driver and rendering tests; host Metal presentation alone does not prove accelerated guest rendering |
| Keyboard/trackpad/mouse | QEMU input backend, guest HID/PS2/absolute input; optional scoped gesture messages | Capture/release, modifiers, scroll, repeat, focus loss, no double cursor; not a global keystroke logger |
| Battery/AC/power | IOPowerSources snapshots/events; host wake/sleep notifications | Host battery values with source/time; time resync, bridge reconnect, VM suspend/resume; host shutdown/sleep is separate explicit consent |
| Thermal/resource pressure | Supported process/system thermal and pressure APIs | Report available states, throttle VM policy safely; no invented temperatures, fan RPM or unsafe fan controls |
| Storage/shared folders | Virtual disks first; selected folder broker/security-scoped host access | File picker grants, traversal/symlink protection, read-only default, revoke; guest Trash never silently deletes host data |
| Clipboard/drag-and-drop | NSPasteboard plus explicit app/session grants and typed transfers | Echo suppression, size limits, file grants, revoke; background clipboard harvesting disabled |
| Time/timezone | Host clock and timezone service | UTC + timezone identity/transitions rather than fixed offset only; DST, suspend, manual clock changes |
| Camera | AVFoundation capability/permission adapter plus bounded media data plane | Explicit indicator/consent, device list, frames, revoke; needs guest media API, not just a control RPC |
| USB/removable devices | Host device metadata; approved folder/device sharing or qualified passthrough | No automatic detach of host input/storage; no raw internal-disk access; removable-device tests optional if absent |
| Host authentication/Touch ID | Optional LocalAuthentication confirmation for sensitive host operations | Return scoped approval result; never expose fingerprints, Secure Enclave keys or emulate raw biometric hardware |
| Printers, location and other optional services | Inventory then provider-specific broker/privacy review | Not silently promised; explicit capability state, no location sharing by default; additional hardware not required for core release |

### macOS compatibility and permission gates

- CoreWLAN exposes scan/association/power operations; installed SDK headers also
  document location authorisation/redaction. Bundle/sign the companion with
  accurate usage descriptions; test denied/revoked permissions and actual host
  behaviour, not only successful compilation. Prefer host-side network credential
  entry and Keychain references over passing saved passwords into the guest.
- CoreBluetooth authorisation/power state observation is not a general Bluetooth
  system power setter. Investigate supported classic-device pairing and management
  separately. A host Settings handoff is an explicit partial fallback, **not**
  completion of an automatic pair/power bridge. Do not use private symbols as if
  they were supported, or unpair the user's keyboard/headset automatically.
- Built-in Apple Silicon brightness requires a tested host-specific backend.
  Public API feasibility is a gate. If only undocumented APIs work, document
  stability/distribution/security costs and ask before adopting an experimental
  adapter; do not disable SIP/TCC or automate permission approval.
- Host-visible permissions page controls Wi-Fi changes, Bluetooth operations,
  brightness, master volume, files, clipboard and capture independently per VM.
  A launch grant is not a blanket grant for websites or guest applications.
- No arbitrary host shell execution, raw paths, root daemon, private key export,
  unrestricted DMA or credential dumping. A privileged helper, if justified,
  exposes narrowly validated XPC methods and needs explicit installation approval.
- Multiple clients may change host state. Use observed generations and fresh
  readback; do not restore stale host settings over the user's later changes.
  Tests may restore only the state they still own, with host-side recovery controls.

### MacBook-only acceptance lab

Use disposable guest disks and a test companion profile with bounded permissions.
No writes to host internal disk partitions. The old Parallels project is a
read-only reference unless the user separately requests edits.

- Unit tests: codecs, adapters with recorded redacted fixtures, permission
  transitions, timers, rate limits, stale handles, invalid/oversized requests.
- Real bridge: boot handshake/capabilities, round-trip sequence tests with guest
  networking disabled, guest/companion restart, multiple VMs, host sleep/resume.
- Real host reads: battery/AC, Wi-Fi metadata permitted by macOS, Bluetooth state,
  display/input/output capability list. Compare with host-native observations.
- Consent-based writes: brightness and volume readback; controlled Wi-Fi change
  with reconnection/recovery; Bluetooth discovery or an already-owned peripheral.
  Warn that Wi-Fi changes can interrupt this chat; never perform them silently.
- Media: microphone/camera test only when requested, visible recording indicator,
  short local test data with defined deletion; no capture during a docs update.
- Failure testing: denied/revoked permission, unavailable host API, no peripheral,
  missing companion, lost channel, corrupt payload, guest crash and resource load.
- Classify evidence as host-unit, QEMU end-to-end, real host read, real host write,
  or peripheral-qualified. Fixtures cannot satisfy real pairing/audio device gates.

## 6. Phase-by-phase execution

All phases below are **planned**, unless their evidence row is explicitly updated.
Activities may overlap after dependencies pass; the browser does not wait for
Bluetooth, optional widgets, or physical GPU support.

### Phase 1 — Rendering correctness and desktop-wide audit

Depends on: current baseline. First implementation phase.

- Instrument per-app paint, commit, composition and presentation sequences.
  Audit Welcome, About, Files, Trash, Clock, Terminal; menu, dock, overview,
  Appearance, calendar; all title controls, focus, resize/drag/overlap paths.
- Remove no-op click redraws. Cache stable materials; update only changed text
  and controls. Finish the calendar experiment's slow-hover fix before release.
- Implement frame publication v2 and migrate clients. Bound damage growth,
  IPC batches, memory allocations and expensive render work per event turn.
- Test blank clicks, repeated hover enter/leave, press-drag-cancel, rapid motion,
  clock ticks during drag, eight windows, off-screen corners, hidden apps,
  minimize/restore and popup open/dismiss on all wallpapers at 1x and 2x.

Exit: static blank clicks cause zero client commits; hover leave restores exact
pixels; no partially painted frames in sequence captures; no missed releases;
no repeatable >100 ms warmed hover frame on the documented TCG test profile.
Measure cold-open separately. Zero changed end-state pixels alone is insufficient
to prove absence of transient flicker. Save traces plus image sequences.

### Phase 2 — A coherent visual system and design approval

Depends on: baseline measurements; native roll-out requires Phase 1.

- Produce light/dark contact sheets and interactive states for the surfaces in
  section 3. Pick one coherent direction with the user; do not keep adding styles.
- Implement tokens, SVG family, common materials, contrast-aware labels, shared
  selection/hover/pressed/disabled states and reduced motion/transparency.
- Replace inconsistent one-off paints in Welcome, shell and app chrome.

Exit: approved design artefacts plus native screenshots matching the direction;
no clipped text, mismatched corners, emoji stand-ins or unusable controls.

### Phase 3 — Runtime and fault-isolation foundation

Depends on: baseline kernel; can progress alongside design after Phase 1.

- Reclaimable process mappings, unmap/protection, guarded stacks, user threads,
  TLS, wait primitives and cancellation; well-defined monotonic/wall clocks.
- Per-task FPU/SIMD state on every CPU before enabling engine/vector code.
- C/C++ ABI/runtime probes, allocation/free, atomics, exceptions/unwind policy,
  static/dynamic linking choice and reproducible cross-toolchain description.
- Process-local fault handling, exit cleanup, IPC/PTY/file/shared-memory cleanup,
  quotas and supervised service recovery. Define per-app security authority.
- Implement the minimum virtio transport/agent prerequisites for Phase 9a early.
  Host adapter feasibility and unit tests may start before the full runtime is
  complete; do not queue the Mac bridge behind the browser or standalone drivers.

Exit: cross-CPU state isolation tests; faulting process cannot panic the OS;
1,000 create/exit cycles plateau in memory/handles; allocation-failure injection
and C/C++ runtime probe suite pass. Report remaining sandbox limitations.

### Phase 4 — Durable storage, settings and capability brokers

Depends on: Phase 3 lifecycle foundations.

- User write/truncate/rename/fsync/directory operations with crash recovery and
  permissions. Never assume an API name provides transactional durability.
- Versioned settings with atomic replacement, schema migration, backup/default
  recovery and subscriptions. File picker/clipboard/app registry contracts.
- Safe trash metadata preserving original path/time, collision-safe restore,
  confirmation for irreversible deletion, cross-volume copy/move semantics.
- Secret store access policy; encrypted persistent credentials require a sound
  unlock/key source and secure randomness. Otherwise session-only, never plaintext.

Exit: fault-injected write/rename/reboot tests, full-disk recovery, permission
tests, restart-safe preferences, real create/edit/trash/restore workflows.

### Phase 5 — Secure asynchronous networking

Depends on: Phase 3; persistent trust/configuration uses Phase 4.

- Event-driven socket readiness, precise EOF/timeout/would-block errors,
  cancellation, DNS caching, DHCP/link events and bounded buffers.
- Cryptographic entropy interface and readiness gate; reviewed TLS library port,
  maintained roots, hostname/date validation and explicit clock-invalid handling.
- HTTP handling, redirects, decompression/size limits, proxy configuration and
  captive portal reporting without automatic credential submission.

Exit: real verified HTTPS fetch on guest; bad/expired/wrong-host certificates
rejected; entropy unavailable fails closed; disconnect/cancel tests pass;
UI remains responsive during slow and failed network operations.

### Phase 6 — Native modern browser engine proof

Depends on: Phase 3, Phase 5, frame API from Phase 1; storage from Phase 4 for profiles.

- Time-box dependency/build experiments for WebKit/WPE and Chromium. Pin exact
  upstream revisions and produce a dependency/license/buildability matrix.
  WPE is a candidate, **not a committed working port or proven RAM winner**.
- Select based on native cross-build feasibility, maintained patch surface,
  compatibility, security architecture and measured memory/CPU—not branding.
- Supply native event loop, thread/VM/socket adapters, Unicode shaping/fallback,
  image decoders, surfaces/input and brokered process integration.
- Bring up interpreter-only JavaScript if feasible before JIT. Enable JIT only
  with reviewed W^X and isolation. No host-rendering proxy or disabled TLS.

Exit: installed guest executable renders real HTML/CSS/JS, Unicode, forms and
verified HTTPS through Peel. Record a Web Platform Tests subset and fixed page
corpus, cold/warm startup, scrolling, crashes and memory. Local fixture proof is
not sufficient to claim a generally safe internet browser.

### Phase 7 — Browser usable alpha, then security beta

Depends on: Phase 6 and broker/storage foundations.

- Real address/search bar, back/forward/reload/stop, tabs, text selection,
  keyboard shortcuts, clipboard, zoom/find, bookmarks/history and downloads.
- Separate web content authority from trusted chrome; file chooser grants,
  camera/microphone/location permissions, navigation-origin checks and secure UI.
- Renderer/network fault containment; cookie/site-data isolation, private mode,
  quotas, background-tab suspension, cache eviction and crash/session recovery.
- Compatibility list covers forms/login, modern layouts, JS, fonts, media and
  offline/errors. DRM, codecs, WebGL/WebRTC remain explicitly qualified until tested.
- Security updates need an owner, tracked upstream advisories and repeatable
  patch/release tests. Do not freeze an old engine merely to call it lightweight.

Exit: demonstrable browsing workflows and downloads with no UI stalls, crash
containment and permission tests; published support matrix. General browsing
beta is blocked until sandbox/security gates pass. No browser launch icon before
there is an actual executable; label experimental builds accurately.

### Phase 8 — Toolkit, desktop shell and everyday applications

Depends on: Phase 1/2; persistence and brokers from Phase 4. Does not block browser proof.

- Real layout/resize, scroll containers, text editing/selection, focus navigation,
  clipboard/drag-and-drop, accessibility semantics, font shaping/fallback.
- Redesigned Files, Settings, Welcome and Terminal; editor with safe save and
  unsaved-change handling; calculator, image preview, app launcher/search.
- Date/notification centre with actual data and actionable notifications;
  calendar events only after persistent storage and timezone semantics exist.
- Consistent dialogs, error recovery, multi-window app behaviour, shortcuts and
  readable permission prompts. No decorative rows pretending to be implemented.

Exit: end-to-end daily workflows in light/dark mode, keyboard-only operation,
long content, multiple scales, and accessibility/reduced-effects checks.

### Phase 9 — Mac bridge foundation, virtual drivers and audio

Depends on: minimum Phase 3 driver/lifecycle support and IPC contracts. Start
host-side work early alongside Phases 1–3; Phase numbers group deliverables,
not a requirement to finish Phase 8 before beginning this phase.

**9a — Companion and secure channel:** inventory the current Mac, create the
Swift companion scaffold, bounded transport/schema and adapter test doubles.
Implement virtio-console/serial driver and Zig guest service; establish hello,
capabilities, permission grants, subscriptions and restart-safe session identity.
Exit: real bidirectional RPC while guest networking is disabled, no LAN listener,
malformed-message rejection, denied host operation, guest/host restart recovery.

**9b — Read-only integration:** host time/timezone, battery/AC, radio state and
audio/display capability discovery. Each value includes source, freshness and
permission state. Exit: guest values agree with host observations and become
stale/unavailable correctly on permission revocation or companion loss.

**9c — Device lifecycle and audio:** stable device IDs, hotplug/cancellation,
DMA/ring ownership; guest HDA PCM, QEMU CoreAudio, mixer, stream gain/mute and
selected Mac output route. Host master-volume changes have a separate grant.
Exit: real speaker playback/mute, responsive UI during streams, route-loss and
underrun handling. Microphone capture requires separate consent and test evidence.

**9d — Shared sessions:** approved clipboard, selected folders and input/display
integration using the section 5 contracts. Exit: revoke/close/restart, clipboard
echo suppression, safe file grants and fullscreen capture-release tests on Mac.

### Phase 10 — Mac Wi-Fi bridge

Depends on: Phase 9a/9b; Phase 5 for guest HTTPS acceptance, not for transport.

**10a — Host adapter:** implement CoreWLAN scan/state/power/association probes
and actual permission handling. Record supported security modes and method
availability on this Mac; macOS manages radio firmware, keys and regulatory policy.

**10b — Guest integration:** wire native Wi-Fi controls to allowlisted RPCs and
observed events. Display host interface state and guest virtual-network health
separately. Use host-side credential UI/Keychain grants; no saved password export.

**10c — Controlled qualification:** user-approved scan/join/reconnect and radio
off/on tests, readback, wrong-key/cancel/denied-location cases; keep serial control
alive during network loss. Protect the user's active connection and provide a
host recovery action before running disruptive tests.

Exit: OrangeOS requests a supported operation, the Mac really performs it, and
readback reaches the guest; confirm guest DHCP/DNS/HTTPS independently. NAT-only
internet is not a completed Wi-Fi control bridge. No external Wi-Fi dongle or
standalone 802.11 driver is required for this MacBook milestone.

### Phase 11 — Mac Bluetooth bridge

Depends on: Phase 9a/9b; host permission/credential policies.

**11a — State and permission:** expose host Bluetooth authorisation, availability,
supported discovery/device operations and subscribed updates. Implement public
CoreBluetooth and relevant IOBluetooth adapters, not a fictional generic HCI port.

**11b — Qualified operations:** supported device discovery/connect/service access,
pairing workflows where available, per-device grants, cancellation and safe names.
Treat system power, classic pairing, forget and BLE operations as separate
capabilities. A read-only power state does not imply a working power switch.
Unsupported automation offers a clearly labelled host Settings handoff, with the
automatic operation still marked incomplete; no private API bypass by default.

**11c — Device sharing:** keep Mac-owned headsets/keyboards paired to macOS;
expose their selected audio/input through the VM's existing virtual devices.
Native guest BLE APIs use brokered service grants rather than raw controller
ownership. Do not disconnect the user's only input device to demonstrate pairing.

Exit: state/permissions and supported control round trips verified on this Mac;
real pairing/service/audio tests qualified only for already-available peripherals.
If no peripheral exists, fixtures/negative tests let development proceed but
positive peripheral acceptance remains untested. No extra-device purchase gate.

### Phase 12 — Mac brightness, battery, power and media integration

Depends on: Phase 9a/9b, plus audio/data-plane support for capture.

**12a — Display and power:** validate a host brightness backend, range/readback,
safe limits and permission handling on the actual built-in panel. Guest controls
change real Mac brightness, with scope visible; software dimming is separate.
Read real battery/AC and thermal states through supported APIs. Synchronise
time/timezone and reconnect after host sleep/wake; never equate guest shutdown
with permission to shut down the Mac.

**12b — Shared control policy:** brightness/volume hotkeys share broker APIs.
Host radio policy (“Mac radios”) aggregates separately supported Wi-Fi/Bluetooth
operations and reports partial failure; it is not an atomic platform airplane
mode promise. Multiple host/guest actors cannot overwrite newer settings with
stale restore values. Provide host-side revoke and recovery controls.

**12c — Media and remaining inventory:** explicit camera/microphone grants,
AVFoundation/CoreAudio adapters and bounded guest media streams; recording
indicator, stop/revoke, device availability and guest-app access policy. Complete
the section 5 coverage register for optional USB, external displays, authentication
and other services; unsupported raw hardware remains explicitly scoped out.

Exit: real brightness/volume readback and physical effect, battery/AC agreement,
safe sleep/reconnect behaviour; camera/mic positive tests only with explicit
capture consent. No second machine or ACPI laptop driver prerequisite.

### Phase 13 — Accelerated presentation and premium motion

Depends on: Phase 1, Phase 3 and Phase 9.

- Separate renderer from display backend; virtio-gpu 2D scanout/fences first,
  retain CPU fallback. Then evaluate host-supported accelerated protocol/backend
  and native userspace graphics dependencies. A QEMU flag alone is not a GPU port.
- Presentation timestamps, vblank where available, buffer fences, frame pacing,
  reduced copying; bounded cached blur/shadows and independently responsive cursor.
- Apply approved motion to dock, windows and transitions only within measured
  budgets. Preserve reduced motion and degraded-performance fallbacks.

Exit: real backend capability and rendering tests, reset/recovery, correct pixels,
input/present latency measurements; explicitly separate TCG CPU emulation and
host display timing. Physical GPU acceleration is its own chipset-qualified gate.

### Phase 14 — Security, updates and recovery

Depends on: Phase 3–7 foundations; starts as a requirement, not late security polish.

- Threat model hostile web content/files/USB/network, compromised apps and
  privileged-service inputs. Fuzz parsers, IPC lengths, image/font codecs and drivers.
- Least authority, process sandbox, secret access prompts, secure session/lock
  behaviour, supply-chain manifests/SBOM and component license notices.
- Include a fully compromised guest in the Mac Companion threat model. Test
  arbitrary-method rejection, file/path escapes, capability revocation, replay,
  guest-web-content access denial and no background host microphone/camera use.
- Signed update manifests, authenticated downloads, anti-rollback policy,
  transactional install/rollback and recovery boot. Offline key management.
- Error reporting is local by default; opt-in telemetry excludes secrets and URLs.

Exit: security regression suite, independent review of critical trust boundaries,
update tamper rejection and interrupted-update recovery. No production label
solely because UI tests passed.

### Phase 15 — MacBook VM installation and integration qualification

Depends on: relevant VM/bridge/security gates. No second test computer required.

- Package QEMU configuration, guest image, signed companion and versioned agent
  together with checked compatibility. Guided host permission onboarding and a
  clear uninstall/revoke path; no silent helper or login-item installation.
- VM creation/import, safe snapshots, crash recovery, update/rollback and guest
  data export. Snapshot credentials/session IDs expire or rotate on restore.
- Qualify built-in Mac display/input/network/audio/power paths; test host sleep,
  lid open/resume, companion exit, VM crash and disk pressure using disposable
  images. Do not claim suspend persistence before state-save tests pass.
- Never repartition or install OrangeOS over macOS. Optional standalone x86
  installation/drivers and native Apple Silicon boot are deferred tracks, not
  prerequisites for this release or a requirement to obtain more hardware.

Exit: repeatable install/start/stop/update/recovery on the user's MacBook and a
published integration matrix distinguishing verified, denied, unavailable and
not-yet-tested operations; no unintended host data or settings mutation.

### Phase 16 — Release candidate and production readiness

Depends on: all features advertised for the release pass their gates; unsupported
hardware must be excluded from the advertised compatibility matrix.

- Reproducible release image, signed artefacts, migration/recovery documentation,
  accessible onboarding, crash reports, performance dashboards and release notes.
- 24-hour initial soak, extended multi-day release soak, repeated app/browser
  open/close, concurrent downloads, disk pressure, hotplug and service failures.
- Browser update rehearsal, corrupted-settings recovery, usability review and
  an explicit list of deferred features. No "all hardware" or "all sites" claim.
- MacBook-first release qualifies every advertised bridge operation; companion
  absence has a tested graceful fallback. Peripheral-only features without actual
  device evidence are not advertised as tested. No unsupported API is hidden.

Exit: release checklist with evidence and no untriaged critical reliability,
security, data-loss or input-blocking bugs. User review before publication.

## 7. Budgets, performance gates and measurement

Baseline guest allowance: **3 GiB RAM and 2 CPU cores**. Additional RAM, CPU or
GPU resources are permitted when justified, as authorised by the user; document
why, compare results, and retain the baseline where feasible. Host build RAM is
separate from guest runtime RAM. No promise that arbitrary websites fit a fixed cap.

Proposed initial planning allocations within the 3 GiB baseline (not measurements):
kernel/services 384 MiB, shell/apps/render caches 512 MiB, browser workload 1536
MiB, reserve 640 MiB. Sum: 3072 MiB. Reconcile allocator/page-cache/shared-buffer
accounting to avoid counting shared pages twice. Pressure triggers bounded cache
eviction/tab suspension or a visible resource limit, never an unexplained hang.

- Record warm/cold startup, frame-work p50/p95/p99, input-to-present latency,
  publication gaps, allocations, resident pages, handles and per-app CPU.
- Initial TCG gate: warmed hover p95 under 50 ms and no reproducible >100 ms
  frame in the fixed idle/8-window corpus; report cold material capture separately.
  Targets require baseline calibration, not retrospective selective reporting.
- Native/accelerated target: 60 Hz presentation budget (16.7 ms), later higher
  refresh when supported. Do not claim this from cursor-copy timing or idle CPU.
- Rendering races, missed button releases and corrupt pixels are hard failures
  regardless of average speed. Test overlapping live content and clock rollover.
- Use fixed local browser pages for deterministic tests plus a dated real-site
  corpus. Report content features and exclusions, not only screenshots.

## 8. Execution ledger and honest prioritisation

| Milestone | Status | Evidence / next action |
|---|---|---|
| Production plan | Written; awaiting iterative review | This document; no hardware/browser completion implied |
| MacBook-first bridge architecture | Planned; explicitly in scope | Swift companion + Zig guest agent; no standalone driver prerequisite |
| Bridge 9a / 9b | Read-only transport proof verified; production gates open | [Mac companion and guest bridge](../../host/macos/README.md): authenticated named virtio port, boot-only agent grant, live host time/timezone/version, reconnect and negative probes; no Control Centre binding or hardware adapters yet |
| Host Wi-Fi / Bluetooth adapters | Not implemented | Phases 10/11: independent operation/permission/real-host gates |
| Host display / audio / media / power | Not implemented in OrangeOS | Phase 9c/12; qualify built-in devices on user's Mac |
| Welcome blank-click fix | Verified locally | `9835784`, `tools/welcome_smoke.py` |
| Whole-desktop flicker audit | Initial six-app CLI pass complete; expanded stress open | About/Files/Trash 8 redraws per 4 blank clicks; Files 1 transient sample |
| Welcome/calendar experiment | Uncommitted, not release-ready | Calendar slow-hover regression must be resolved |
| Aurora Phase 1 | Planned beyond the targeted Welcome fix | Shared publication, all-app audit and performance gates |
| Aurora Phases 2–16 | Planned | Update each only with tests and local commit evidence |

Immediate order: finish the all-app baseline audit; fix rendering/publication and
calendar slowdown; agree the design system. In the next platform work, start
Phase 9a companion/schema/transport and minimum Phase 3 runtime together, then
9b host readback and Wi-Fi/Bluetooth adapter probes. Runtime/HTTPS/browser proof
continues as its own critical path; wireless and optional motion do **not** block
it. No standalone hardware purchase or driver port is on either critical path.

Track bridge milestones individually: 9a channel/security, 9b observed host
state, 9c audio, 9d session sharing, 10a–10c Wi-Fi, 11a–11c Bluetooth, 12a–12c
display/power/media. Each needs its own evidence and successful local commit.
The Mac Companion may support these without altering native desktop design
goals; it does not replace the browser engine or convert OrangeOS into a website.

This is a substantial OS programme, not a one-turn skin change. Estimate each
phase after its dependency spike; do not invent completion dates. Major risks:
engine port complexity/maintenance, device documentation/firmware licensing,
memory reclamation, sandbox correctness and host GPU limitations. Each spike
ends with evidence, a bounded next milestone or a documented go/no-go decision.
Do not silently substitute a text fetcher or a hosted browser if a port is blocked.

## 9. Primary engineering references

Reviewed on 2026-09-07; recheck and pin relevant versions at implementation time.

Mac integration reference evidence: the user's P2 sources listed in section 5,
plus installed Xcode SDK CoreWLAN `CWInterface.h` (scan/association/power and
location restrictions) and CoreBluetooth `CBManager.h`/`CBCentralManager.h`
(authorisation and operation contracts). No radio/control operation was invoked
while updating this plan.

- [Apple CoreWLAN CWInterface](https://developer.apple.com/documentation/corewlan/cwinterface):
  host Wi-Fi API reference; installed SDK headers were used where the web viewer
  could not render Apple's Markdown documentation.
- [Apple CoreBluetooth authorisation](https://developer.apple.com/documentation/corebluetooth/cbmanager/authorization-swift.type.property):
  access state must be checked; a denied permission is not successful integration.
- [Apple IOBluetooth](https://developer.apple.com/documentation/iobluetooth):
  candidate classic-device API reference; specific methods/OS behaviour need probes.
- [Apple IOKit](https://developer.apple.com/documentation/iokit): host device/power
  interface reference, not proof that arbitrary Apple Silicon brightness controls
  are supported.
- [Apple capture authorisation](https://developer.apple.com/documentation/avfoundation/requesting-authorization-to-capture-and-save-media):
  reference for explicit camera/microphone access; no capture is enabled by this plan.

- [WebKit WPE](https://webkit.org/wpe/): embedded engine direction; does not
  supply an OrangeOS runtime or establish the cost of this port.
- [Chromium Ozone](https://chromium.googlesource.com/chromium/src/+/main/docs/ozone_overview.md):
  input/graphics abstraction; not a full operating-system compatibility layer.
- [QEMU USB](https://www.qemu.org/docs/master/system/devices/usb.html): virtual
  devices and host-device access possibilities; verify installed host support.
- [QEMU virtio-gpu](https://www.qemu.org/docs/master/system/devices/virtio/virtio-gpu.html):
  2D and accelerated backends have different host/guest requirements; do not
  assume documented Linux configurations run unchanged on this Mac or Zest.
- [Bluetooth Core specification](https://www.bluetooth.com/specifications/specs/core-specification-6-1/):
  controller/protocol/security reference, with required errata and profile-specific
  qualification work. This plan makes no Bluetooth compliance claim.
