# A modern browser for OrangeOS

Status: compatibility investigation, not an installed browser.
User requirement (September 6, 2026): full modern-web functionality with a
lightweight shell; a plain-HTTP text viewer is not an acceptable substitute.

## Engine direction

Evaluate a native WebKit port first, with WPE as the embedded reference.
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

Chromium remains an alternative if compatibility or port feasibility favors it.
Ozone abstracts graphics/input, not all of the operating system. Neither an
Ozone backend nor a Peel window alone supplies a libc, threads, virtual memory,
network security, process isolation, font shaping or media stack.

## Verified gaps in the current source

| Area | Current implementation | Work needed |
|---|---|---|
| Executables | Static freestanding Zig ELF, no libc underneath Pulp | C/C++ runtime and target/toolchain support |
| Heap | 256 KiB bump arena; freeing is a no-op | Reclaimable process VM, allocation and protection APIs |
| CPU state | SIMD disabled; context switch saves general registers | Per-task FPU/SIMD initialization and isolation on every CPU |
| Threads | Kernel scheduler, no pthread-compatible user API | User threads, thread-local storage, synchronization |
| Network | DNS and blocking TCP; receive conflates timeout and EOF | Nonblocking/polling sockets with precise errors and cancellation |
| HTTPS | No TLS library, trust store or secure randomness API | Audited TLS port, entropy, certificate and hostname validation |
| Files | Read-only user API; limited reclamation | Safe writes, profile storage, cache quotas, object cleanup |
| Graphics | Peel CPU framebuffer and ASCII coverage atlas | Native engine backend, Unicode shaping, images, scalable surfaces |
| Security | User faults can halt the OS; limited process cleanup | Fault containment, sandbox boundaries, permissions, lifecycle tests |

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

The default guest allocation is 3 GiB / two vCPUs. Memory ceilings, background
tab suspension, lazy startup, bounded caches and minimal browser chrome are
ways to control overhead; there is no honest fixed RAM promise for arbitrary
modern websites. No host-browser streaming, TLS-stripping proxy or hidden
remote renderer is part of this native-browser plan.

The user requires descriptive **local commits after each verified phase**.
Do not push without explicit permission. Runtime work is necessary engineering,
not a completed browser; do not add a nonfunctional browser icon as a milestone.
