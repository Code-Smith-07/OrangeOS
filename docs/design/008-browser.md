# A modern browser for OrangeOS

Status: runtime foundations in progress, not an installed browser.
User requirement (September 6, 2026): full modern-web functionality with a
lightweight shell; a plain-HTTP text viewer is not an acceptable substitute.

## Engine direction

**Superseded direction (2026-09-23):** the leading candidate is now native
Chromium with a minimal, maintainable browser interface. See the
[native Chromium architecture](011-native-chromium-browser.md) for the 4 GiB
browser profile, graphics/media design, conditional 8K tiers and phase gates.
This file retains the verified runtime ledger; no engine port is complete.

The earlier proposal was to evaluate a native WebKit port first, with WPE as
the embedded reference. It remains a fallback for a recorded feasibility decision.
WPE is designed for embedded/low-consumption devices and minimizes UI-layer
dependencies. It still targets Linux-based systems; it cannot run unchanged
on Zest. A browser shell, platform port, and security integration remain work.
This is a provisional engineering direction, not a measured performance win.

Primary references:

- [WebKit's WPE description](https://webkit.org/wpe/)
- [WPE architecture](https://wpewebkit.org/blog/02-overview-of-wpe.html)
- [WPE FAQ: Cog is not a complete desktop browser](https://wpewebkit.org/about/faq.html)
- [Chromium platform abstraction](https://chromium.googlesource.com/chromium/src/+/main/docs/ozone_overview.md)
- [Chromium Linux build prerequisites](https://chromium.googlesource.com/chromium/src/+/main/docs/linux/build_instructions.md)

Chromium is the leading candidate, subject to the new plan's feasibility gate.
Ozone abstracts graphics/input, not all of the operating system. Neither an
Ozone backend nor a Peel window alone supplies a libc, threads, virtual memory,
network security, process isolation, font shaping or media stack.

## Verified gaps in the current source

| Area | Current implementation | Work needed |
|---|---|---|
| Executables | Static freestanding Zig/C ELF; native C floating-point ABI probe; no libc underneath Pulp | General libc, allocator and C++ runtime/toolchain support |
| Heap | Owned anonymous maps and sparse reserve/commit/decommit with page-aligned subranges, plus legacy 256 KiB scratch arena | General C/C++ allocator, thread-safe VM, file/shared mappings and larger workloads |
| CPU state | Eager per-task x87/SSE2 save/restore on every CPU; apps compile for baseline SSE2; kernel remains soft-float | XSAVE/AVX remain unsupported; retain CPU isolation and ABI regression gates |
| Threads | Kernel scheduler, no pthread-compatible user API | User threads, thread-local storage, synchronization |
| Network | DNS and blocking TCP; receive conflates timeout and EOF | Nonblocking/polling sockets with precise errors and cancellation |
| HTTPS | No TLS library, trust store or secure randomness API | Audited TLS port, entropy, certificate and hostname validation |
| Files | Read-only user API; limited reclamation | Safe writes, profile storage, cache quotas, object cleanup |
| Graphics | Peel CPU framebuffer and ASCII coverage atlas | Native engine backend, Unicode shaping, images, scalable surfaces |
| Security | Synchronous ring-3 faults terminate the app; owned pages reclaimed | IPC/socket/file cleanup, task reaping, sandbox boundaries, permissions, lifecycle stress |

Evidence locations: build.zig; userland/libs/pulp/pulp.zig;
kernel/sched/process.zig; kernel/arch/x86_64/context.zig;
kernel/syscall/syscall.zig; kernel/lib/elf.zig;
userland/libs/typography/typography.zig.

## Phased acceptance gates

1. **Desktop performance prerequisite:** profile actual guest frame costs,
   separate pointer rendering and damage, preserve glass correctness. Commit
   only after native tests and QEMU interaction checks pass.
2. **Runtime foundation:** reclaimable mappings, C/C++ allocation/runtime
   probes, isolated FPU/SIMD state, user synchronization and thread-local storage.
   Test across two CPUs, allocation failures, process exit and repeated relaunch.
3. **Secure networking:** explicit EOF/timeouts, asynchronous fetches and
   cancellation, secure randomness, TLS with a maintained trust bundle. Test
   trusted HTTPS, invalid/expired/hostname-mismatched certificates, redirects,
   oversized replies and disconnects. Never bypass certificate verification.
4. **Engine proof:** pin an upstream engine revision; reproducible cross-build;
   render real HTML/CSS/JavaScript and Unicode through Peel. Measure actual
   pages, memory and startup time before claiming lightweight compatibility.
5. **Browser shell:** address bar, history navigation, tabs, find, zoom,
   downloads, bookmarks, profiles, permission prompts and crash recovery.
6. **Compatibility/security:** Web Platform Tests subset plus documented
   real-site tests, sandbox/crash containment, sustained tab open/close stress
   and update policy. Media/DRM limitations must be explicit.

Current launchers still default to 3 GiB / two vCPUs. Set
`ORANGE_VM_PROFILE=browser` for the implemented 4 GiB / two-vCPU test profile.
This is guest capacity, not a measured browser result. Memory ceilings, background
tab suspension, lazy startup, bounded caches and minimal browser chrome are
ways to control overhead; there is no honest fixed RAM promise for arbitrary
modern websites. No host-browser streaming, TLS-stripping proxy or hidden
remote renderer is part of this native-browser plan.

The user requires descriptive **local commits after each verified phase**.
Do not push without explicit permission. Runtime work is necessary engineering,
not a completed browser; do not add a nonfunctional browser icon as a milestone.

## Runtime milestone: owned anonymous memory (23 September 2026)

Syscalls 10/11/12 now implement a deliberately bounded mmap/munmap/mprotect
subset, exposed by Pulp's `mapMemory`, `unmapMemory`, `protectMemory`:

- Anonymous private allocations, page-rounded and zero-filled; 128 live regions,
  64 MiB maximum per mapping, 256 MiB per-process reserved arena.
- Read/write, read-only and inaccessible protection. Page-aligned subrange
  protection and unmap are supported within one owned region; a middle unmap
  splits it into two live regions. Anonymous execution, fixed addresses,
  file mappings and sparse reservation/commit remain unsupported.
- Released virtual addresses, physical frames and empty page tables are reused.
  Exit releases owned anonymous mappings. The following cleanup milestone also
  reclaims image/stack pages; shared-object teardown and zombie reaping remain.
- One thread per address space; do not expose shared-address-space threads until
  VM locking and cross-CPU TLB invalidation are implemented.

Qualification: `zig build -Dmm-test -Druntime-test -Ddesktop-profile`,
`./scripts/mkdisk.sh`, `python3 tools/runtime_smoke.py`. The kernel checks exact
physical-page conservation over 64 cycles, protection flags, cleanup and table
teardown. Three ring-3 runs check API rejections, syscall copy permissions,
zeroing, address reuse and slot exhaustion before the desktop starts.

On 24 September 2026, subrange operations gained kernel and ring-3 coverage.
The kernel test checks unaffected neighbors, prefix/suffix removal, hole reuse
and frame conservation.
At that subrange milestone, the virtual arena was still 256 MiB and lacked
V8-style reservation. The following sparse-memory milestone expands the arena
but does not yet qualify V8 or Chromium.
`tools/vm_range_smoke.py` is the focused QEMU acceptance gate. The combined
`tools/runtime_smoke.py` also passed once with two vCPUs, but earlier runs
stalled during process stress and one later run panicked during desktop startup;
repeatability remains an open reliability gate. The wait syscall now blocks
briefly between checks instead of continuously yielding at a higher priority
than CPU-bound children.

On 24 September 2026, syscalls 13–15 and Pulp's `reserveMemory`,
`commitMemory` and `decommitMemory` added sparse anonymous reservations. The
arena is 8 GiB; one reservation may span 4 GiB, while each eager mapping or
commit call is limited to 64 MiB. Reserve consumes virtual address space but
no frames; decommit keeps the reservation and frees its frames. Kernel and
three ring-3 QEMU probes verify a 1 GiB reservation, inaccessible holes,
zeroed recommit, read-only protection, rejection of overlap/out-of-range
commits and frame cleanup. `tools/vm_range_smoke.py` passed after the final
boundary checks. The combined `tools/runtime_smoke.py` passed once before
those checks, then timed out in pre-existing concurrent SIMD/C process stress
on three later runs; all three VM probes passed in each run. That runtime
reliability gate remains open. This is still a single-threaded, anonymous,
non-executable VM API—not a browser engine or a full POSIX mapping layer.

On 24 September 2026, the next reliability slice identified the main apparent
SMP stress timeout: while the 2560×1600 boot framebuffer console was still
active, each new line scrolled millions of pixels one volatile byte at a time,
holding its console lock with interrupts disabled. Failure-only QEMU register
capture placed the CPU inside `fbcon.scroll`. It now copies non-overlapping
scanline blocks in bulk. The blocking `wait` syscall also now uses an atomic
child-exit wakeup instead of polling a one-millisecond sleep. After both
changes, the two-vCPU `tools/runtime_smoke.py` passed six consecutive runs,
including all VM, SIMD, C ABI and desktop gates. This resolves the observed
timeout in those runs, not all future scheduler or browser stress risks.

The next process-lifecycle slice recycles a child task's registry slot and
32 KiB kernel stack when its parent consumes the exit status. The 64-record
limit now bounds concurrent records, not lifetime process launches; a full
registry rejects a spawn instead of silently creating an unfindable task.
Task IDs are assigned atomically across CPUs, and `wait` accepts only children
of the calling task. Budget reporting copies task accounting data under the
scheduler lock so it cannot inspect a record being reaped. A quiet ring-3
probe is launched and waited 96 times before desktop startup, checking slot
reuse, second-wait rejection and non-child rejection. A separate wave fills
the registry with uncollected children, checks a clean spawn rejection, then
reaps the wave and starts another child. This does not yet reap
orphaned children automatically or reclaim globally owned sockets/descriptors.

This removes the first allocation blocker; it is not a completed engine port,
C library, thread API, SIMD implementation or browser.

The following orphan-cleanup slice adds a low-priority kernel reaper. When a
parent exits, its live and already-exited children become unowned; after each
child exits, the reaper releases its task record and 32 KiB stack. A ring-3
stress probe launches 96 parents in eight waves; each parent leaves a fast and
a delayed child, then exits without waiting. A post-wave spawn checks that the
registry remains reusable. This stress also exposed unsynchronized concurrent
reads through the AHCI/NVMe drivers' single command slot and DMA bounce buffer:
some real binaries falsely resolved as missing. The common block-device
boundary now serializes reads and writes across partition aliases until the
drivers implement independently owned request queues. This is a correctness
gate, not an asynchronous storage or browser I/O implementation. Global
descriptor, socket and IPC object ownership remains incomplete.

## Runtime milestone: process fault containment (23 September 2026)

Synchronous ring-3 faults (including null access, writing read-only memory,
executing NX memory and invalid opcodes) terminate the offending task with
status `128 + exception vector`; the kernel, supervisor and other apps continue.
Kernel faults and machine failures keep the panic path. `tools/runtime_smoke.py`
launches four actual faulting programs and checks their exit status before the
desktop starts. This is CPU-fault containment, not browser sandbox certification.

Private image/stack/anonymous pages carry a software ownership flag. Process
exit switches away from its page tables before freeing them; borrowed framebuffer
and shared-memory frames remain alive. Boot tests verify private-frame recovery
and preservation of borrowed data. Successful exec now releases the copied ELF
file buffer, and failed exec unwinds its new address space. IPC handle references
are dropped, but global IPC object retention, global descriptors/sockets, task
stacks and zombie records still require lifecycle work.

## Runtime milestone: isolated floating-point state (23 September 2026)

The scheduler now eagerly saves/restores a kernel-owned, 16-byte-aligned,
512-byte FXSAVE64 context per task, including startup, migration and exit.
Every CPU enables x87/SSE2 and clears OSXSAVE; AVX is deliberately unavailable.
New tasks receive zeroed data registers, an empty x87 stack and the default
masked-exception/round-to-nearest environment, never the spawner's CPU state.
Kernel code remains soft-float because interrupt/syscall entry does not save
extended state separately. Lazy #NM switching is not used.

This uncovered and fixed the AP trampoline's C-entry stack alignment: a proper
call now supplies the ABI's return slot before entering `apEntry`.

`tools/runtime_smoke.py` runs two waves of six concurrent ring-3 SIMD probes.
They snapshot initial registers before compiler code, load distinct per-PID
x87/XMM/rounding patterns, and validate them after yields, blocking syscalls,
busy intervals and cross-CPU migration; SSE2 double arithmetic is also checked.
The first two-vCPU qualification covered both CPUs in every one of 12 probes.
Existing VM cleanup and four fault-containment probes still pass.

CPU-state contract: [Intel SDM volume 3A, chapter 13](https://cdrdv2-public.intel.com/835754/253668-sdm-vol-3a.pdf).
This is one browser-runtime prerequisite, **not an installed browser or an
engine port**. C/C++ runtime, threads/TLS, lifecycle reclamation, HTTPS and the
engine/platform integration still gate the native browser.

## Runtime milestone: native SSE2 apps and C ABI (23 September 2026)

`build.zig` now separates the soft-float kernel target from baseline x86-64
userland. All app modules use the same SSE2-enabled target, including their
shared graphics and Pulp code; the kernel's calendar module is separate and
stays soft-float. No AVX, libc, dynamic linker or host compatibility layer is
silently enabled.

`/bin/c-abi-probe` links a freestanding C11 translation unit directly into a
native guest ELF. Four concurrent instances check C/Zig floating-point calls,
mixed integer/double struct returns, callbacks into Zig, nine double arguments
(including stack passing) and live FP values over blocking system calls.
This validates a cross-language ABI subset, **not libc or C++ support**.
Use the runtime smoke suite for the complete memory/fault/SIMD/C ABI gates;
`ORANGE_VM_CPUS=1` also checks the single-core fallback.
Qualification passed on 1, 2 and 4 virtual CPUs; the four-CPU run observed all
four cores. A simultaneous multi-VM run hit the original C-probe timeout; the
standalone runs passed, and the software-emulation deadline is now 90 seconds.
No correctness assertion was removed to accommodate timing.
`python3 tools/runtime_codegen_audit.py` inspects built ELF instructions: the
kernel must contain the explicit FX save/restore instructions without MMX/XMM
register use, while the C probe and Peel must actually emit SSE instructions
without YMM/ZMM register use. This is a regression audit of emitted register
classes, not a replacement for the guest state-isolation tests.
