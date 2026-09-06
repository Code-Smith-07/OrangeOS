# OrangeOS Aurora: production desktop and platform plan

Status: proposed implementation roadmap, not a claim of completed features.
Created: 2026-09-07. Target: native OrangeOS on Zest, not a website or Linux reskin.
Requested outcome: a distinctive, beautiful, responsive desktop with a real
modern browser, useful applications, and truthful hardware controls.

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
| Wi-Fi panel | scan, connect, disconnect, radio state | wireless service/supplicant → 802.11 driver/firmware | bad key, rfkill, timeout, regulatory restriction |
| Bluetooth panel | discover, pair, connect, forget | Bluetooth service → HCI → supported USB controller | rejected pairing, removed adapter, lost link |
| Volume/sound | enumerate routes, PCM stream, gain/mute | Audio service → HDA initially | absent codec, underrun, route loss |
| Brightness/display | enumerate capability/range, set/get backlight | Display/Power service → ACPI or GPU backlight backend | no physical backlight, invalid range, timeout |
| Battery/power | status/health, policy, sleep/wake requests | Power service → ACPI AML/EC/platform backend | absent battery, device refuses suspend, wake failure |
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

## 5. Hardware reality and test targets

| Target | Honest capability | Not implied |
|---|---|---|
| Current Mac + x86_64 QEMU TCG | Emulated CPU, virtual NIC/disks/display/input; selected optional devices | Direct Mac Wi-Fi/Bluetooth/backlight, native x86 CPU speed or GPU acceleration |
| Explicitly attached USB device | Possible testing route after host/backend support, device permission and guest driver verification | USB enumeration alone is not Wi-Fi or Bluetooth support |
| Selected x86_64 UEFI PC | Real device work against recorded PCI/USB IDs and firmware | Universal laptop compatibility or safe install to every disk |
| Apple Silicon native boot | Separate architecture/platform programme | Implied by running this x86 guest on a Mac |

For virtual Ethernet show **Ethernet**, even when the Mac uses Wi-Fi upstream.
For QEMU brightness show **No hardware backlight exposed**; a separate optional
"Dim desktop" effect must be labelled software dimming. No host settings bridge
is authorised or implied. A future explicit bridge is a separate security model.

Select one reference x86 PC and one documented radio adapter per feature after
inventory. Record exact IDs, revisions, firmware source/license, transport,
interrupt/DMA requirements and reproducible tests. Do not promise all chipsets.
USB passthrough and destructive disk installation require explicit target choice;
do not detach the user's only input/network device or overwrite personal disks.

Wi-Fi requires a radio driver, firmware lifecycle, scan/association, key handling,
802.11 security integration and regulatory controls—not just a TCP stack.
Bluetooth requires controller transport, HCI, L2CAP/security and selected profiles;
start with one real HID profile, not an immediate promise of every headset.
Backlight/battery require actual platform methods or driver registers and tested
readback. ACPI table parsing alone does not provide those methods.

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

### Phase 9 — Device framework and real audio control

Depends on: Phase 3 service lifecycle and API contracts.

- Stable device discovery, capability queries, driver bindings, hotplug events,
  cancellation, DMA ownership and recovery on device loss.
- HDA PCM playback/capture where supported, ring/stream scheduling, mixer,
  route selection, gain/mute and per-app audio permissions. Connect Settings
  and control centre to readback, not a local UI variable.
- Define supported controller/codec matrix and QEMU audio fixture explicitly.

Exit: audible test stream with verified gain/mute and route changes; no underrun
storm or OS hang; unplug/restart and denied-microphone tests pass.

### Phase 10 — Real Wi-Fi

Depends on: Phase 3/5/9; Phase 4 for saved credentials.

- Inventory/select one supported adapter with available documentation and
  redistributable firmware. Record chipset/revision, not merely retail name.
- Implement driver transport/DMA/interrupts/firmware; integrate scan, association,
  encryption/key installation and a reviewed supplicant/security stack.
- Capability-led WPA2/WPA3 support, regulatory/rfkill handling, reconnection,
  saved network policy and power management. Never log passwords.
- Connect panel to actual scan results and radio/link state. Unsupported security
  modes remain unavailable, not silently downgraded.

Exit: selected physical adapter scans and joins a real authorised access point,
obtains a lease, resolves DNS and loads HTTPS in guest; wrong-password, radio-off,
AP loss, restart and hotplug tests pass. QEMU Ethernet is not this acceptance test.

### Phase 11 — Real Bluetooth

Depends on: Phase 3/9, Phase 4 for secure bonding data.

- Select one documented HCI controller; USB endpoint and transfer support before
  HCI commands/events/ACL, then L2CAP, discovery, pairing/bonding and security.
- Implement and test an explicit first profile (HID input), connection/forget
  policy and reconnect. Headset audio is separate A2DP/HFP or LE Audio work,
  including codec/routing dependencies; not implied by successful pairing.
- UI shows discovered names safely, pairing consent/passkeys and real link state.

Exit: pair and use a real supported peripheral; deny/cancel/forget/reconnect and
adapter removal work; no silent pairing or leaked keys. Publish profile matrix.

### Phase 12 — Display brightness, battery and power controls

Depends on: Phase 9 and selected physical reference machine.

- ACPI AML/platform device support with checked method evaluation; implement
  supported backlight capability/range/read/set via ACPI or display driver.
- Real battery/AC/charge readout, power policies, thermal reporting and safe
  shutdown; suspend/resume only after per-device quiesce/restore is reliable.
- Brightness slider reconciles hardware readback; external displays need their
  own supported path. Never label an alpha overlay hardware brightness.
- Airplane mode aggregates Wi-Fi/Bluetooth policy, surfaces partial failures and
  maintains user preferences. Brightness/volume hotkeys reuse service APIs.

Exit: observed physical brightness change and readback, real AC/battery events,
safe range limits and recovery; suspend requires repeated successful wake tests.
VM unavailable states are tested independently and do not count as hardware passes.

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
- Signed update manifests, authenticated downloads, anti-rollback policy,
  transactional install/rollback and recovery boot. Offline key management.
- Error reporting is local by default; opt-in telemetry excludes secrets and URLs.

Exit: security regression suite, independent review of critical trust boundaries,
update tamper rejection and interrupted-update recovery. No production label
solely because UI tests passed.

### Phase 15 — Physical installation and supported-hardware qualification

Depends on: relevant driver/power/security gates and explicit user-selected media.

- Read-only live boot first, inventory/report, then a safe installer with exact
  disk identification, partition preview, backup guidance and explicit erase consent.
- Run storage/network/input/audio/power/display qualification on the reference PC;
  document IDs, firmware and known unsupported devices. Test recovery independently.
- No automatic writes to the Mac's internal disk. Native Apple Silicon remains
  a separately scoped architecture/driver programme, not promised by this release.

Exit: repeatable boot/reboot/install/recovery on named reference hardware, no
unintended disk mutation, complete compatibility report.

### Phase 16 — Release candidate and production readiness

Depends on: all features advertised for the release pass their gates; unsupported
hardware must be excluded from the advertised compatibility matrix.

- Reproducible release image, signed artefacts, migration/recovery documentation,
  accessible onboarding, crash reports, performance dashboards and release notes.
- 24-hour initial soak, extended multi-day release soak, repeated app/browser
  open/close, concurrent downloads, disk pressure, hotplug and service failures.
- Browser update rehearsal, corrupted-settings recovery, usability review and
  an explicit list of deferred features. No "all hardware" or "all sites" claim.

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
| Welcome blank-click fix | Verified locally | `9835784`, `tools/welcome_smoke.py` |
| Whole-desktop flicker audit | In progress | About/Files/Trash redundant redraw identified in source |
| Welcome/calendar experiment | Uncommitted, not release-ready | Calendar slow-hover regression must be resolved |
| Aurora Phase 1 | Planned beyond the targeted Welcome fix | Shared publication, all-app audit and performance gates |
| Aurora Phases 2–16 | Planned | Update each only with tests and local commit evidence |

Immediate order: finish the all-app baseline audit; fix rendering/publication and
calendar slowdown; agree the design system; start runtime/HTTPS/browser proof.
Wireless and optional motion do **not** postpone the browser critical path.

This is a substantial OS programme, not a one-turn skin change. Estimate each
phase after its dependency spike; do not invent completion dates. Major risks:
engine port complexity/maintenance, device documentation/firmware licensing,
memory reclamation, sandbox correctness and host GPU limitations. Each spike
ends with evidence, a bounded next milestone or a documented go/no-go decision.
Do not silently substitute a text fetcher or a hosted browser if a port is blocked.

## 9. Primary engineering references

Reviewed on 2026-09-07; recheck and pin relevant versions at implementation time.

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
