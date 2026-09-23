# OrangeOS native Chromium browser architecture

Status: **Phase 1 preparation in progress; no browser engine is installed or qualified**.
Created: 2026-09-23. Owner requirement: a smooth, full-featured browser running
entirely inside OrangeOS, within a 4 GiB desktop profile, with excellent video
playback and hardware-dependent 8K support.

"Chrome OS native browser" means a **Chromium-based browser native to OrangeOS**
in this document. It does not mean replacing Zest with Google ChromeOS, Linux,
or a host browser. The product name is provisional: **Orange Browser**.

This document supersedes the provisional WebKit-first engine direction in
[008-browser.md](008-browser.md). That document retains the runtime implementation
ledger. This plan refines the browser, runtime, graphics and media work in
[the production desktop plan](010-production-desktop-plan.md); it does not mark
those phases complete. All numerical performance budgets below are **proposed
acceptance targets, not measured results**.

## 1. Product contract and non-goals

- Keep Zest and Peel. Port a maintained upstream engine; do not write HTML/CSS,
  JavaScript, cryptography or codecs from scratch.
- All browser UI, Blink/V8 execution, network/TLS processing, profiles and media
  pipeline orchestration run in guest processes. No host WebView, page streaming,
  remote renderer, TLS-stripping proxy or nested Linux browser appliance.
- A virtual graphics device may execute guest-issued graphics operations using
  the host GPU, as normal VM hardware virtualization. This is not permission to
  move the browser engine or its profile to the Mac. No custom host decoding
  service is assumed; guest-visible accelerated devices require separate proof.
- Deliver real navigation, tabs, downloads, bookmarks, permissions and recovery.
  A static page, browser-shaped window or engine test shell is not a finished browser.
- Keep sandboxing, site isolation, certificate verification and timely security
  updates. Never trade them for a lower RAM screenshot.
- Aim for essential modern websites, not an untestable promise of every site.
  Protected streaming, proprietary integrations and extension compatibility have
  explicit gates; Chromium reuse alone does not certify them.
- Retain original SVG icons, licensed fonts, crisp scale-aware rendering and a
  restrained glass interface. Browser controls must stay responsive during load.
- Make a descriptive local commit after each verified phase and report its hash,
  tests and limitations. Push only with explicit user authorization.

## 2. Engine and maintenance decision

**Leading candidate: upstream Chromium, with an OrangeOS platform port and a
minimal browser interface.** Use its existing engine and resource-management
mechanisms before creating parallel implementations.

Phase 1 must pin an upstream revision and decide the smallest sustainable
embedding surface. Chromium `content_shell` is a bring-up/test target, not the
shipping browser. Evaluate retaining Chromium's browser layer against CEF;
prefer the option with less long-lived downstream maintenance, not the fewest
lines in the toolbar. CEF can simplify integration but still carries Chromium.
Its separate Alloy bootstrap was removed in M128; Alloy style is not a tiny
independent engine [S2]. Do not promise CEF or Chrome extensions until tested.

WPE WebKit remains a documented fallback if the feasibility gate fails, not a
second engine to ship by default. Changing engines needs a recorded decision
and user agreement. Do not silently replace modern browsing with NetSurf.

Keep platform adaptations localized: toolchain/build configuration, OS services,
Ozone/Peel, audio and graphics/video adapters. Avoid invasive Blink/V8 changes.
The runtime libraries and SDK must be reusable by other upstream applications.
Source portability is the initial objective; running existing Linux Chrome
binaries unchanged requires a separate Linux ABI project and is not promised.

## 3. Current baseline and blockers

Baseline checked against the repository on 2026-09-23:

| Area | Present | Required before browser qualification |
|---|---|---|
| CPU/runtime | Static freestanding Zig/C ELF; x87/SSE2 isolation; C ABI probes | libc/libc++, user threads, TLS, synchronization, upstream library tests |
| Virtual memory | Owned anonymous mappings; 256 MiB arena, 64 MiB per mapping in `kernel/mm/user_vm.zig` | Large sparse reservations, partial mapping operations, file/shared mappings, concurrent VM and cross-CPU TLB correctness |
| Process lifecycle | Fault containment and private page reclamation | Complete task/descriptor/socket/IPC reaping; quota accounting; stress beyond scheduler's current 64 task slots |
| Networking | DNS and blocking TCP | Precise EOF/error semantics, async readiness, cancellation, entropy, authenticated TLS and trust updates |
| Storage | Existing CitrusFS and read-only user file interfaces | Durable writable profiles, transactions/locking, larger installation image and cache quotas |
| Graphics | CPU framebuffer and Peel compositor | Chromium Ozone adapter; atomic buffer ownership; presentation feedback; accelerated device/backend |
| Audio | HDA tone/stop/position API in `kernel/drivers/audio/hda.zig` | Continuous PCM service, mixer, timing, underrun recovery and browser audio adapter |
| Video | No qualified browser decoder path | Software codec integration, sandboxed hardware decode, shared video surfaces and A/V synchronization |
| Preview | x86-64 QEMU, default 3 GiB/2 vCPUs; explicit 4 GiB browser profile; Cocoa fullscreen | Qualified GPU/device backend and reproducible media test harness |

The current 32 MiB root image is not a browser installation volume. Its layout,
installer and persistent storage must be expanded deliberately, preserving user
data and rollback. The existing per-process VM bounds cannot be treated as a
4 GiB browser runtime merely by changing QEMU's `-m` option.

## 4. Deployment and resource profiles

### 4.1 Browser baseline: 4 GiB total guest RAM

4 GiB means **4096 MiB for the entire guest**, not 4 GiB for the browser plus
unlimited graphics allocations. Two CPU cores remain the baseline. Additional
cores/RAM can define an explicitly labelled higher-capability profile.

Initial working budget, to revise using measurements:

| Account | Planning allowance |
|---|---:|
| Kernel, services, Peel and desktop apps | 640 MiB |
| Browser UI, networking and utility processes | 384 MiB |
| Active renderer processes combined | 1664 MiB |
| Shared GPU/media buffers and related graphics allocations | 768 MiB |
| Available/reclaimable headroom | 640 MiB |
| **Total** | **4096 MiB** |

These are tuning envelopes, not permission to allocate all accounts eagerly.
Count each shared physical page once; separately show per-process private and
proportionally attributed shared memory. The graphics account includes surfaces
already mapped into browser processes, not a second copy of their charge.
Include page tables, kernel objects, image/code pages and non-reclaimable caches.
Count borrowed/host-backed resources in the overall VM footprint report too.
On unified-memory GPUs, graphics storage is not free extra RAM. Dedicated VRAM
is measured separately, with a configurable cap and allocation-failure path.

Initial pressure policy: warn/reclaim near 80% physical occupancy, actively
discard eligible background contents near 90%, and protect at least 256 MiB
emergency headroom. Occupancy excludes immediately reclaimable caches; tune
thresholds with hysteresis and measured recovery times. Quotas, not voluntary
JavaScript cooperation, must contain runaway renderers. Prefer terminating an
offending renderer with a recoverable tab error to wedging the desktop.

The explicit 4 GiB launch/test profile is implemented without changing the
desktop's 3 GiB default. See section 11.1 for commands and qualification.
A larger browser installation disk and persistent profile storage remain pending.

### 4.2 Separate correctness from performance qualification

| Profile | Role | Claims allowed |
|---|---|---|
| Current MacBook x86-64 QEMU/TCG | Functional bring-up and security regression | Actual observed results only; no assumed hardware decoding or 60 fps |
| Accelerated VM on a verified backend | Guest GPU, presentation and media qualification | Only capabilities actually exposed to and exercised by the guest |
| Supported physical device, future | Native driver and decoder qualification | Per-device, per-codec resolution/frame-rate results |

Apple Silicon cannot hardware-virtualize the current x86-64 CPU as an ARM guest.
An ARM64 OrangeOS port is a separate potential performance project, not silently
included in the browser port. No second PC is required to advance functional
work; missing accelerated hardware results remain **unqualified**, not simulated
passes. Do not claim Mac hardware decoder availability from the Mac model alone.

Build resources are distinct from runtime resources. Chromium's documented Linux
build baseline is at least 8 GB RAM and 100 GB free disk, with more than 16 GB RAM
recommended [S3]. Check local free space and toolchain architecture before fetching
large dependencies; agree a build location rather than deleting unrelated files.
Cross-compiling outside OrangeOS is allowed; execution remains inside OrangeOS.

## 5. Native process and service architecture

```text
Guest browser UI / privileged permission broker
  |-- sandboxed site renderer(s): Blink + V8
  |-- restricted network service: DNS, HTTP, TLS, cookies/cache policy
  |-- restricted GPU/media utility processes
  |       |-- native graphics driver -> guest-visible GPU -> presentation
  |       `-- decoder driver -> shared YUV surfaces -> compositor
  `-- native adapters: files, fonts, clipboard, accessibility, audio
          |
     OrangeOS runtime + capability IPC + Zest kernel + Peel
```

Renderers receive no general filesystem or hardware-control authority. Network
access and privileged browser actions are mediated; sites cannot reach the Mac
companion's control APIs. Services receive only the resources their job needs.
Kernel interfaces validate lengths, offsets, handles, ownership and quotas.
Do not implement Chromium's security model as a collection of success-returning
stubs. Keep site/process boundaries even when the machine is memory-constrained.

Proposed adapter contracts (design names, not implemented syscalls):

| Interface | Responsibility and required failure semantics |
|---|---|
| `Runtime/VM` | Reserve vs commit, map/protect/unmap, W^X transitions, handle-backed shared memory, bounded allocation failure |
| `Threads/Wait` | Threads, TLS, mutex/condition/futex-like waits, cancellation, monotonic deadlines; no lost wakeups |
| `Process/IPC` | Spawn, rights-limited handles, shared buffers, peer death, backpressure and deterministic cleanup |
| `Network` | Nonblocking sockets, readiness, DNS cancellation, precise errors, verified TLS, offline/proxy handling |
| `ProfileStore` | Atomic replacement, locking, durability, quota errors, crash recovery and permission-scoped downloads |
| `Peel/Ozone` | Window lifecycle, resize/scale, pointer/keyboard/IME, clipboard, presentation timestamps and input focus |
| `Graphics` | Capability query, formats, buffer import/export, fences, presentation and device-loss recovery |
| `MediaDecode` | Codec/profile/level and size/rate query, bounded async decode, flush/reset, surface lifecycle and errors |
| `Audio` | PCM stream negotiation, bounded ring buffers, playback clock, routing, volume and underrun reporting |

Chromium Mojo remains its internal IPC protocol; port its underlying platform
primitives rather than replacing all browser messages with ad hoc RPC. Ozone
is the graphics/input integration boundary, not a substitute for OS support [S1].

V8/PartitionAlloc feasibility must explicitly audit large virtual reservations,
page alignment, memory permissions, thread primitives and CPU feature detection
at the pinned revision. Virtual address reservation is not resident RAM. A
JIT-less diagnostic build may help bring-up, but is not proof of performance.
Never use permanently writable/executable memory to avoid JIT integration work.
AVX remains unavailable until complete CPU state management and tests exist.

## 6. Smooth graphics and input

Keep Chromium's compositor/raster pipeline and adapt its output to Peel.
Use compositor-driven scrolling where upstream supports it; input, browser UI
and audio must not block behind page JavaScript, DNS or disk operations.

1. Establish a correct software-output path for engine bring-up.
2. Add a capability-checked guest GPU backend and required userspace graphics
   libraries. Evaluate virtio-gpu for VM portability before selecting a backend.
3. Import shared surfaces using explicit acquire/release fences. The producer
   must not overwrite a buffer while Chromium, Peel or scanout is using it.
4. Present on frame deadlines with actual completion feedback. Bound queued
   frames; avoid buffering latency and full-screen copies for cursor movement.
5. Handle resize, scale changes, clipping, occlusion and device reset without
   stale frames, corruption, tearing or focus loss.

GPU command validation, per-client memory accounting and reset containment are
required. A hardware cursor plane is optional; a responsive software cursor is
still necessary. Retain crisp text at the guest backing scale; distinguish guest
raster quality from QEMU's final host-side scaling.

QEMU documents distinct 2D and accelerated virtio-gpu backends [S4]. This is a
candidate technology, not evidence the installed Cocoa/Mac configuration supports
the necessary backend. Phase 1 records QEMU build options, host renderer support,
guest protocol/features and actual acceleration. **3D acceleration is not proof
of hardware video decoding.** Unsupported combinations must fail clearly.

## 7. Media architecture: excellent playback before headline resolution

Use Chromium's existing HTML media and Media Source Extensions pipelines,
including upstream buffering, demuxing and A/V timing machinery [S5]. Wire them
to OrangeOS implementations; do not create a parallel YouTube player or bypass
site authentication. Target adaptive streaming, seeking, captions, playback speed,
fullscreen and picture-in-picture, with correct background audio policy.

### 7.1 Decode and audio path

```text
HTTPS / MSE segments -> bounded demux queue -> codec selection
    |-- supported hardware decoder -> shared NV12/P010 surfaces --|
    `-- maintained software decoder -> bounded frame surfaces ----|-> GPU/Peel
    `-- audio decoder -> PCM ring -> mixer/device clock ----------|-> speakers
```

Software decoding is a correctness/fallback route, not an 8K performance claim.
Candidate codec coverage: VP8/VP9/AV1 and Opus/Vorbis, plus H.264/AAC and HEVC
where supported and approved for distribution. Audit upstream build switches,
codec dependencies and applicable licensing before shipping; do not claim that
all Chromium builds include every codec or protected-media component.

The hardware adapter must report codec, profile, bit depth, chroma format,
maximum dimensions, supported throughput, concurrent stream count and required
surface count. Validate allocation and sustained decoding, not just a capability
bit. Export truthful Media Capabilities results [S6]; retain diagnostic visibility
of hardware vs software decoding, codec, decoded/dropped/presented frames and A/V drift.

Avoid CPU round-trips and repeated YUV-to-RGBA conversions when supported.
Negotiate color range/matrix and SDR/HDR output correctly; HDR is separate from
8K and remains unsupported until the full display path is qualified. Handle
mid-stream resolution changes, seek flushes and device loss without stale frames.

Continuous guest audio must have a real playback clock, format conversion,
bounded buffers and underrun counters. Mac volume control is not a substitute
for this service. Use audio timing to pace video; recover from missing/late
frames without accumulating A/V drift. Never block audio on browser UI locks.

### 7.2 Resolution tiers

| Tier | Qualification target | Prerequisite |
|---|---|---|
| Bring-up | Local known-good clips and basic online playback | Correct software decode, PCM output, synchronization |
| Baseline smooth | 1920x1080 at 60 fps, 4 GiB total guest | Measured CPU throughput or supported hardware decode; paced display |
| High resolution | 3840x2160 at 60 fps | Qualified codec/decoder/graphics path, bandwidth and surface budget |
| Optional 8K | 7680x4320 at 30 fps and 60 fps qualified separately | End-to-end hardware/software capability and sufficient resources |

The 4 GiB baseline must not depend on 8K support. An 8K-qualified configuration
may require more memory/cores than the baseline. Even a GPU advertised as "8K"
may support only scanout, certain codecs, bit depths or frame rates. Decoding an
8K stream downscaled to a smaller display is not native 8K display output; report
source dimensions and output dimensions separately. Network throughput and
site-provided renditions must also be adequate.

For 7680x4320, tightly packed illustrative storage before stride/alignment:

- NV12 (8-bit 4:2:0): approximately 47.5 MiB per frame.
- P010 (10-bit values in 16-bit 4:2:0 storage): approximately 94.9 MiB per frame.
- RGBA8: approximately 126.6 MiB per frame.

Eight P010 surfaces alone use approximately 759.4 MiB, before reference pools,
display buffers, bitstreams and browser memory. Reference frames, queue depth,
decoder requirements and alignment must determine the actual pool size; never
reduce it below codec requirements to fit a marketing budget. This is why a
768 MiB baseline graphics envelope cannot promise general 8K playback.

When a requested tier is unsupported, expose the reason and offer a lower
resolution. Let sites' adaptive playback operate using truthful capabilities;
do not promise that the browser can force every website to offer a particular
quality. A repeated overload must degrade quality or stop safely, not freeze
the desktop. Protected/DRM playback has a separate vendor and security gate.

## 8. Browser UI and memory policy

- Small native-looking toolbar: back/forward/reload, address/security state,
  tabs, downloads, bookmarks and settings. Match desktop light/dark themes.
- Browser actions remain keyboard-accessible; support IME, Unicode shaping,
  selection, zoom, accessibility semantics and readable focus/error states.
- Restore session metadata first; load background page contents on demand.
- Freeze eligible inactive work, then discard contents under pressure. Preserve
  tab identity and make reload behaviour visible, not a silent loss of work.
- Protect active playback/calls, downloads, unsaved forms and other unsafe-to-
  discard workloads using upstream lifecycle heuristics and user exceptions.
- Bound history, network caches, media queues, decoded images and GPU pools.
  No speculative unlimited preload, extension preload or background browser
  process after final close unless the user explicitly enables such behaviour.
- Do not cap all sites into one renderer to claim lower RAM. No global
  `--no-sandbox` or site-isolation bypass in a release configuration.

Browser tab lifecycle policies can save resources [S7], but freezing alone is
not guaranteed to release a page's resident heap. Prove reclamation with guest
physical accounting. A single heavy site can exceed the target: provide a clear
tab-level resource error and preserve the rest of the OS.

## 9. Website compatibility and test matrix

Run tests at a recorded engine revision/date, with exact URLs, task steps,
viewport, codec, device/backend, network conditions and profile. Live sites
change; passing once is not permanent certification. Use dedicated test accounts
only with user consent; never scrape personal sessions or publish credentials.

| Workload | Required user journeys |
|---|---|
| YouTube | Search, playback, 1080p60 where offered, seek, captions, fullscreen, speed, audio sync, 30-minute playback; 4K/8K separate |
| Search and Wikipedia | Queries, links, scrolling, selection, find-in-page, zoom and navigation history |
| GitHub | Repository browsing, code views, search, downloads and optional test-account login |
| Gmail / Google Docs | Authorized login, compose/edit, keyboard shortcuts, save/reload; verify unsaved-work protection |
| Modern web chat | Authorized session, streaming text, clipboard permissions and reconnect; microphone/camera only after capture support |
| Media fixtures | Known VP9/AV1 and approved other-codec clips, MSE switching, offline/slow network, malformed/truncated streams |
| Security fixtures | Bad/expired/mismatched certificates, mixed content, cross-origin boundaries, denied permissions and malformed IPC |

Use reproducible local HTTPS fixtures and upstream Web Platform Tests subsets
for regressions alongside live sites. Media fixtures need recorded licenses,
hashes, duration, codec profile, bit depth, dimensions and frame rate.
Passing a test video does not by itself certify YouTube or DRM services.

## 10. Performance acceptance: define "butter smooth"

Performance gates apply to a named **qualified accelerated profile**, not
automatically to the current TCG preview. Functional gates still run in TCG.
Measure guest processing separately from end-to-end host presentation latency.

| Metric | Initial proposed gate |
|---|---|
| Desktop/browser animation on a 60 Hz output | p95 frame work within 16.7 ms; fewer than 1% missed presentation deadlines during a 60-second fixed scroll/drag trace |
| Input-to-present for toolbar and scrolling | p95 <= 50 ms, p99 <= 100 ms on the defined trace; disclose measurement method |
| Browser-controlled main-thread stalls | None over 100 ms during the trace; report site-script stalls separately rather than hiding them |
| 1080p60 playback | < 0.5% dropped frames after startup/seek exclusions, zero audio underruns, absolute A/V drift <= 50 ms over 30 minutes |
| 4K / 8K playback | Same quality gate for each advertised resolution, codec and frame-rate combination; no extrapolation from 1080p |
| Memory | Specified mixed-site workload within 4096 MiB total, >= 256 MiB emergency headroom, no swap needed for the baseline pass |
| Lifecycle | 1000 tab open/close cycles; no leaked kernel resources; post-warm-up retained memory plateaus within a declared 5% tolerance after cache reclamation |
| Fault handling | Renderer/GPU/network service failure leaves desktop usable; recovery does not grant extra authority or lose committed profile data |

Baseline mixed workload: one playing 1080p60 video, one active document or
interactive page, and three eligible background tabs. Test both awake and
memory-saver states and report every discard/reload. Do not compare browsers
using different codecs, extensions, content, viewport sizes or tab states.

Network startup/rebuffer targets are measured with a controlled link and reported
separately from decoder/presentation results. Repeat at least three runs after
warm-up and publish median, tail latency, peak memory and failures. Record CPU,
GPU and power/thermal information where available. No invented benchmark numbers.

## 11. Ordered implementation phases and exit gates

Phase 1 is **in progress**, with the resource-profile/preflight slice below
implemented. Some Phase 2 groundwork is already recorded in
[008-browser.md](008-browser.md); no full phase exit gate has passed. Independent investigations may
overlap, but a later gate cannot waive an earlier security/correctness blocker.

| Phase | Deliverable | Exit gate |
|---|---|---|
| 1. Feasibility and profiles | Pinned Chromium/toolchain; embedding choice; dependency/patch map; 4 GiB test profile; storage/build-space plan; GPU capability audit | Reproducible upstream reference build on a supported build host; documented OrangeOS blockers and go/no-go decision. Reference build is not a native browser milestone |
| 2. Reusable runtime | libc/C++ runtime, allocator, thread/TLS/waits, expanded VM, IPC and lifecycle reclamation | Upstream library probes run in OrangeOS; multicore/fault/OOM/stress tests pass; unsafe VM/JIT assumptions resolved |
| 3. Secure platform services | Async network/TLS/entropy, durable profiles, file authority, fonts/text/input and audio service | Invalid certificates rejected; crash recovery/quota tests; correct Unicode/input; continuous PCM fixture with timing evidence |
| 4. Native engine bring-up | Chromium test shell + OrangeOS build/platform adapters + software Peel output | HTML/CSS/JS and HTTPS fixtures execute in guest; no host renderer; limitations labelled, not public browsing release |
| 5. Isolation and browser shell | Renderer/network/GPU authority boundaries, tabs/navigation/downloads/permissions, recovery | Negative sandbox/IPC tests and cross-origin tests; controlled real-site browsing; no unsandboxed release path |
| 6. Graphics acceleration | Qualified device backend, Ozone surfaces/fences, frame pacing, scale/resize and reset | Scroll/drag/input gates pass on named profile; resource ownership and GPU-reset tests pass |
| 7. Baseline media | Decode integration, continuous audio, MSE, captions/seek/fullscreen and truthful capabilities | 1080p60 fixtures and YouTube pass under 4 GiB on named profile; fallback and overload recovery pass |
| 8. Advanced media | Hardware decode surfaces, zero-copy where possible, color handling and optional 4K/8K | Separate per-codec/bit-depth/fps sustained results; source vs output resolution reported; untested tiers remain unavailable |
| 9. Resource and compatibility qualification | Memory-saver policy, quotas, essential-site matrix, lifecycle and update stress | Mixed workload, 1000-cycle test and security suite pass; unsupported sites/features listed |
| 10. Release maintenance | Signed packages, staged updates, rollback, notices/SBOM and vulnerability response | Reproducible release, verified update/recovery drills, tracked upstream fixes and documented support policy |

The initial native engine milestone must arrive before extended browser cosmetic
work. Each phase produces commands, logs, screenshots where relevant, measurements,
known limitations and a local commit. Store sanitized durable evidence, not only
temporary-directory paths. Keep real-world media qualification separate from
mock backend tests and from a successful compilation.

### 11.1 Phase 1a: resource profiles and preflight

Implemented on 2026-09-23:

- One validated resource resolver for Python/shell launchers and Zig's
  run/debug/trace targets: desktop = 3072 MiB / 2 CPUs; browser = 4096 MiB / 2 CPUs.
  The UEFI launcher previously used 512 MiB / 4 CPUs and now uses the same
  explicit profiles. Set all three overrides for a deliberate low-memory run:
  `ORANGE_VM_RAM=512M ORANGE_VM_CPUS=4 ORANGE_RAM_BUDGET_MIB=512`.
- Capacity overrides do not silently raise the selected memory budget. Invalid
  profiles, noninteger capacities, more than 32 CPUs and budgets above capacity
  fail before launching a VM. This is launch validation, not runtime quota enforcement.
- Headless guest tests confirm actual memory and CPU counts with QMP and save
  `vm-profile.json` beside serial logs and screenshots.
- `tools/browser_preflight.py` is read-only unless asked to create a new JSON
  report; it never fetches Chromium or changes the machine. It records host
  tools, build-volume free space/filesystem and advertised QEMU devices.
  Insufficient space, an unverified/non-APFS volume, spaces in the checkout path
  or missing tools fail the preliminary build gate. Passing is not a build result.

Local host audit: arm64 Mac with 16 GiB RAM, Xcode 26.3 (17C529), macOS SDK
26.2 and QEMU 11.1.0. The external APFS project volume has about 268 GiB free
at audit time, above our 100 GiB planning reserve. QEMU advertises only TCG
for x86 execution and no accelerated virtio-GPU variant. This is not guest
GPU/video qualification. `depot_tools` was missing at this audit; Phase 1b below
installs pinned tools in the external workspace, not in the global shell PATH.

Reproduce the verified profile/runtime and desktop checks:

```sh
python3 -m unittest discover -s tools -p 'test_*.py'
python3 tools/budget/test_check.py
ORANGE_VM_PROFILE=browser python3 tools/budget/test_check.py
zig build -Dmm-test -Druntime-test -Ddesktop-profile
./scripts/mkdisk.sh
ORANGE_VM_PROFILE=browser python3 tools/runtime_smoke.py
zig build -Ddesktop-profile
./scripts/mkdisk.sh
ORANGE_VM_PROFILE=browser python3 tools/desktop_smoke.py
python3 tools/desktop_smoke.py
ORANGE_VM_PROFILE=browser python3 tools/browser_preflight.py
```

Qualification record (2026-09-23):

| Check | Observed result |
|---|---|
| Profile/preflight unit tests | 20 passed |
| Budget-checker unit tests | 4 passed under each of desktop and browser profiles |
| 4 GiB native runtime | VM conservation, 4 fault types, 12 SIMD probes and 4 C/Zig ABI probes passed; each SIMD probe exercised both CPUs |
| Desktop interaction suite | Passed at both 3072 MiB / 2 CPUs and 4096 MiB / 2 CPUs, independently confirmed through QMP |
| Emitted-code audit | Soft-float kernel and native SSE2 apps passed; no YMM/ZMM register use |
| 4 GiB UEFI/NVMe budget boot | All hard limits passed; 159.38 MiB desktop idle memory, 0.42% idle CPU in this run |
| 3 GiB UEFI/NVMe budget regression | All hard limits passed; 159.38 MiB desktop idle memory, 0.41% idle CPU in this run |

The resource run exposed a stale benchmark call site left over from the FPU
context-switch API change. The benchmark now supplies separate aligned FPU
contexts, so its measured 298 ns switch includes eager save/restore. Historical
22 ns pre-SIMD measurements are not comparable. The 2135 ms browser-profile
and 2141 ms desktop-profile boot times exceeded the 2000 ms advisory target
and are reported rather than hidden. None of these
idle or microbenchmark results qualifies browser performance.

Reproduce the real budget boot separately with
`ORANGE_VM_PROFILE=browser ./scripts/budget.sh`; it rebuilds the development
disk and USB image, so do not run it alongside a VM using those images.

The plain preflight command exits 2 if `depot_tools` is absent from PATH;
`python3 tools/browser_reference.py preflight` uses the pinned workspace tools.
Passing the preliminary check is not a successful reference build. Runtime and
desktop qualification use disposable guest disk writes. For evidence on the
external drive, create `build/tmp` and set `TMPDIR` to its absolute path before
running the Python tests (keep Unix socket paths short).

Next Phase 1 gates remain: pinned source/toolchain and dependency map, embedding
decision, upstream reference build, guest installation storage, and a recorded
native-port feasibility decision. No Chromium binary, YouTube playback or
browser sandbox is installed by this profile work.

Build-layout checks follow the upstream [macOS build instructions](https://chromium.googlesource.com/chromium/src/+/main/docs/mac_build_instructions.md)
(checked 2026-09-23). The 100 GiB threshold is our planning reserve, not a quoted
macOS minimum. Pin-specific SDK/toolchain compatibility still needs a build.

### 11.2 Phase 1b: pinned upstream source and external workspace

Implemented and exercised on 2026-09-23:

- `tools/browser/upstream.json` locks Chromium **154.0.8037.58** to
  `a654841425914cbb703a2931e07b70a83aedbafd` and depot_tools to
  `910f54316dac310fadee0c453c4d460c0c446189`. These are real downloaded Git
  checkouts, not a version string attached to a mock browser.
- `tools/browser_reference.py` creates a shallow checkout and exposes separate
  tools/source/sync/hooks/generate/build steps. It checks origins, revisions,
  tracked changes, configuration, stage order and the pinned source's SDK/Clang
  declarations. A failed stage invalidates downstream success records.
- Source, build output, tool downloads, CIPD/vpython/XDG caches and temporary
  downloads live under the external project's ignored `build/browser` directory.
  A disconnected drive, internal fallback, non-APFS filesystem, whitespace in
  the path, insufficient free-space reserve or conflicting configuration stops
  setup. No automatic cleanup, global shell edits or guest-image writes occur.
- The pinned tools bootstrap and source checkout passed. Preliminary preflight
  passes with these tools in the subprocess environment. The SDK minimum is
  **15**, while upstream official builds use **26.5**; this Mac's **26.2** clears
  the development minimum but does not establish official-toolchain parity.
- The declared compiler package is `llvmorg-24-init-3796-g20e97c4b-27`.
  The actual downloaded compiler and compiled target are separate later checks.
  Host build settings use an arm64 component build, no debug symbols, local
  execution and two compile jobs; guest memory remains the 4 GiB profile.
- **34 unit tests passed** across setup/profile/preflight, including refusing
  changed pins/configuration, numeric SDK comparison, external cache routing,
  stage-order/failure recording and read-only status behavior. The source/tools
  workspace occupies about **7.7 GiB** before dependency sync.

Runbook: [pinned reference workspace](../../tools/browser/README.md).
The source/tools milestone is complete, **not Phase 1 as a whole**. A complete
dependency sync, successful reference compile/launch, embedding decision,
dependency/patch inventory and native-port feasibility gate remain outstanding.
No native guest browser, web compatibility or media performance is claimed.

## 12. Security updates and distribution

Track a supported upstream Chromium release branch, recording its source hash,
toolchain, dependency versions and downstream patches. Pinning ensures reproducibility,
not permission to stay indefinitely on a vulnerable release. Automate update
builds and regression tests; define ownership and response targets before launch.
Critical upstream advisories trigger immediate triage and an expedited release
process. If a fix cannot ship safely, communicate the limitation and restrict
affected functionality rather than silently shipping a known unsafe configuration.

Signed updates require a verified trust root, atomic install, recovery from
interrupted writes and tested rollback. Prevent rollback to revoked vulnerable
versions. Profile/schema migrations must be backed up or version-aware so binary
rollback does not corrupt user data. Never collect browsing history in telemetry
without explicit consent. Crash logs must redact URLs, tokens and page contents.

Preserve third-party notices and applicable license obligations. Reconcile the
historical "every line ours" claim before importing dependencies: the kernel
can remain original while the browser legitimately reuses upstream code.
Google Chrome branding, Google services, codecs and DRM are separate decisions;
neither official Chrome availability nor protected 8K streaming is implied.

## 13. Risks and decisions still required

- **Port breadth:** Chromium assumes a mature platform. Phase 1 may conclude a
  prerequisite is larger than expected; report it rather than substituting a mock.
- **MacBook acceleration:** installed QEMU/Cocoa capabilities and guest drivers
  may not support the required acceleration. Functional progress continues, but
  accelerated/8K acceptance cannot be declared without a real exposed device.
- **CPU architecture:** x86 emulation on ARM can dominate latency. An ARM64 port
  could help CPU execution but does not automatically add graphics/video support.
- **4 GiB pressure:** high-resolution surfaces and complex pages compete for the
  same memory. Baseline smoothness takes priority over keeping unlimited tabs awake.
- **Storage/build capacity:** large engine sources and artifacts require an agreed
  location; persistent profiles require a qualified writable guest filesystem.
- **Maintenance:** reducing toolbar features does not reduce the obligation to
  integrate security fixes. Keep a small platform patch set and avoid engine forks.

Phase 1b selects an engine revision for reference-build qualification, not a
shipping release. No graphics backend, shipping codec set, DRM provider or
browser performance result is selected/claimed by writing this document.
Subsequent phases must supply evidence.

## 14. Primary references

Checked 2026-09-23. Links describe upstream interfaces; they do not certify OrangeOS.

- **S1:** [Chromium Ozone platform integration](https://chromium.googlesource.com/chromium/src/+/main/docs/ozone_overview.md).
- **S2:** [CEF architecture](https://chromiumembedded.github.io/cef/architecture) and [Alloy bootstrap removal](https://github.com/chromiumembedded/cef/issues/3685).
- **S3:** [Chromium Linux build requirements](https://chromium.googlesource.com/chromium/src/+/main/docs/linux/build_instructions.md).
- **S4:** [QEMU virtio-gpu backends](https://www.qemu.org/docs/master/system/devices/virtio/virtio-gpu.html).
- **S5:** [Chromium media pipeline](https://github.com/chromium/chromium/blob/main/media/README.md) and [video decoder performance tests](https://github.com/chromium/chromium/blob/main/docs/media/gpu/video_decoder_perf_test_usage.md).
- **S6:** [W3C Media Capabilities](https://www.w3.org/TR/media-capabilities/).
- **S7:** [Edge tab lifecycle explanation](https://support.microsoft.com/en-us/edge/learn-about-performance-features-in-microsoft-edge) and [Chrome Memory Saver](https://support.google.com/chrome/answer/12929150?hl=en).
- **S8:** [WPE design goals](https://webkit.org/wpe/) and [platform/feature limitations](https://wpewebkit.org/about/faq.html).
