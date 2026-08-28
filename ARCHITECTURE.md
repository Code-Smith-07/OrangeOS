<div align="center">

# 🍊 Orange OS

**A modern operating system, written from scratch.**

*No Linux. No BSD. No inherited code. Every line ours.*

`x86_64` · `Zig` · `Monolithic + Modules` · `Wayland-style Compositor` · `MIT OR Apache-2.0`

</div>

---

## Table of Contents

| § | Section | What's inside |
|---|---------|---------------|
| 1 | [Identity & Vision](#1-identity--vision) | What Orange OS is, and what it refuses to be |
| 2 | [Design Principles](#2-design-principles) | The rules we hold ourselves to |
| 3 | [Non-Goals](#3-non-goals) | Explicitly out of scope, and why |
| 4 | [Core Decisions](#4-core-decisions) | Every locked architectural choice in one table |
| 5 | [Component Naming](#5-component-naming) | The citrus family |
| 6 | [System Architecture](#6-system-architecture) | The layer cake |
| 7 | [Boot Flow](#7-boot-flow) | Power-on to desktop, step by step |
| 8 | [Memory Architecture](#8-memory-architecture) | Physical map, virtual layout, allocators |
| 9 | [Repository Layout](#9-repository-layout) | The complete file tree |
| 10 | [Kernel Subsystems](#10-kernel-subsystems) | Deep dive per subsystem |
| 11 | [Syscall ABI](#11-syscall-abi) | The kernel/user contract |
| 12 | [IPC Model](#12-ipc-model) | Ports, channels, capabilities |
| 13 | [Graphics Stack](#13-graphics-stack) | Framebuffer to pixels on screen |
| 14 | [Filesystem Design](#14-filesystem-design) | VFS and CitrusFS |
| 15 | [Build System](#15-build-system) | How it all compiles |
| 16 | [Development Roadmap](#16-development-roadmap) | 10 phases, with honest timelines |
| 17 | [Coding Conventions](#17-coding-conventions) | House style |
| 18 | [Glossary](#18-glossary) | Every term used here |

---

## 1. Identity & Vision

Orange OS is a **from-scratch operating system** targeting x86_64, built to be
**radically lighter** than mainstream desktop systems while presenting a
**genuinely beautiful** graphical interface.

Three sentences that define the project:

> **1.** Every line of code in the kernel and core userland is written by us, giving
> total control over hardware, software, and licensing.
>
> **2.** The system should idle in well under 128 MB of RAM with the full desktop
> running, and stay responsive on a decade-old machine.
>
> **3.** The interface is a first-class concern, not an afterthought bolted onto a
> terminal — compositing, animation, and typography are designed in from Phase 0.

### Why from scratch?

| Reason | Payoff |
|--------|--------|
| **Control** | No upstream decides our scheduler, our ABI, or our release cadence. |
| **Licensing** | Zero GPL obligation. We choose our terms; ours are MIT and Apache-2.0, dual. |
| **Footprint** | Nothing we didn't ask for. No legacy subsystems, no dead drivers. |
| **Understanding** | We can debug any layer because we wrote every layer. |
| **Education** | There is no deeper way to learn how computers actually work. |

---

## 2. Design Principles

```
  ┌──────────────────────────────────────────────────────────────────────┐
  │                                                                      │
  │   I.    CORRECTNESS BEFORE PERFORMANCE                               │
  │         A slow kernel that works can be optimized.                   │
  │         A fast kernel that corrupts memory cannot be salvaged.        │
  │                                                                      │
  │   II.   EXPLICIT BEFORE CLEVER                                       │
  │         Kernel code is read at 3 AM while chasing a triple fault.    │
  │         Optimize for the reader, always.                             │
  │                                                                      │
  │   III.  NO SILENT FAILURE                                            │
  │         Every fallible operation returns an error. No ignored codes.  │
  │         An unexpected state panics loudly with full context.          │
  │                                                                      │
  │   IV.   ONE ALLOCATOR PER PURPOSE                                    │
  │         Page frames, kernel heap, slab caches, and user memory are   │
  │         distinct systems with distinct invariants. Never mix them.    │
  │                                                                      │
  │   V.    ARCHITECTURE BEHIND A WALL                                   │
  │         Nothing outside kernel/arch/ may know what a CR3 register is. │
  │         Porting to aarch64 must touch exactly one directory.          │
  │                                                                      │
  │   VI.   THE DESKTOP IS NOT PRIVILEGED                                │
  │         The compositor is an ordinary userspace process.             │
  │         If it crashes, the system survives and restarts it.           │
  │                                                                      │
  │   VII.  MEASURE EVERY BYTE                                           │
  │         Memory footprint is a tracked metric with a CI budget.        │
  │         A regression is a build failure, not a discussion.            │
  │                                                                      │
  └──────────────────────────────────────────────────────────────────────┘
```

---

## 3. Non-Goals

Being explicit about what we are *not* building is what keeps the project finishable.

| Not doing | Why |
|-----------|-----|
| **POSIX certification** | POSIX-*inspired*. We adopt what's useful, discard the rest. |
| **Binary compatibility with Linux** | A Linux ABI shim is a project the size of this one. |
| **Running Windows games (Wine/Proton)** | Requires a Linux-compatible base + mature Vulkan drivers. Not reachable from a from-scratch kernel by a small team. |
| **Booting on Apple Silicon MacBooks** | Requires reverse-engineering undocumented Apple silicon. See §16, Phase 9. |
| **A web browser** | A modern browser engine is larger than this entire OS. |
| **SMP in Phase 0–5** | Single-core until the core is provably correct. Locks come later, deliberately. |
| **Microkernel purity** | We take the pragmatic hybrid. See §4. |
| **32-bit x86** | Long mode only. Legacy protected mode is boot-time transit, nothing more. |

> **Note on the MacBook and gaming goals:** these remain the long-term north star
> and shape our decisions (clean arch abstraction, Vulkan-shaped GPU interfaces),
> but they are Phase 9+ and depend on hardware documentation that does not
> currently exist publicly. Every phase before that stands on its own merit.

---

## 4. Core Decisions

Locked-in choices. Changing any of these is a project-wide event.

| # | Decision | Choice | Rationale |
|---|----------|--------|-----------|
| D1 | **Target architecture** | `x86_64` long mode | Widest documentation, real hardware available, all tooling mature. `aarch64` planned behind the arch wall. |
| D2 | **Implementation language** | **Zig** `0.14.1` (pinned) | Cross-compiles to bare metal from macOS with zero toolchain setup, C-ABI native, compile-time safety without a runtime. **Pinned to 0.14.1:** 0.16's bundled LLD segfaults on any freestanding x86_64 link, and its self-hosted ELF linker ignores linker scripts. |
| D3 | **Assembly** | Inline Zig `asm` + `.S` for trampolines | Only where unavoidable: context switch, ISR stubs, syscall entry. |
| D4 | **Kernel model** | **Monolithic with loadable modules** | Microkernel IPC costs contradict the low-resource goal; a pure monolith is unmaintainable. Drivers are modules with defined interfaces. |
| D5 | **Bootloader** | **Limine** (protocol v3) | Hands us long mode, a higher-half map, the memory map, a linear framebuffer, and ACPI pointers. UEFI + BIOS both. |
| D6 | **Kernel address model** | Higher-half at `0xFFFFFFFF80000000` | Standard, keeps the full lower half for userspace. |
| D7 | **Physical memory access** | HHDM at `0xFFFF800000000000` | All physical RAM linearly mapped. Trivial phys↔virt conversion. |
| D8 | **Page frame allocator** | Buddy allocator, order 0–10 | Fast, low fragmentation, handles contiguous DMA requests. |
| D9 | **Kernel heap** | Slab caches over the buddy | Object caches for fixed-size structures; minimal waste. |
| D10 | **Scheduler** | MLFQ, 4 levels, preemptive | Interactive responsiveness without CFS complexity. Round-robin within a level. |
| D11 | **Syscall mechanism** | `syscall`/`sysret` (MSR-based) | Far faster than `int 0x80`. Standard on every x86_64 CPU. |
| D12 | **IPC** | Capability-scoped ports + shared memory | Handles are unforgeable. Bulk data never copies through the kernel. |
| D13 | **Executable format** | `ELF64` | Universal, well-documented, our toolchain emits it natively. |
| D14 | **Native filesystem** | **CitrusFS** — journaled, extent-based | Designed for the OS, crash-safe by construction. `FAT32` read/write for interop. |
| D15 | **Display architecture** | Userspace compositor over a kernel-owned framebuffer | Compositor crash ≠ system crash. Kernel does not know what a window is. |
| D16 | **Rendering** | CPU-composited, damage-tracked, SIMD blitters | No GPU driver required for a full desktop. GPU acceleration is Phase 8+. |
| D17 | **Windowing protocol** | Custom, Wayland-inspired, shared-memory buffers | No network transparency, no legacy. Simple and fast. |
| D18 | **License** | **MIT OR Apache-2.0** (dual) | Maximum freedom, zero copyleft. Apache adds a patent grant; MIT is simplest. Downstream picks. Same model as Rust. |
| D19 | **Primary dev target** | QEMU `q35` machine | Instant iteration, GDB stub, full exception tracing. |
| D20 | **First real hardware** | Intel Mac (2012–2020) / generic x86_64 UEFI laptop | Standard UEFI, documented chipsets, no Apple silicon reverse-engineering. |

---

## 5. Component Naming

Every major component gets a citrus name. It's a small thing that makes the
codebase feel like one system rather than a pile of parts.

```
                              🍊 ORANGE OS
                                    │
        ┌───────────────┬───────────┴───────────┬───────────────┐
        │               │                       │               │
     KERNEL          RUNTIME                 DISPLAY         TOOLING
        │               │                       │               │
     ┌──┴──┐        ┌───┴───┐              ┌────┴────┐     ┌────┴────┐
     │Zest │        │ Pulp  │              │  Peel   │     │  Crate  │
     └─────┘        │ Seed  │              │ Segment │     │  Juice  │
                    └───────┘              │  Grove  │     │ Squeeze │
                                           └─────────┘     └─────────┘
```

| Name | Component | Meaning | Lives in |
|------|-----------|---------|----------|
| **Zest** | The kernel | The concentrated essence — the core of the fruit | `kernel/` |
| **Pulp** | C standard library | The substance everything else is made of | `userland/libs/pulp/` |
| **Seed** | `init`, PID 1 | The first thing, from which everything grows | `userland/servers/seed/` |
| **Peel** | Display server / compositor | The surface you actually touch | `userland/servers/peel/` |
| **Segment** | Widget toolkit | Windows are segments of the whole | `userland/libs/segment/` |
| **Grove** | Desktop shell | Where the oranges live — dock, panel, launcher | `userland/apps/grove/` |
| **Squeeze** | Terminal emulator | You squeeze it to get output | `userland/apps/squeeze/` |
| **Juice** | Command-line shell | What comes out when you squeeze | `userland/bin/juice/` |
| **Crate** | Package manager | How oranges ship | `tools/crate/` |
| **CitrusFS** | Native filesystem | On-disk format | `kernel/fs/citrusfs/` |
| **Marmalade** | Debug/trace subsystem | Everything preserved for later inspection | `kernel/debug/` |

---

## 6. System Architecture

The full stack, top to bottom. Everything above the double line runs in **ring 3**
(userspace, unprivileged). Everything below runs in **ring 0** (kernel).

```
╔══════════════════════════════════════════════════════════════════════════════╗
║                              U S E R S P A C E                               ║
╠══════════════════════════════════════════════════════════════════════════════╣
║                                                                              ║
║  ┌────────────────────────────────────────────────────────────────────────┐  ║
║  │  APPLICATIONS                                                          │  ║
║  │  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐      │  ║
║  │  │ Squeeze  │ │  Files   │ │ Settings │ │  Editor  │ │  Viewer  │ ···  │  ║
║  │  │ terminal │ │ browser  │ │  panel   │ │   text   │ │  image   │      │  ║
║  │  └────┬─────┘ └────┬─────┘ └────┬─────┘ └────┬─────┘ └────┬─────┘      │  ║
║  └───────┼────────────┼────────────┼────────────┼────────────┼────────────┘  ║
║          └────────────┴─────┬──────┴────────────┴────────────┘               ║
║                             ▼                                                ║
║  ┌────────────────────────────────────────────────────────────────────────┐  ║
║  │  SEGMENT — Widget Toolkit                                              │  ║
║  │  layout engine · widgets · theming · animation · text shaping · events │  ║
║  └───────────────────────────────┬────────────────────────────────────────┘  ║
║                                  ▼                                           ║
║  ┌────────────────────────────────────────────────────────────────────────┐  ║
║  │  GROVE — Desktop Shell            │  PEEL — Display Server             │  ║
║  │  dock · top panel · launcher      │  compositor · window mgmt          │  ║
║  │  notifications · workspaces       │  damage tracking · input routing   │  ║
║  │  wallpaper · lock screen          │  buffer pool · cursor · effects    │  ║
║  └───────────────────────────────┬───┴────────────────────────────────────┘  ║
║                                  ▼                                           ║
║  ┌────────────────────────────────────────────────────────────────────────┐  ║
║  │  SYSTEM SERVERS                                                        │  ║
║  │  ┌────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐            │  ║
║  │  │  Seed  │ │  netd   │ │ audiod  │ │  logd   │ │ devmgr  │            │  ║
║  │  │  init  │ │ network │ │  sound  │ │ logging │ │ hotplug │            │  ║
║  │  └────────┘ └─────────┘ └─────────┘ └─────────┘ └─────────┘            │  ║
║  └───────────────────────────────┬────────────────────────────────────────┘  ║
║                                  ▼                                           ║
║  ┌────────────────────────────────────────────────────────────────────────┐  ║
║  │  PULP — C Standard Library                                             │  ║
║  │  stdio · stdlib · string · math · pthread · syscall stubs · crt0       │  ║
║  └───────────────────────────────┬────────────────────────────────────────┘  ║
║                                  │                                           ║
╚══════════════════════════════════╪═══════════════════════════════════════════╝
                                   │
        ═══════════════════════ SYSCALL GATE ═══════════════════════
              syscall / sysret  ·  ~80 calls  ·  capability-checked
                                   │
╔══════════════════════════════════╪═══════════════════════════════════════════╗
║                                  ▼        K E R N E L   —   Z E S T          ║
╠══════════════════════════════════════════════════════════════════════════════╣
║                                                                              ║
║  ┌───────────────┐ ┌───────────────┐ ┌───────────────┐ ┌──────────────────┐  ║
║  │  SCHEDULER    │ │  MEMORY (mm)  │ │  VFS          │ │  IPC             │  ║
║  │  MLFQ 4-level │ │  buddy alloc  │ │  mount tree   │ │  ports           │  ║
║  │  threads      │ │  slab caches  │ │  inode cache  │ │  channels        │  ║
║  │  processes    │ │  paging       │ │  file descr.  │ │  shared memory   │  ║
║  │  wait queues  │ │  address sp.  │ │  page cache   │ │  capabilities    │  ║
║  │  timers       │ │  COW / demand │ │  CitrusFS     │ │  signals         │  ║
║  └───────────────┘ └───────────────┘ └───────────────┘ └──────────────────┘  ║
║                                                                              ║
║  ┌───────────────┐ ┌───────────────┐ ┌───────────────┐ ┌──────────────────┐  ║
║  │  DRIVERS      │ │  NET STACK    │ │  TIME         │ │  DEBUG           │  ║
║  │  block · char │ │  eth · arp    │ │  TSC · HPET   │ │  Marmalade       │  ║
║  │  input · fb   │ │  ip · udp/tcp │ │  RTC · timers │ │  panic · trace   │  ║
║  │  pci · acpi   │ │  socket layer │ │  monotonic    │ │  symbolizer      │  ║
║  └───────────────┘ └───────────────┘ └───────────────┘ └──────────────────┘  ║
║                                                                              ║
║  ┌────────────────────────────────────────────────────────────────────────┐  ║
║  │  ARCH LAYER — kernel/arch/x86_64/                                      │  ║
║  │  GDT · IDT · TSS · paging (PML4) · APIC · MSR · SMP trampoline · ctx   │  ║
║  │  ─────────────────── the only code that knows what a CR3 is ────────── │  ║
║  └────────────────────────────────────────────────────────────────────────┘  ║
╚══════════════════════════════════════════════════════════════════════════════╝
                                   │
  ┌────────────────────────────────▼─────────────────────────────────────────┐
  │  LIMINE BOOTLOADER  →  UEFI firmware  /  Legacy BIOS                     │
  └────────────────────────────────┬─────────────────────────────────────────┘
                                   ▼
  ┌──────────────────────────────────────────────────────────────────────────┐
  │  H A R D W A R E     CPU · RAM · PCIe · NVMe/AHCI · USB · GPU · NIC      │
  └──────────────────────────────────────────────────────────────────────────┘
```

### Trust boundaries

```
   ┌─ Ring 0 ──────────────────────────────────────┐
   │  Zest kernel. Full hardware access.           │   ← ~35k lines target
   │  Bugs here = system death.                    │
   └───────────────────────────────────────────────┘
   ┌─ Ring 3, privileged capabilities ─────────────┐
   │  Seed, devmgr, Peel, netd                     │   ← restart-on-crash
   │  Hold caps for hardware/IPC. Bugs = degraded. │
   └───────────────────────────────────────────────┘
   ┌─ Ring 3, unprivileged ────────────────────────┐
   │  Grove, apps. No caps beyond what Seed grants.│   ← fully sandboxable
   │  Bugs = one dead window.                      │
   └───────────────────────────────────────────────┘
```

---

## 7. Boot Flow

From pressing the power button to a usable desktop. Each step names the file that
owns it.

```
 ┌──────┐
 │ 0    │  POWER ON
 └──┬───┘  CPU starts in 16-bit real mode at the reset vector.
    │
    ▼
 ┌──────┐
 │ 1    │  FIRMWARE — UEFI or Legacy BIOS
 └──┬───┘  POST, device init, reads the boot device, loads Limine.
    │      ▸ owned by: the machine, not us
    ▼
 ┌──────┐
 │ 2    │  LIMINE BOOTLOADER
 └──┬───┘  Reads boot/limine.conf. Switches to 64-bit long mode.
    │      Builds an initial page table, maps the kernel higher-half.
    │      Collects the memory map, RSDP (ACPI), and framebuffer info.
    │      Loads kernel.elf and jumps to our entry point.
    │      ▸ config: boot/limine.conf
    ▼
 ┌──────┐
 │ 3    │  ZEST ENTRY — kmain()
 └──┬───┘  First line of our own code. Still single-core, interrupts off.
    │      ▸ kernel/main.zig
    │
    ├─▶ 3.1  Serial UART init (COM1, 115200 8N1)     kernel/drivers/char/serial.zig
    │        ══ FIRST OUTPUT. Our lifeline for every bug after this. ══
    │
    ├─▶ 3.2  Parse Limine responses                  kernel/boot/limine_req.zig
    │        memory map · framebuffer · HHDM offset · RSDP · kernel address
    │
    ├─▶ 3.3  Framebuffer console online              kernel/drivers/video/fbcon.zig
    │        ══ FIRST PIXELS. Boot log now visible on screen. ══
    │
    ├─▶ 3.4  GDT + TSS installed                     kernel/arch/x86_64/gdt.zig
    │        Kernel/user code+data segments, IST stacks for double fault.
    │
    ├─▶ 3.5  IDT + exception handlers                kernel/arch/x86_64/idt.zig
    │        ══ Faults now print a diagnosis instead of rebooting. ══
    │
    ├─▶ 3.6  Physical memory manager                 kernel/mm/pmm.zig
    │        Buddy allocator seeded from the Limine memory map.
    │
    ├─▶ 3.7  Kernel page tables (ours, not Limine's) kernel/mm/vmm.zig
    │        Build PML4, map kernel + HHDM + framebuffer, load CR3.
    │
    ├─▶ 3.8  Kernel heap (slab over buddy)           kernel/mm/heap.zig
    │        ══ kalloc() works. Dynamic data structures unlocked. ══
    │
    ├─▶ 3.9  ACPI tables parsed                      kernel/dev/acpi/
    │        MADT → LAPIC/IOAPIC. MCFG → PCIe ECAM. FADT → power.
    │
    ├─▶ 3.10 APIC + timer + interrupts ENABLED       kernel/arch/x86_64/apic.zig
    │        ══ sti. The system is now preemptible. ══
    │
    ├─▶ 3.11 Scheduler init, idle thread created     kernel/sched/sched.zig
    │
    ├─▶ 3.12 PCI enumeration → driver binding        kernel/dev/pci/
    │        Walk buses, match vendor/device IDs, probe drivers.
    │
    ├─▶ 3.13 Block driver (NVMe / AHCI) online       kernel/drivers/block/
    │
    ├─▶ 3.14 VFS mounts root filesystem              kernel/fs/vfs/
    │        CitrusFS on the boot partition → mounted at /
    │
    ├─▶ 3.15 Input drivers (PS/2 kbd + mouse)        kernel/drivers/input/
    │
    └─▶ 3.16 Load /sbin/seed as PID 1, enter ring 3
             ══ FIRST USERSPACE CODE. Kernel boot complete. ══
    │
    ▼
 ┌──────┐
 │ 4    │  SEED — PID 1                userland/servers/seed/
 └──┬───┘  Mounts /dev, /proc, /tmp. Reads /etc/seed.conf.
    │      Starts services in dependency order, supervises, restarts on crash.
    │
    ├─▶ 4.1  devmgr    — device node management, hotplug
    ├─▶ 4.2  logd      — system log collection
    ├─▶ 4.3  netd      — network configuration (if a NIC exists)
    ├─▶ 4.4  audiod    — audio mixing daemon
    └─▶ 4.5  peel      — the display server
    │
    ▼
 ┌──────┐
 │ 5    │  PEEL — Display Server       userland/servers/peel/
 └──┬───┘  Claims the framebuffer via the kernel fb capability.
    │      Opens input devices. Creates the compositor scene graph.
    │      Opens the client socket at /run/peel-0. Starts the render loop.
    │
    ▼
 ┌──────┐
 │ 6    │  GROVE — Desktop Shell       userland/apps/grove/
 └──┬───┘  Connects to Peel as its first client. Draws wallpaper,
    │      top panel, dock, launcher. Registers global hotkeys.
    │
    ▼
 ┌──────┐
 │ 7    │  ══════════  D E S K T O P   R E A D Y  ══════════
 └──────┘  Target cold-boot time: under 2 seconds in QEMU.
           Target idle RSS with full desktop: under 128 MB.
```

---

## 8. Memory Architecture

### 8.1 Virtual address space

x86_64 gives 48 bits of usable virtual address (256 TB per half), split by a
non-canonical hole. Kernel owns the top half; every process owns the bottom half.

```
 0xFFFF_FFFF_FFFF_FFFF ┬─────────────────────────────────────────────────────┐
                       │                                                     │
                       │   ▓▓▓ RESERVED / guard                              │
 0xFFFF_FFFF_C000_0000 ┼─────────────────────────────────────────────────────┤
                       │   MMIO WINDOW              (1 GB)                    │
                       │   device registers, PCIe BARs, APIC, HPET           │
 0xFFFF_FFFF_8000_0000 ┼─────────────────────────────────────────────────────┤
                       │   ██ KERNEL IMAGE ██       (2 GB window)            │  K
                       │   .text .rodata .data .bss  — Zest itself           │  E
                       │   loaded here by Limine, -mcmodel=kernel            │  R
 0xFFFF_FF80_0000_0000 ┼─────────────────────────────────────────────────────┤  N
                       │   KERNEL HEAP              (512 GB window)           │  E
                       │   slab caches, kalloc() arenas, vmalloc region      │  L
 0xFFFF_9000_0000_0000 ┼─────────────────────────────────────────────────────┤
                       │   ▒▒ HHDM ▒▒               (up to 64 TB)            │  H
                       │   Higher-Half Direct Map                            │  A
                       │   ALL physical RAM, linearly mapped                 │  L
                       │   phys→virt is: addr + 0xFFFF_8000_0000_0000        │  F
 0xFFFF_8000_0000_0000 ┼─────────────────────────────────────────────────────┤
                       │                                                     │
                       │   ░░░░░  N O N - C A N O N I C A L   H O L E  ░░░░  │
                       │   any access here = #GP. Free bug detection.        │
                       │                                                     │
 0x0000_8000_0000_0000 ┼─────────────────────────────────────────────────────┤
                       │   [guard page]                                      │
 0x0000_7FFF_FFFF_F000 ┼─────────────────────────────────────────────────────┤
                       │   USER STACK          grows ↓  (8 MB default)       │  U
                       │           ↓                                         │  S
                       │                                                     │  E
                       │   ═══ unmapped gap ═══                              │  R
                       │                                                     │
                       │   MMAP REGION         grows ↑                       │  H
                       │   shared libs, file mappings, shm buffers           │  A
 0x0000_7F00_0000_0000 ┼─────────────────────────────────────────────────────┤  L
                       │                                                     │  F
                       │   ═══ unmapped gap ═══                              │
                       │                                                     │
                       │   USER HEAP           grows ↑  (brk / sbrk)         │
 0x0000_0000_0060_0000 ┼─────────────────────────────────────────────────────┤
                       │   USER PROGRAM IMAGE                                │
                       │   .text .rodata .data .bss  — the ELF               │
 0x0000_0000_0040_0000 ┼─────────────────────────────────────────────────────┤
                       │                                                     │
                       │   ▓▓ NULL GUARD ▓▓  (4 MB, never mapped)            │
                       │   *ptr on NULL = #PF, not silent corruption         │
 0x0000_0000_0000_0000 ┴─────────────────────────────────────────────────────┘
```

### 8.2 Physical memory allocators

Three layers, each built on the one below. Never skip a layer.

```
   ┌─────────────────────────────────────────────────────────────────────┐
   │  LAYER 3 — SLAB CACHES            kernel/mm/slab.zig                │
   │  ─────────────────────────────────────────────────────────────────  │
   │  Per-type object caches. One cache per fixed-size kernel struct.    │
   │                                                                     │
   │   cache "task"    ┌──┬──┬──┬──┬──┬──┬──┬──┐  512 B objects          │
   │                   │██│██│  │██│  │  │██│  │  freelist in-place      │
   │                   └──┴──┴──┴──┴──┴──┴──┴──┘                         │
   │   cache "inode"   ┌──┬──┬──┬──┬──┬──┬──┬──┐  256 B objects          │
   │                   │██│  │██│██│██│  │  │  │                         │
   │                   └──┴──┴──┴──┴──┴──┴──┴──┘                         │
   │   cache "file"  · cache "vma" · cache "page" · cache "port"         │
   │                                                                     │
   │  O(1) alloc/free. Near-zero fragmentation. Cache-line friendly.     │
   └────────────────────────────────┬────────────────────────────────────┘
                                    │ requests 4 KB pages
                                    ▼
   ┌─────────────────────────────────────────────────────────────────────┐
   │  LAYER 2 — KERNEL HEAP            kernel/mm/heap.zig                │
   │  ─────────────────────────────────────────────────────────────────  │
   │  kalloc(n) / kfree(p) for arbitrary sizes.                          │
   │  ≤ 8 KB  → routed to the nearest power-of-two slab cache            │
   │  > 8 KB  → direct buddy allocation, page-aligned                    │
   └────────────────────────────────┬────────────────────────────────────┘
                                    │ requests page frames
                                    ▼
   ┌─────────────────────────────────────────────────────────────────────┐
   │  LAYER 1 — BUDDY ALLOCATOR        kernel/mm/pmm.zig                 │
   │  ─────────────────────────────────────────────────────────────────  │
   │  Physical page frames. Orders 0..10 → 4 KB .. 4 MB contiguous.      │
   │                                                                     │
   │   order 10  [ 4 MB ]────split────┐                                  │
   │   order  9  [ 2 MB ][ 2 MB ]     │  buddies merge on free           │
   │   order  8  [1MB][1MB][1MB][1MB] │  → contiguous DMA buffers        │
   │    ...                            │     stay obtainable             │
   │   order  0  [4K][4K][4K][4K] ... ─┘                                 │
   │                                                                     │
   │  Free lists per order. Seeded from the Limine memory map at boot.   │
   └─────────────────────────────────────────────────────────────────────┘
```

### 8.3 Page table walk (4-level)

```
   Virtual address, 48 bits used:

    63    48 47    39 38    30 29    21 20    12 11         0
   ┌────────┬────────┬────────┬────────┬────────┬────────────┐
   │  sign  │ PML4   │  PDPT  │   PD   │   PT   │   offset   │
   │ extend │ 9 bits │ 9 bits │ 9 bits │ 9 bits │  12 bits   │
   └────────┴───┬────┴───┬────┴───┬────┴───┬────┴──────┬─────┘
                │        │        │        │           │
      CR3 ──▶ ┌─▼──┐   ┌─▼──┐   ┌─▼──┐   ┌─▼──┐        │
              │PML4│──▶│PDPT│──▶│ PD │──▶│ PT │──▶ physical page
              └────┘   └────┘   └────┘   └────┘        │
               512      512      512      512          ▼
              entries  entries  entries  entries   ┌────────┐
                                                   │ 4 KB   │
              (1 GB huge page stops at PDPT)       │ frame  │
              (2 MB huge page stops at PD)         └────┬───┘
                                                        │
                                            final addr = frame + offset
```

Per-entry flags we use: `PRESENT` · `WRITABLE` · `USER` · `WRITE_THROUGH` ·
`NO_CACHE` · `ACCESSED` · `DIRTY` · `HUGE` · `GLOBAL` · `NO_EXECUTE`.

---

## 9. Repository Layout

The complete tree. Files marked `[P0]`–`[P9]` indicate the phase (§16) that
creates them — most of this does not exist on day one, and that's the point.

### 9.1 Top level

```
OrangeOS/
│
├── 📄 README.md                     Project intro, quick start, screenshots
├── 📄 ARCHITECTURE.md               ← you are here
├── 📄 LICENSE                       Dual-license notice (MIT OR Apache-2.0)
├── 📄 LICENSE-MIT                   MIT License full text
├── 📄 LICENSE-APACHE                Apache License 2.0 full text
├── 📄 CONTRIBUTING.md               How to work on this
├── 📄 CHANGELOG.md                  Per-phase release notes
├── 📄 .gitignore                    zig-out/, zig-cache/, build/, *.iso, *.img
├── 📄 .gitattributes                Line endings, binary markers
├── 📄 build.zig                     ROOT BUILD SCRIPT — the entire build
├── 📄 build.zig.zon                 Dependency manifest
├── 📄 Makefile                      Thin convenience wrapper over zig build
│
├── 📁 boot/                         Bootloader config + image assembly
├── 📁 kernel/                       ██ ZEST — the kernel ██
├── 📁 userland/                     Everything in ring 3
├── 📁 tools/                        Host-side tooling (runs on macOS, not Orange)
├── 📁 tests/                        Unit, integration, and boot tests
├── 📁 docs/                         Design docs, specs, notes
├── 📁 assets/                       Fonts, icons, wallpapers, cursors
├── 📁 scripts/                      Dev shell scripts
├── 📁 third_party/                  Vendored external code (kept minimal)
└── 📁 build/                        Generated output (gitignored)
```

### 9.2 `boot/` — bootloader and image assembly

```
boot/
├── limine.conf                      Limine boot entry: kernel path, cmdline, resolution
├── limine.h                         Limine protocol structs (C header, imported by Zig)
├── linker-x86_64.ld                 Kernel linker script: higher-half, section layout
├── linker-aarch64.ld            [P9] Future ARM linker script
│
├── iso/                             Staging tree assembled into the bootable ISO
│   ├── EFI/BOOT/BOOTX64.EFI         Limine UEFI binary (copied at build time)
│   ├── limine-bios.sys              Limine BIOS stage
│   ├── limine-bios-cd.bin           El Torito boot record
│   └── limine-uefi-cd.bin           UEFI CD boot image
│
└── initrd/                          Initial ramdisk contents (pre-rootfs)
    ├── sbin/seed                    PID 1, so we can boot before CitrusFS works
    └── etc/seed.conf                Minimal service config
```

### 9.3 `kernel/` — Zest

The heart of the project. Target: **~35,000 lines** at Phase 8 completion.

```
kernel/
│
├── main.zig                         kmain() — the first line of our code
├── panic.zig                        Panic handler, register dump, stack unwind
├── build.zig                        Kernel-specific build rules
│
├── 📁 boot/                         Early boot, pre-subsystem
│   ├── limine_req.zig               Limine request structs + response parsing
│   ├── early_console.zig            Pre-heap serial output
│   ├── memmap.zig                   Memory map normalization and validation
│   └── cmdline.zig                  Kernel command-line parsing
│
├── 📁 arch/                         ══ THE ARCHITECTURE WALL ══
│   │                                Nothing outside this dir touches CPU specifics
│   ├── arch.zig                     Public arch-neutral interface (the wall itself)
│   │
│   ├── 📁 x86_64/
│   │   ├── cpu.zig                  CPUID, control regs, halt, pause, features
│   │   ├── gdt.zig                  Global Descriptor Table + TSS + IST stacks
│   │   ├── idt.zig                  Interrupt Descriptor Table, 256 vectors
│   │   ├── isr.zig                  Exception handlers 0–31 (#PF, #GP, #DF…)
│   │   │                            Entry stubs are comptime-generated naked
│   │   │                            functions, not a separate .S file, so the
│   │   │                            vector table and entry code cannot drift
│   │   ├── irq.zig                  Hardware IRQ dispatch and routing
│   │   ├── apic.zig                 Local APIC: timer, EOI, IPI
│   │   ├── ioapic.zig               I/O APIC: IRQ redirection entries
│   │   ├── msr.zig                  Model-Specific Register read/write
│   │   ├── paging.zig               PML4 manipulation, TLB shootdown, CR3
│   │   ├── context.zig              Thread context struct
│   │   ├── switch.S                 ══ THE CONTEXT SWITCH ══ (~40 lines of asm)
│   │   ├── syscall.zig              MSR_STAR/LSTAR/SFMASK setup
│   │   ├── syscall_entry.S          syscall/sysret trampoline, stack swap
│   │   ├── smp.zig              [P7] AP startup (INIT-SIPI-SIPI)
│   │   ├── trampoline.S         [P7] 16-bit → 64-bit AP bring-up code
│   │   ├── fpu.zig                  FPU/SSE/AVX state save and restore (XSAVE)
│   │   ├── io.zig                   Port I/O: inb/outb/inw/outw/inl/outl
│   │   └── serial_early.zig         Raw UART before drivers exist
│   │
│   └── 📁 aarch64/                [P9] Apple Silicon / ARM — mirrors x86_64/
│       ├── cpu.zig                  ...
│       └── (parallel structure)
│
├── 📁 mm/                           Memory management
│   ├── mm.zig                       Subsystem init and public API
│   ├── pmm.zig                      Buddy allocator — physical page frames
│   ├── vmm.zig                      Virtual memory manager, address spaces
│   ├── heap.zig                     kalloc / kfree — the kernel heap
│   ├── slab.zig                     Slab object caches
│   ├── vma.zig                      Virtual memory areas (per-process regions)
│   ├── fault.zig                    Page fault handler: demand paging, COW
│   ├── cow.zig                      Copy-on-write refcounting for fork()
│   ├── shm.zig                      Shared memory objects for IPC
│   ├── mmio.zig                     Device memory mapping helpers
│   └── stats.zig                    Memory accounting — feeds the CI byte budget
│
├── 📁 sched/                        Scheduling and execution
│   ├── sched.zig                    MLFQ scheduler core, pick_next()
│   ├── task.zig                     Task struct: the fundamental unit
│   ├── thread.zig                   Thread lifecycle: create, exit, join
│   ├── process.zig                  Process: address space + threads + fds
│   ├── fork.zig                     fork() — COW address space clone
│   ├── exec.zig                     exec() — ELF load and replace image
│   ├── wait.zig                     Wait queues, blocking, wakeup
│   ├── runqueue.zig                 Per-priority run queues
│   ├── idle.zig                     Idle thread — hlt until interrupted
│   └── signal.zig                   Signal delivery and handler dispatch
│
├── 📁 sync/                         Synchronization primitives
│   ├── spinlock.zig                 Ticket spinlock, IRQ-save variant
│   ├── mutex.zig                    Sleeping mutex
│   ├── rwlock.zig                   Reader/writer lock
│   ├── semaphore.zig                Counting semaphore
│   ├── atomic.zig                   Atomic operation wrappers
│   └── rcu.zig                  [P7] Read-copy-update for lockless reads
│
├── 📁 ipc/                          Inter-process communication
│   ├── ipc.zig                      Subsystem init and public API
│   ├── port.zig                     Named message ports
│   ├── channel.zig                  Bidirectional byte channels
│   ├── message.zig                  Message framing, headers, handle passing
│   ├── capability.zig               Capability table — unforgeable handles
│   ├── handle.zig                   Per-process handle table
│   └── pipe.zig                     Anonymous pipes (POSIX-style)
│
├── 📁 syscall/                      The kernel/user contract
│   ├── syscall.zig                  Dispatch table, entry point from asm
│   ├── table.zig                    Syscall number → handler mapping
│   ├── validate.zig                 ══ Userspace pointer validation ══
│   │                                Every user pointer passes through here
│   ├── sys_mem.zig                  mmap, munmap, mprotect, brk
│   ├── sys_proc.zig                 fork, exec, exit, wait, getpid, kill
│   ├── sys_file.zig                 open, close, read, write, seek, stat
│   ├── sys_dir.zig                  mkdir, rmdir, readdir, chdir, unlink
│   ├── sys_ipc.zig                  port_create, send, recv, shm_*
│   ├── sys_time.zig                 clock_gettime, nanosleep
│   ├── sys_thread.zig               thread_create, thread_exit, futex
│   └── sys_dev.zig                  ioctl, framebuffer and input access
│
├── 📁 fs/                           Filesystems
│   ├── 📁 vfs/                      Virtual filesystem layer
│   │   ├── vfs.zig                  Mount table, path resolution
│   │   ├── inode.zig                Inode abstraction + cache
│   │   ├── dentry.zig               Directory entry cache
│   │   ├── file.zig                 Open file description
│   │   ├── fd.zig                   Per-process file descriptor table
│   │   ├── path.zig                 Path parsing, normalization, lookup
│   │   ├── mount.zig                Mount and unmount logic
│   │   └── pagecache.zig            Unified page cache for file data
│   │
│   ├── 📁 citrusfs/                 ██ OUR NATIVE FILESYSTEM ██
│   │   ├── citrusfs.zig             Mount, unmount, superblock
│   │   ├── superblock.zig           On-disk superblock layout
│   │   ├── inode.zig                On-disk inode, 256 bytes
│   │   ├── extent.zig               Extent tree — contiguous block ranges
│   │   ├── alloc.zig                Block and inode bitmap allocation
│   │   ├── dir.zig                  Directory: hashed B-tree entries
│   │   ├── journal.zig              Write-ahead log for crash safety
│   │   └── format.md                ══ ON-DISK FORMAT SPEC ══
│   │
│   ├── 📁 fat32/                    Interop: read/write FAT32 (ESP, USB sticks)
│   │   ├── fat32.zig
│   │   ├── bpb.zig                  BIOS Parameter Block
│   │   ├── cluster.zig              FAT chain traversal
│   │   └── lfn.zig                  Long filename support
│   │
│   ├── 📁 tmpfs/                    RAM-backed filesystem for /tmp
│   │   └── tmpfs.zig
│   ├── 📁 devfs/                    /dev — device nodes
│   │   └── devfs.zig
│   └── 📁 procfs/                   /proc — kernel state as files
│       └── procfs.zig
│
├── 📁 dev/                          Device discovery and buses
│   ├── device.zig                   Device model: bus, driver, device, probe
│   ├── driver.zig                   Driver registration and matching
│   ├── 📁 pci/
│   │   ├── pci.zig                  Bus enumeration, config space
│   │   ├── ecam.zig                 PCIe memory-mapped config (MCFG)
│   │   ├── ids.zig                  Vendor/device ID tables
│   │   ├── msi.zig                  MSI / MSI-X interrupt setup
│   │   └── bar.zig                  Base Address Register decoding
│   └── 📁 acpi/
│       ├── acpi.zig                 RSDP → RSDT/XSDT table walk
│       ├── madt.zig                 Interrupt controller topology
│       ├── fadt.zig                 Fixed ACPI description, power control
│       ├── mcfg.zig                 PCIe ECAM base addresses
│       └── hpet.zig                 High Precision Event Timer
│
├── 📁 drivers/                      Hardware drivers
│   ├── 📁 char/
│   │   ├── serial.zig               16550 UART — our debug lifeline
│   │   ├── null.zig                 /dev/null, /dev/zero
│   │   └── random.zig               /dev/random, /dev/urandom (ChaCha20)
│   ├── 📁 video/
│   │   ├── framebuffer.zig          Linear FB abstraction from Limine
│   │   ├── fbcon.zig                Kernel text console on the framebuffer
│   │   ├── font.zig                 PSF2 bitmap font renderer
│   │   └── gpu/                 [P8] Real GPU drivers (virtio-gpu first)
│   ├── 📁 input/
│   │   ├── ps2.zig                  8042 controller
│   │   ├── keyboard.zig             Scancode set 2 → keycode → keysym
│   │   ├── mouse.zig                PS/2 mouse, 3-button + scroll
│   │   └── evdev.zig                Unified event queue for userspace
│   ├── 📁 block/
│   │   ├── block.zig                Block device abstraction + request queue
│   │   ├── ahci.zig                 SATA controller
│   │   ├── nvme.zig                 NVMe — the modern path
│   │   ├── ata.zig                  Legacy PIO fallback (QEMU convenience)
│   │   ├── virtio_blk.zig           virtio block — fastest in QEMU
│   │   └── partition.zig            GPT and MBR partition table parsing
│   ├── 📁 net/                  [P6]
│   │   ├── netdev.zig               Network device abstraction
│   │   ├── e1000.zig                Intel gigabit — QEMU default
│   │   ├── rtl8139.zig              Realtek — widely emulated
│   │   └── virtio_net.zig           virtio network
│   ├── 📁 usb/                  [P8] ══ THE BIG ONE. Months of work. ══
│   │   ├── xhci.zig                 USB 3.x host controller
│   │   ├── hub.zig                  Hub and port enumeration
│   │   ├── hid.zig                  Keyboards and mice over USB
│   │   └── msc.zig                  Mass storage class
│   └── 📁 audio/                [P8]
│       ├── hda.zig                  Intel HD Audio
│       └── ac97.zig                 Legacy AC'97
│
├── 📁 net/                      [P6] Network stack
│   ├── net.zig                      Stack init
│   ├── ethernet.zig                 Layer 2 framing
│   ├── arp.zig                      Address resolution + cache
│   ├── ip.zig                       IPv4, routing table, fragmentation
│   ├── icmp.zig                     ping
│   ├── udp.zig                      Datagrams
│   ├── tcp.zig                      ══ The swamp. State machine, windows. ══
│   ├── socket.zig                   BSD socket layer
│   └── dhcp.zig                     Address autoconfiguration
│
├── 📁 time/
│   ├── time.zig                     Monotonic + wall clock
│   ├── tsc.zig                      Timestamp counter, calibration
│   ├── hpet.zig                     HPET as a timer source
│   ├── pit.zig                      Legacy 8253 PIT (calibration only)
│   ├── rtc.zig                      CMOS real-time clock
│   └── timer.zig                    Kernel timer wheel, callbacks
│
├── 📁 debug/                        ██ MARMALADE — debug subsystem ██
│   ├── marmalade.zig                Trace buffer, log levels, ring buffer
│   ├── symbols.zig                  Kernel symbol table for stack traces
│   ├── backtrace.zig                Frame-pointer stack unwinding
│   ├── assert.zig                   Kernel assertions
│   ├── gdbstub.zig              [P5] In-kernel GDB stub
│   └── kasan.zig                [P7] Address sanitizer for kernel heap
│
├── 📁 lib/                          Kernel-internal utilities (no libc here)
│   ├── list.zig                     Intrusive doubly-linked list
│   ├── rbtree.zig                   Red-black tree
│   ├── bitmap.zig                   Bitmap operations
│   ├── hashmap.zig                  Open-addressing hash map
│   ├── ringbuf.zig                  Lock-free ring buffer
│   ├── string.zig                   memcpy, memset, strlen (SIMD where useful)
│   ├── fmt.zig                      printf-style formatting, no allocation
│   ├── elf.zig                      ELF64 parsing and loading
│   ├── crc.zig                      CRC32 for filesystem checksums
│   └── math.zig                     Integer math, no FPU in kernel
│
└── 📁 include/                      Shared headers (kernel ↔ userland ABI)
    ├── syscall_nr.h                 ══ SYSCALL NUMBERS — single source of truth ══
    ├── errno.h                      Error codes
    ├── types.h                      Shared type definitions
    ├── ioctl.h                      ioctl request codes
    └── ipc_abi.h                    IPC message layout
```

---

### 9.4 `userland/` — ring 3

```
userland/
│
├── 📁 libs/                         Shared libraries
│   │
│   ├── 📁 pulp/                     ██ PULP — the C standard library ██
│   │   ├── include/                 Public headers, POSIX-shaped
│   │   │   ├── stdio.h      stdlib.h    string.h    unistd.h
│   │   │   ├── fcntl.h      errno.h     time.h      math.h
│   │   │   ├── pthread.h    signal.h    dirent.h    sys/*.h
│   │   │   └── orange/                  ══ Orange-specific extensions ══
│   │   │       ├── ipc.h                Port and channel API
│   │   │       ├── cap.h                Capability manipulation
│   │   │       └── gfx.h                Framebuffer and input access
│   │   ├── src/
│   │   │   ├── crt0.S               ══ Process entry. Runs before main(). ══
│   │   │   ├── syscall.zig          Raw syscall stubs (the only asm boundary)
│   │   │   ├── stdio/               printf family, FILE*, buffering
│   │   │   ├── stdlib/              malloc, free, exit, env, qsort
│   │   │   ├── string/              str*/mem* with SIMD paths
│   │   │   ├── math/                libm — sin, cos, sqrt, pow
│   │   │   ├── pthread/             Threads, mutexes, condvars over futex
│   │   │   ├── malloc/              ── the userspace allocator ──
│   │   │   │   ├── malloc.zig       Size-class allocator, thread-cached
│   │   │   │   └── arena.zig        Arena management over mmap
│   │   │   └── unistd/              fork, exec, pipe, dup, file ops
│   │   └── README.md
│   │
│   ├── 📁 segment/                  ██ SEGMENT — the widget toolkit ██
│   │   ├── include/segment/
│   │   │   ├── widget.h   window.h   layout.h   theme.h   event.h
│   │   ├── src/
│   │   │   ├── 📁 core/
│   │   │   │   ├── application.zig  Event loop, main() wrapper
│   │   │   │   ├── window.zig       Top-level window, Peel connection
│   │   │   │   ├── widget.zig       Base widget: tree, invalidation, focus
│   │   │   │   ├── event.zig        Event types and propagation
│   │   │   │   └── timer.zig        Widget-level timers
│   │   │   ├── 📁 layout/
│   │   │   │   ├── box.zig          Horizontal / vertical box
│   │   │   │   ├── grid.zig         Grid layout
│   │   │   │   ├── stack.zig        Overlay stack
│   │   │   │   ├── flow.zig         Wrapping flow layout
│   │   │   │   └── constraint.zig   Size constraints and negotiation
│   │   │   ├── 📁 widgets/
│   │   │   │   ├── button.zig       label.zig      textbox.zig
│   │   │   │   ├── checkbox.zig     radio.zig      slider.zig
│   │   │   │   ├── scrollview.zig   listview.zig   treeview.zig
│   │   │   │   ├── tabview.zig      menu.zig       toolbar.zig
│   │   │   │   ├── progress.zig     spinner.zig    tooltip.zig
│   │   │   │   └── dialog.zig       Modal dialogs
│   │   │   ├── 📁 gfx/              ══ THE RENDERER ══
│   │   │   │   ├── canvas.zig       Drawing surface, clip stack
│   │   │   │   ├── painter.zig      High-level drawing API
│   │   │   │   ├── path.zig         Bezier paths, filling, stroking
│   │   │   │   ├── raster.zig       Scanline rasterizer, anti-aliased
│   │   │   │   ├── blit.zig         SIMD blitters — the hot path
│   │   │   │   ├── blend.zig        Alpha compositing modes
│   │   │   │   ├── color.zig        sRGB, linear, HSL conversion
│   │   │   │   ├── gradient.zig     Linear and radial gradients
│   │   │   │   ├── shadow.zig       Box shadows, blur (the macOS look)
│   │   │   │   └── image.zig        PNG/JPEG/QOI decode
│   │   │   ├── 📁 text/
│   │   │   │   ├── font.zig         Font loading and caching
│   │   │   │   ├── truetype.zig     TrueType/OpenType glyph rasterizer
│   │   │   │   ├── shape.zig        Text shaping, kerning, ligatures
│   │   │   │   ├── layout.zig       Line breaking, wrapping, alignment
│   │   │   │   └── atlas.zig        Glyph cache atlas
│   │   │   ├── 📁 theme/
│   │   │   │   ├── theme.zig        Theme loading and token resolution
│   │   │   │   ├── tokens.zig       Color/spacing/radius design tokens
│   │   │   │   └── default.zig      ══ The Orange look, in code ══
│   │   │   └── 📁 anim/
│   │   │       ├── animation.zig    Property animation driver
│   │   │       ├── easing.zig       Easing curves
│   │   │       └── spring.zig       Spring physics (natural motion)
│   │   └── README.md
│   │
│   ├── 📁 libpeel/                  Client library for talking to Peel
│   │   ├── connection.zig           Socket connect, handshake
│   │   ├── surface.zig              Buffer allocation, attach, commit
│   │   ├── protocol.zig             ══ Wire protocol, generated from XML ══
│   │   └── input.zig                Input event decoding
│   │
│   ├── 📁 libipc/                   Higher-level IPC helpers over kernel ports
│   ├── 📁 libcrate/                 Package format reading (for Crate)
│   └── 📁 libconfig/                Config file parsing (TOML-ish)
│
├── 📁 servers/                      Long-running system services
│   │
│   ├── 📁 seed/                     ██ SEED — PID 1 ██
│   │   ├── main.zig                 Boot sequence, then supervise forever
│   │   ├── service.zig              Service definition and lifecycle
│   │   ├── dependency.zig           Dependency graph resolution
│   │   ├── supervisor.zig           Restart policy, backoff, crash counting
│   │   ├── mount.zig                Early mounts: /dev /proc /tmp /run
│   │   └── seed.conf.example        Reference service configuration
│   │
│   ├── 📁 peel/                     ██ PEEL — the display server ██
│   │   ├── main.zig                 Init, then the render loop
│   │   ├── 📁 compositor/
│   │   │   ├── compositor.zig       ══ THE FRAME LOOP ══
│   │   │   ├── scene.zig            Scene graph, z-order
│   │   │   ├── surface.zig          Client surfaces and their buffers
│   │   │   ├── damage.zig           ══ Damage tracking — only redraw dirt ══
│   │   │   ├── output.zig           Physical output / framebuffer target
│   │   │   └── cursor.zig           Hardware-free cursor compositing
│   │   ├── 📁 wm/
│   │   │   ├── window.zig           Window state: position, size, flags
│   │   │   ├── stacking.zig         Z-order, focus-follows-raise
│   │   │   ├── decoration.zig       Title bars, borders, shadows
│   │   │   ├── move_resize.zig      Interactive drag and resize
│   │   │   ├── snap.zig             Edge snapping, tiling shortcuts
│   │   │   └── workspace.zig        Virtual desktops
│   │   ├── 📁 input/
│   │   │   ├── input.zig            Read from /dev/input, decode
│   │   │   ├── pointer.zig          Pointer position, buttons, hit testing
│   │   │   ├── keyboard.zig         Keymaps, modifiers, repeat
│   │   │   ├── focus.zig            Keyboard and pointer focus tracking
│   │   │   └── hotkey.zig           Global shortcut registry
│   │   ├── 📁 render/
│   │   │   ├── backend.zig          Render backend interface
│   │   │   ├── software.zig         ══ CPU compositing — the default path ══
│   │   │   ├── gpu.zig          [P8] GPU-accelerated backend
│   │   │   └── effects.zig          Blur, rounded corners, drop shadow
│   │   └── 📁 protocol/
│   │       ├── peel.xml             ══ PROTOCOL DEFINITION ══
│   │       ├── generated.zig        Auto-generated from peel.xml
│   │       └── server.zig           Server-side protocol dispatch
│   │
│   ├── 📁 devmgr/                   Device node management, hotplug events
│   ├── 📁 netd/                 [P6] DHCP client, routing, DNS resolution
│   ├── 📁 audiod/               [P8] Audio mixing and routing
│   └── 📁 logd/                     System log collection and rotation
│
├── 📁 apps/                         GUI applications
│   │
│   ├── 📁 grove/                    ██ GROVE — the desktop shell ██
│   │   ├── main.zig
│   │   ├── panel.zig                Top panel: clock, status, menus
│   │   ├── dock.zig                 Application dock
│   │   ├── launcher.zig             Application launcher / search
│   │   ├── notification.zig         Notification popups
│   │   ├── wallpaper.zig            Desktop background
│   │   ├── switcher.zig             Alt-Tab window switcher
│   │   └── lockscreen.zig           Session lock
│   │
│   ├── 📁 squeeze/                  ██ SQUEEZE — terminal emulator ██
│   │   ├── main.zig
│   │   ├── terminal.zig             Grid, scrollback, selection
│   │   ├── vt.zig                   VT100/xterm escape sequence parser
│   │   ├── pty.zig                  Pseudo-terminal handling
│   │   └── renderer.zig             Fast monospace glyph rendering
│   │
│   ├── 📁 files/                    File browser
│   ├── 📁 settings/                 System settings panel
│   ├── 📁 editor/                   Text editor
│   ├── 📁 viewer/                   Image viewer
│   ├── 📁 monitor/                  System monitor (CPU, RAM, processes)
│   └── 📁 calculator/               The traditional first GUI app
│
└── 📁 bin/                          Command-line utilities
    ├── 📁 juice/                    ██ JUICE — the shell ██
    │   ├── main.zig
    │   ├── lexer.zig                Tokenizer
    │   ├── parser.zig               Command, pipeline, redirect parsing
    │   ├── exec.zig                 Fork/exec, job control
    │   ├── builtin.zig              cd, export, alias, jobs, fg, bg
    │   ├── expand.zig               Globbing, variable expansion
    │   └── history.zig              Command history and line editing
    │
    ├── coreutils/                   ls  cat  cp  mv  rm  mkdir  rmdir
    │                                echo  pwd  touch  ln  chmod  stat
    │                                head  tail  wc  sort  uniq  cut
    │                                grep  find  which  env  date  sleep
    ├── ps.zig  top.zig  kill.zig    Process tools
    ├── mount.zig  umount.zig  df.zig  du.zig
    ├── ping.zig  ifconfig.zig   [P6]
    └── uname.zig  free.zig  dmesg.zig
```

### 9.5 `tools/`, `tests/`, `docs/`, and the rest

```
tools/                               Runs on macOS, not on Orange OS
├── 📁 crate/                        ██ CRATE — the package manager ██
│   ├── main.zig                     install, remove, update, search
│   ├── format.zig                   .crate archive format
│   ├── manifest.zig                 Package metadata
│   ├── resolve.zig                  Dependency resolution
│   └── repo.zig                     Repository index handling
├── 📁 mkcitrusfs/                   Create and populate a CitrusFS image
│   ├── main.zig
│   └── populate.zig                 Copy a host directory into the image
├── 📁 mkimage/                      Build the bootable disk image / ISO
│   ├── gpt.zig                      GPT partition table writer
│   └── esp.zig                      EFI System Partition assembly
├── 📁 protogen/                     Generate Peel protocol code from peel.xml
├── 📁 symgen/                       Generate the kernel symbol table
├── 📁 fontconv/                     TTF → internal atlas format
├── 📁 themegen/                     Design tokens → theme binary
└── 📁 qemu/
    ├── run.sh                       Standard QEMU launch
    ├── debug.sh                     QEMU + GDB stub, halted at reset
    ├── trace.sh                     -d int,cpu_reset for fault diagnosis
    └── gdbinit                      GDB init: symbols, layout, helpers

tests/
├── 📁 unit/                         Host-run unit tests (zig test)
│   ├── mm/       buddy, slab, vma allocation invariants
│   ├── lib/      list, rbtree, hashmap, fmt
│   ├── fs/       CitrusFS format round-trips
│   └── gfx/      Blitters, blending, rasterizer correctness
├── 📁 integration/                  Run inside the OS, report over serial
│   ├── syscall_test.zig             Every syscall, valid and invalid input
│   ├── fork_test.zig                Process creation stress
│   ├── mm_test.zig                  Allocation stress, fragmentation
│   ├── fs_test.zig                  Filesystem stress, crash consistency
│   └── ipc_test.zig                 Port and channel semantics
├── 📁 boot/                         Automated boot-to-marker tests
│   └── expect_boot.sh               Boot in QEMU, assert serial output, exit
└── 📁 bench/
    ├── syscall_bench.zig            Syscall round-trip latency
    ├── ctx_switch_bench.zig         Context switch cost
    ├── alloc_bench.zig              Allocator throughput
    └── memory_budget.zig            ══ CI FAILS IF RSS REGRESSES ══

docs/
├── 📁 design/                       One doc per major decision
│   ├── 001-kernel-model.md          Why monolithic + modules
│   ├── 002-memory-layout.md         Address space rationale
│   ├── 003-scheduler.md             Why MLFQ, tuning parameters
│   ├── 004-syscall-abi.md           Full ABI specification
│   ├── 005-ipc-capabilities.md      Capability model
│   ├── 006-citrusfs.md              Filesystem design and on-disk format
│   ├── 007-peel-protocol.md         Display protocol specification
│   └── 008-visual-language.md       ══ THE DESIGN SYSTEM ══
├── 📁 hacking/
│   ├── getting-started.md           Clone → build → boot in 5 minutes
│   ├── debugging.md                 GDB, QEMU tracing, reading a panic
│   ├── adding-a-driver.md           Driver author's guide
│   ├── adding-a-syscall.md          Checklist for a new syscall
│   └── style.md                     Coding conventions
├── 📁 reference/
│   ├── syscalls.md                  Generated syscall reference
│   ├── boot-protocol.md             What Limine hands us
│   └── memory-map.md                Address space reference
└── 📁 notes/                        Research, hardware datasheets, scratch

assets/
├── 📁 fonts/
│   ├── ui/                          UI typeface — regular, medium, bold
│   ├── mono/                        Terminal typeface
│   └── console.psf                  Kernel console bitmap font
├── 📁 icons/                        System and application icons (SVG source)
├── 📁 cursors/                      Cursor theme
├── 📁 wallpapers/                   Default backgrounds
└── 📁 branding/                     Logo, boot splash, marks

scripts/
├── setup-macos.sh                   brew install qemu zig, fetch Limine
├── build.sh                         Full build → bootable ISO
├── run.sh                           Build and boot in QEMU
├── debug.sh                         Build and boot halted, attach GDB
├── clean.sh                         Remove build artifacts
├── fmt.sh                           zig fmt across the tree
├── lint.sh                          Style and convention checks
└── loc.sh                           Line count by subsystem

third_party/                         Kept deliberately minimal
├── limine/                          Bootloader binaries (BSD-licensed)
└── LICENSES.md                      Every external license, tracked

build/                               Generated — gitignored
├── kernel.elf                       The linked kernel
├── kernel.map                       Symbol map for stack traces
├── orange.iso                       ══ THE BOOTABLE IMAGE ══
├── orange.img                       Raw disk image for USB writing
├── initrd.img                       Initial ramdisk
└── rootfs/                          Staged root filesystem before imaging
```

---

## 10. Kernel Subsystems

### 10.1 The Task model

Orange OS separates **process** (a resource container) from **thread** (a unit of
execution), the same way every serious OS does.

```
   ┌─ PROCESS ────────────────────────────────────────────────────┐
   │  pid, ppid, name, state, exit_code                           │
   │                                                              │
   │  ┌────────────────┐  ┌────────────────┐  ┌────────────────┐  │
   │  │ AddressSpace   │  │ FdTable        │  │ HandleTable    │  │
   │  │  PML4 root     │  │  0 → stdin     │  │  caps to ports │  │
   │  │  VMA red-black │  │  1 → stdout    │  │  caps to shm   │  │
   │  │  tree          │  │  2 → stderr    │  │  caps to dev   │  │
   │  └────────────────┘  └────────────────┘  └────────────────┘  │
   │                                                              │
   │  ┌────────────────┐  ┌────────────────┐                      │
   │  │ SignalState    │  │ Credentials    │                      │
   │  └────────────────┘  └────────────────┘                      │
   │                                                              │
   │  threads: ──┬────────────┬────────────┐                      │
   └─────────────┼────────────┼────────────┼──────────────────────┘
                 ▼            ▼            ▼
        ┌─ THREAD ──┐ ┌─ THREAD ──┐ ┌─ THREAD ──┐
        │ tid       │ │ tid       │ │ tid       │
        │ Context   │ │ Context   │ │ Context   │  ← saved registers
        │ kstack    │ │ kstack    │ │ kstack    │  ← 16 KB kernel stack
        │ state     │ │ state     │ │ state     │
        │ priority  │ │ priority  │ │ priority  │
        │ quantum   │ │ quantum   │ │ quantum   │
        │ fpu_state │ │ fpu_state │ │ fpu_state │  ← XSAVE area
        └───────────┘ └───────────┘ └───────────┘
```

**Thread states and transitions:**

```
                      thread_create()
                            │
                            ▼
                      ┌──────────┐
              ┌──────▶│  READY   │◀──────┐
              │       └────┬─────┘       │
              │            │ scheduled   │ wakeup / signal
     quantum  │            ▼             │
     expired  │       ┌──────────┐       │
     preempt  └───────│ RUNNING  │───────┤
                      └────┬─────┘  blocks on:
                           │        ├ I/O
                    exit() │        ├ mutex
                           │        ├ IPC recv
                           ▼        └ sleep
                      ┌──────────┐  │       ┌──────────┐
                      │  ZOMBIE  │  └──────▶│ BLOCKED  │
                      └────┬─────┘          └──────────┘
                           │ parent wait()
                           ▼
                        [freed]
```

### 10.2 Scheduler — MLFQ

Four priority levels. Interactive work naturally floats up; CPU hogs sink.

```
   ┌────────────────────────────────────────────────────────────────────┐
   │                                                                    │
   │  LEVEL 0  REALTIME    quantum  1 ms   ┌──┬──┬──┐                   │
   │           audio, input, compositor    │T1│T2│  │  never demoted    │
   │                                       └──┴──┴──┘                   │
   │              │ (only runs if empty)                                │
   │              ▼                                                     │
   │  LEVEL 1  INTERACTIVE quantum  4 ms   ┌──┬──┬──┬──┐                │
   │           GUI apps, shells            │T3│T4│T5│  │                │
   │                                       └──┴──┴──┴──┘                │
   │              │                    ▲                                │
   │              ▼ used full quantum  │ blocked before quantum end     │
   │  LEVEL 2  NORMAL      quantum 16 ms   ┌──┬──┬──┐   (= interactive) │
   │           default for new threads     │T6│T7│  │                   │
   │                                       └──┴──┴──┘                   │
   │              │                    ▲                                │
   │              ▼ used full quantum  │                                │
   │  LEVEL 3  BATCH       quantum 64 ms   ┌──┬──┐                      │
   │           compilers, indexers         │T8│  │                      │
   │                                       └──┴──┘                      │
   │                                                                    │
   │  ┌──────────────────────────────────────────────────────────────┐  │
   │  │  ANTI-STARVATION: every 1000 ms, all threads are boosted to  │  │
   │  │  level 1. Nothing can be starved indefinitely.               │  │
   │  └──────────────────────────────────────────────────────────────┘  │
   │                                                                    │
   │  IDLE — runs only when every level is empty. Executes hlt.         │
   └────────────────────────────────────────────────────────────────────┘
```

**Rules:**
1. Always run the highest-priority ready thread. Round-robin within a level.
2. A thread that consumes its full quantum drops one level (it's CPU-bound).
3. A thread that blocks before its quantum ends stays put (it's interactive).
4. Every 1000 ms, everything is boosted to level 1 (anti-starvation).
5. Level 0 is granted only by capability — apps cannot promote themselves.

### 10.3 Context switch

The most delicate ~40 lines in the entire project.

```
   Thread A running                          Thread B ready
        │                                          │
        ▼                                          │
   ┌─────────────────────────────────────┐         │
   │ timer IRQ fires → APIC → IDT vector  │         │
   └────────────────┬────────────────────┘         │
                    ▼                              │
   ┌─────────────────────────────────────┐         │
   │ isr_stubs.S: push all GP registers  │         │
   │ → builds a TrapFrame on A's kstack  │         │
   └────────────────┬────────────────────┘         │
                    ▼                              │
   ┌─────────────────────────────────────┐         │
   │ sched.tick() → A's quantum expired  │         │
   │ sched.pick_next() → returns B       │         │
   └────────────────┬────────────────────┘         │
                    ▼                              │
   ┌─────────────────────────────────────┐         │
   │ switch.S  context_switch(&A, &B)    │         │
   │  1. save callee-saved regs → A.ctx  │         │
   │  2. save rsp → A.ctx.rsp            │         │
   │  3. if different process: load CR3  │─────────┤ ← TLB flush,
   │  4. update TSS.rsp0 = B.kstack_top  │         │   the expensive part
   │  5. load rsp ← B.ctx.rsp            │         │
   │  6. restore callee-saved from B.ctx │         │
   │  7. ret → lands in B's saved rip    │         │
   └────────────────┬────────────────────┘         │
                    │                              ▼
                    │                    ┌─────────────────────┐
                    │                    │ B pops its TrapFrame│
                    │                    │ iretq → B resumes   │
                    │                    └─────────────────────┘
                    ▼                              │
              Thread A now READY                Thread B RUNNING
```

> **Target:** under 500 ns per switch on modern hardware. Measured every build by
> `tests/bench/ctx_switch_bench.zig`.

---

## 11. Syscall ABI

### 11.1 Calling convention

We use the `syscall`/`sysret` instruction pair, not `int 0x80`.

```
   USER SIDE                              register layout
   ─────────                              ───────────────
   mov rax, <syscall number>              rax  ← number     (return value out)
   mov rdi, arg0                          rdi  ← arg 0
   mov rsi, arg1                          rsi  ← arg 1
   mov rdx, arg2                          rdx  ← arg 2
   mov r10, arg3       ← NOT rcx!         r10  ← arg 3
   mov r8,  arg4                          r8   ← arg 4
   mov r9,  arg5                          r9   ← arg 5
   syscall
                                          CLOBBERED by the instruction:
                                          rcx  ← return rip  (hardware)
                                          r11  ← saved rflags (hardware)

   ┌──────────────────────────────────────────────────────────────────┐
   │  This is why arg3 lives in r10: the CPU itself overwrites rcx.   │
   └──────────────────────────────────────────────────────────────────┘

   KERNEL SIDE — syscall_entry.S
   ─────────────────────────────
   1. swapgs                     → GS now points at per-CPU kernel data
   2. save user rsp to per-CPU scratch
   3. load kernel rsp from TSS
   4. push a full TrapFrame
   5. validate rax < SYSCALL_MAX
   6. call syscall_table[rax]
   7. pop TrapFrame, restore user rsp
   8. swapgs
   9. sysretq

   RETURN VALUE
   ────────────
   rax ≥ 0   → success (value, or count, or fd)
   rax < 0   → -errno   e.g. -2 = -ENOENT, -12 = -ENOMEM
```

### 11.2 Syscall table

Roughly 80 calls at Phase 8. Numbers are stable once assigned — **never reuse a
retired number.**

| #  | Name | Signature | Phase |
|----|------|-----------|-------|
| | **── Process ──** | | |
| 0 | `exit` | `(status: i32) noreturn` | P4 |
| 1 | `fork` | `() → pid` | P4 |
| 2 | `exec` | `(path, argv, envp) → !noreturn` | P4 |
| 3 | `wait` | `(pid, *status, flags) → pid` | P4 |
| 4 | `getpid` | `() → pid` | P4 |
| 5 | `getppid` | `() → pid` | P4 |
| 6 | `kill` | `(pid, sig) → !void` | P5 |
| 7 | `yield` | `() → void` | P4 |
| | **── Memory ──** | | |
| 10 | `mmap` | `(addr, len, prot, flags, fd, off) → ptr` | P4 |
| 11 | `munmap` | `(addr, len) → !void` | P4 |
| 12 | `mprotect` | `(addr, len, prot) → !void` | P4 |
| 13 | `brk` | `(addr) → ptr` | P4 |
| | **── File I/O ──** | | |
| 20 | `open` | `(path, flags, mode) → fd` | P5 |
| 21 | `close` | `(fd) → !void` | P5 |
| 22 | `read` | `(fd, buf, len) → count` | P5 |
| 23 | `write` | `(fd, buf, len) → count` | P5 |
| 24 | `seek` | `(fd, off, whence) → off` | P5 |
| 25 | `stat` | `(path, *statbuf) → !void` | P5 |
| 26 | `fstat` | `(fd, *statbuf) → !void` | P5 |
| 27 | `dup` / `dup2` | `(fd[, newfd]) → fd` | P5 |
| 28 | `pipe` | `(*[2]fd) → !void` | P5 |
| 29 | `ioctl` | `(fd, req, arg) → !isize` | P5 |
| | **── Directories ──** | | |
| 30 | `mkdir` | `(path, mode) → !void` | P5 |
| 31 | `rmdir` | `(path) → !void` | P5 |
| 32 | `unlink` | `(path) → !void` | P5 |
| 33 | `rename` | `(old, new) → !void` | P5 |
| 34 | `readdir` | `(fd, *dirent, n) → count` | P5 |
| 35 | `chdir` | `(path) → !void` | P5 |
| 36 | `getcwd` | `(buf, len) → !usize` | P5 |
| 37 | `mount` | `(src, dst, fstype, flags) → !void` | P5 |
| | **── Threads ──** | | |
| 40 | `thread_create` | `(entry, arg, stack) → tid` | P4 |
| 41 | `thread_exit` | `(status) noreturn` | P4 |
| 42 | `thread_join` | `(tid, *status) → !void` | P4 |
| 43 | `futex_wait` | `(*u32, expected, timeout) → !void` | P4 |
| 44 | `futex_wake` | `(*u32, count) → count` | P4 |
| | **── IPC ──** | | |
| 50 | `port_create` | `(name, flags) → handle` | P6 |
| 51 | `port_connect` | `(name) → handle` | P6 |
| 52 | `port_send` | `(h, *msg, nhandles) → !void` | P6 |
| 53 | `port_recv` | `(h, *msg, flags) → !void` | P6 |
| 54 | `shm_create` | `(size, flags) → handle` | P6 |
| 55 | `shm_map` | `(h, prot) → ptr` | P6 |
| 56 | `handle_close` | `(h) → !void` | P6 |
| 57 | `handle_dup` | `(h) → handle` | P6 |
| | **── Time ──** | | |
| 60 | `clock_gettime` | `(clockid, *timespec) → !void` | P3 |
| 61 | `nanosleep` | `(*timespec, *rem) → !void` | P4 |
| | **── Device / Graphics ──** | | |
| 70 | `fb_acquire` | `(*fbinfo) → handle` | P7 |
| 71 | `fb_map` | `(h) → ptr` | P7 |
| 72 | `input_open` | `(devid) → fd` | P7 |
| | **── System ──** | | |
| 78 | `uname` | `(*utsname) → !void` | P5 |
| 79 | `sysinfo` | `(*sysinfo) → !void` | P5 |

### 11.3 The validation rule

> ⚠️ **Every pointer arriving from userspace is hostile until proven otherwise.**

`kernel/syscall/validate.zig` is the single chokepoint. It checks:

```
   user pointer arrives
          │
          ▼
   ┌─────────────────────────────────────────────────┐
   │ 1. Is addr < 0x0000_8000_0000_0000?             │  ← must be user half
   │ 2. Does addr + len overflow?                    │  ← integer safety
   │ 3. Is the whole range mapped in this process?   │  ← VMA lookup
   │ 4. Does the VMA permit the required access?     │  ← R / W / X
   │ 5. Copy through copy_from_user / copy_to_user   │  ← never deref directly
   └─────────────────────────────────────────────────┘
          │                              │
       PASS                           FAIL → return -EFAULT
```

**The kernel never dereferences a user pointer directly. Ever.** A single
violation of this rule is a privilege-escalation vulnerability.

---

## 12. IPC Model

Capability-based. A handle is an opaque integer that is meaningless outside the
process that owns it — you cannot guess or forge one.

```
   ┌─ PROCESS A ──────────────┐          ┌─ PROCESS B ──────────────┐
   │                          │          │                          │
   │  HandleTable             │          │  HandleTable             │
   │  ┌────┬──────────────┐   │          │  ┌────┬──────────────┐   │
   │  │ 3  │ port "peel"  │───┼────┐     │  │ 7  │ port "peel"  │   │
   │  │ 4  │ shm  #12     │───┼──┐ │     │  │ 8  │ shm  #12     │   │
   │  └────┴──────────────┘   │  │ │     │  └────┴──────────────┘   │
   └──────────────────────────┘  │ │     └──────────────────────────┘
                                 │ │              ▲        ▲
   ══ KERNEL ════════════════════╪═╪══════════════╪════════╪════════
                                 │ │              │        │
       ┌─────────────────────────┼─┼──────────────┘        │
       │                         │ └───────────────────────┤
       ▼                         ▼                         │
   ┌────────────────┐    ┌───────────────────┐             │
   │ PORT "peel"    │    │ SHM OBJECT #12    │◀────────────┘
   │ ────────────── │    │ ───────────────── │
   │ msg queue:     │    │ 4 MB, refcount 2  │
   │  ┌──┬──┬──┐    │    │ physical pages:   │
   │  │M1│M2│M3│    │    │  [p0][p1][p2]...  │  ← mapped into BOTH
   │  └──┴──┴──┘    │    └───────────────────┘     address spaces
   │ waiters: [B]   │
   └────────────────┘

   ┌────────────────────────────────────────────────────────────────────┐
   │  CONTROL PLANE  → ports. Small messages. Kernel copies them.       │
   │  DATA PLANE     → shared memory. Bulk bytes. Kernel never copies.  │
   │                                                                    │
   │  A 4K window buffer is never memcpy'd through the kernel — the     │
   │  client writes it and sends a 32-byte "damage" message.            │
   └────────────────────────────────────────────────────────────────────┘
```

**Message layout** (`kernel/include/ipc_abi.h`):

```
   ┌────────────────────────────────────────────────────────────────┐
   │ Header  32 bytes                                               │
   ├────────────┬────────────┬────────────┬─────────────────────────┤
   │ magic  u32 │ opcode u32 │ len    u32 │ nhandles u32            │
   │ seq    u64 │ sender u32 │ flags  u32 │                         │
   ├────────────┴────────────┴────────────┴─────────────────────────┤
   │ Handles   nhandles × u32   (translated across the boundary)    │
   ├────────────────────────────────────────────────────────────────┤
   │ Payload   len bytes, ≤ 4096                                    │
   └────────────────────────────────────────────────────────────────┘
```

Handles are **translated** as they cross: handle 4 in A becomes handle 8 in B,
pointing at the same kernel object with an incremented refcount. B can never
address an object it wasn't given.

---

## 13. Graphics Stack

### 13.1 From pixel to screen

```
  ┌────────────────────────────────────────────────────────────────────┐
  │  APPLICATION                                                       │
  │  segment.Button.draw(painter)                                      │
  │      painter.roundedRect(rect, radius: 8)                          │
  │      painter.fillGradient(from, to)                                │
  │      painter.text("Click me", font, color)                         │
  └────────────────────────────┬───────────────────────────────────────┘
                               ▼  writes pixels into
  ┌────────────────────────────────────────────────────────────────────┐
  │  CLIENT BUFFER  (shared memory, allocated via shm_create)          │
  │  ┌──────────────────────────────────────┐                          │
  │  │ ARGB8888, width × height × 4 bytes    │  double-buffered         │
  │  └──────────────────────────────────────┘                          │
  └────────────────────────────┬───────────────────────────────────────┘
                               ▼  surface.commit(damage_rect)
  ┌────────────────────────────────────────────────────────────────────┐
  │  PEEL — COMPOSITOR                                                 │
  │                                                                    │
  │  1. Collect damage from all clients this frame                     │
  │     ┌───────────────────────────────────────────┐                  │
  │     │  screen                                   │                  │
  │     │      ┌────────┐                           │                  │
  │     │      │▓▓▓▓▓▓▓▓│ ← only this region is     │  ══ DAMAGE ══    │
  │     │      │▓ dirty │   recomposited            │  the single      │
  │     │      └────────┘                           │  biggest         │
  │     │                        ┌──────┐           │  performance     │
  │     │                        │clean │ skipped   │  lever           │
  │     │                        └──────┘           │                  │
  │     └───────────────────────────────────────────┘                  │
  │                                                                    │
  │  2. Walk the scene graph back-to-front within damage               │
  │     wallpaper → windows (z-order) → decorations → cursor           │
  │                                                                    │
  │  3. Blit + blend each surface  (SIMD, in software)                 │
  │  4. Apply effects: shadow, rounded corners, blur                   │
  └────────────────────────────┬───────────────────────────────────────┘
                               ▼  memcpy into the real framebuffer
  ┌────────────────────────────────────────────────────────────────────┐
  │  KERNEL FRAMEBUFFER  (mapped write-combining, via fb_map)          │
  └────────────────────────────┬───────────────────────────────────────┘
                               ▼
  ┌────────────────────────────────────────────────────────────────────┐
  │  DISPLAY                                                           │
  └────────────────────────────────────────────────────────────────────┘
```

### 13.2 Why software rendering is enough

```
   1920 × 1080 × 4 bytes  =  8.3 MB per full frame
   at 60 Hz               =  498 MB/s

   Modern CPU memory bandwidth: 20–50 GB/s
   ─────────────────────────────────────────────────────────
   A full-screen redraw uses ~1–2% of available bandwidth.

   And with damage tracking, a typical frame redraws
   under 5% of the screen. We are nowhere near a limit.
```

Retina-class panels (3024 × 1964) change the math, which is why damage tracking
is not an optimization to add later — it is designed in from the first frame.

### 13.3 Input flow

```
   physical key press
          │
          ▼
   ┌──────────────────┐   IRQ 1
   │ PS/2 controller  │──────────▶ kernel/drivers/input/ps2.zig
   └──────────────────┘
          │  scancode (set 2)
          ▼
   ┌──────────────────┐
   │ keyboard.zig     │  scancode → keycode → keysym + modifier state
   └──────────────────┘
          │  InputEvent { type, code, value, timestamp }
          ▼
   ┌──────────────────┐
   │ evdev.zig        │  ring buffer, readable at /dev/input/event0
   └──────────────────┘
          │  read()
          ▼
   ┌──────────────────┐
   │ PEEL input.zig   │  applies keymap, tracks focus
   └──────────────────┘
          │  routed to the focused surface only
          ▼
   ┌──────────────────┐
   │ libpeel client   │  decodes into a Segment event
   └──────────────────┘
          │
          ▼
   ┌──────────────────┐
   │ Widget.onKeyDown │  the application finally sees it
   └──────────────────┘
```

---

## 14. Filesystem Design

### 14.1 VFS layering

```
   open("/home/vish/notes.txt", O_RDWR)
          │
          ▼
   ┌────────────────────────────────────────────────────────┐
   │  VFS — path resolution                                 │
   │  "/" → root mount → CitrusFS                           │
   │  "home" → dentry cache HIT                             │
   │  "vish" → dentry cache HIT                             │
   │  "notes.txt" → MISS → ask the filesystem               │
   └───────────────────────┬────────────────────────────────┘
                           ▼   inode_ops.lookup()
   ┌────────────────────────────────────────────────────────┐
   │  MOUNT TABLE                                           │
   │   /          → CitrusFS   on nvme0p2                   │
   │   /boot      → FAT32      on nvme0p1  (ESP)            │
   │   /dev       → devfs      (virtual)                    │
   │   /proc      → procfs     (virtual)                    │
   │   /tmp       → tmpfs      (RAM)                        │
   └───────────────────────┬────────────────────────────────┘
                           ▼
   ┌────────────────────────────────────────────────────────┐
   │  CITRUSFS                                              │
   │  inode 4271 → extent tree → blocks 88120..88134        │
   └───────────────────────┬────────────────────────────────┘
                           ▼
   ┌────────────────────────────────────────────────────────┐
   │  PAGE CACHE — is the block already in RAM?             │
   │     HIT  → return immediately, zero I/O                │
   │     MISS → issue a block request                       │
   └───────────────────────┬────────────────────────────────┘
                           ▼
   ┌────────────────────────────────────────────────────────┐
   │  BLOCK LAYER → NVMe driver → hardware                  │
   └────────────────────────────────────────────────────────┘
```

### 14.2 CitrusFS on-disk layout

```
   ┌───────────────────────────────────────────────────────────────────────┐
   │ BLOCK 0        │ SUPERBLOCK                                           │
   │                │ magic "CTRS" · version · block_size · total_blocks   │
   │                │ inode_count · free_blocks · journal_start · uuid     │
   │                │ root_inode · state (CLEAN/DIRTY) · checksum          │
   ├────────────────┼──────────────────────────────────────────────────────┤
   │ BLOCK 1        │ SUPERBLOCK BACKUP (identical, for recovery)          │
   ├────────────────┼──────────────────────────────────────────────────────┤
   │ BLOCKS 2..N    │ ██ JOURNAL ██  write-ahead log, circular             │
   │                │ every metadata change lands here first               │
   │                │ ┌─────────────────────────────────────────────────┐  │
   │                │ │ TXN_BEGIN │ block writes... │ TXN_COMMIT │ ...  │  │
   │                │ └─────────────────────────────────────────────────┘  │
   │                │ crash between BEGIN and COMMIT → transaction         │
   │                │ discarded on mount. The FS is never half-updated.    │
   ├────────────────┼──────────────────────────────────────────────────────┤
   │ BLOCKS N..M    │ BLOCK BITMAP — 1 bit per data block                  │
   ├────────────────┼──────────────────────────────────────────────────────┤
   │ BLOCKS M..P    │ INODE BITMAP                                         │
   ├────────────────┼──────────────────────────────────────────────────────┤
   │ BLOCKS P..Q    │ INODE TABLE — 256 bytes each                         │
   │                │ ┌──────────────────────────────────────────────────┐ │
   │                │ │ mode · uid · gid · size · nlinks                 │ │
   │                │ │ atime · mtime · ctime · btime  (64-bit, ns)      │ │
   │                │ │ extent_tree_root  ← not block pointers: EXTENTS  │ │
   │                │ │ flags · checksum                                 │ │
   │                │ └──────────────────────────────────────────────────┘ │
   ├────────────────┼──────────────────────────────────────────────────────┤
   │ BLOCKS Q..END  │ DATA BLOCKS — 4 KB each                             │
   └────────────────┴──────────────────────────────────────────────────────┘
```

**Why extents instead of block pointers:** a 1 GB contiguous file is one extent
record (`start=88120, len=262144`) instead of 262,144 individual pointers. Less
metadata, fewer reads, dramatically faster large-file I/O.

**Why journaling:** power loss during a write must never produce a corrupt
filesystem. Metadata goes to the journal, then to its final location. A crash in
between means the journal replays or discards on next mount — never a half-state.

---

## 15. Build System

One `build.zig` at the root drives everything. Zig cross-compiles to bare metal
from macOS with no external toolchain.

```
   ┌─ HOST: macOS (arm64 or x86_64) ────────────────────────────────────────┐
   │                                                                        │
   │   zig build                                                            │
   │       │                                                                │
   │       ├──▶ [1] TOOLS  (native, run on the host)                        │
   │       │        protogen  → peel.xml  → generated.zig                   │
   │       │        fontconv  → *.ttf     → *.atlas                         │
   │       │        themegen  → tokens    → theme.bin                       │
   │       │        symgen    → kernel.map → symbols.zig                    │
   │       │                                                                │
   │       ├──▶ [2] KERNEL  target: x86_64-freestanding-none                │
   │       │        cpu features: -mmx -sse -sse2 -avx +soft_float          │
   │       │        code model: kernel        red zone: DISABLED            │
   │       │        linker script: boot/linker-x86_64.ld                    │
   │       │        ══▶ build/kernel.elf + build/kernel.map                 │
   │       │                                                                │
   │       ├──▶ [3] USERLAND  target: x86_64-orange-none                    │
   │       │        pulp → libpulp.a                                        │
   │       │        segment, libpeel → static libs                          │
   │       │        seed, peel, devmgr, logd → server binaries              │
   │       │        grove, squeeze, files, ... → app binaries               │
   │       │        juice + coreutils → /bin                                │
   │       │        ══▶ build/rootfs/                                       │
   │       │                                                                │
   │       ├──▶ [4] ASSETS   fonts, icons, wallpapers → build/rootfs/       │
   │       │                                                                │
   │       ├──▶ [5] IMAGE                                                   │
   │       │        mkcitrusfs  build/rootfs/  → rootfs.img                 │
   │       │        mkimage     GPT: [ESP | CitrusFS]                       │
   │       │        xorriso     → ══▶ build/orange.iso ◀══                  │
   │       │                                                                │
   │       └──▶ [6] RUN                                                     │
   │                qemu-system-x86_64 -M q35 -m 512M -cdrom orange.iso     │
   └────────────────────────────────────────────────────────────────────────┘
```

### 15.1 Commands

```bash
zig build                 # Build everything → build/orange.iso
zig build run             # Build and boot in QEMU
zig build debug           # Boot halted with a GDB stub on :1234
zig build test            # Host-side unit tests
zig build test-integration# Boot in QEMU, run in-OS tests, assert on serial
zig build bench           # Performance benchmarks + memory budget check
zig build usb -Ddev=/dev/diskN   # Write a bootable USB stick
zig build clean
```

### 15.2 Critical kernel compile flags

| Flag | Why it is non-negotiable |
|------|--------------------------|
| `red_zone = false` | Interrupts clobber the 128-byte red zone. Leaving it on causes stack corruption that is nearly impossible to diagnose. |
| `-mno-sse -mno-mmx -mno-avx` | The kernel must not touch FPU/SIMD registers implicitly — we don't save them on every entry. |
| `code_model = .kernel` | Required for the higher-half address at `0xFFFFFFFF80000000`. |
| `soft_float` | No floating point in the kernel, full stop. |
| `-fno-stack-protector` | No `__stack_chk_fail` symbol exists at ring 0. |
| `pic = false` | The kernel is loaded at a fixed address; PIC adds pointless indirection. |
| `omit_frame_pointer = false` | Frame pointers are what make stack traces possible in a panic. |

### 15.3 The debug loop

```
   ┌─────────────────────────────────────────────────────────────────┐
   │  Terminal 1                     Terminal 2                      │
   │  ──────────                     ──────────                      │
   │  $ zig build debug              $ gdb build/kernel.elf          │
   │                                 (gdb) target remote :1234       │
   │  QEMU starts, CPU halted        (gdb) break kmain               │
   │  waiting for GDB on :1234       (gdb) continue                  │
   │                                 (gdb) layout src                │
   │                                 (gdb) info registers            │
   │                                 (gdb) x/16gx $rsp               │
   └─────────────────────────────────────────────────────────────────┘

   When it triple-faults instead:
   $ qemu-system-x86_64 -d int,cpu_reset,guest_errors -no-reboot -no-shutdown
     ▸ prints every exception vector and a full CPU dump at the fault
```

---

## 16. Development Roadmap

Ten phases. Time estimates assume **serious evening/weekend work with AI
assistance**, per our earlier estimate of roughly 2.5× solo-unassisted speed.

```
 PHASE 0  ░░░░░░░░░░  FOUNDATION                              ~1 week
 ─────────────────────────────────────────────────────────────────────
   ▸ Repo, build.zig, linker script, Limine integration
   ▸ Boot to long mode, serial output over COM1
   ▸ Framebuffer console with a PSF bitmap font
   ▸ QEMU run + GDB debug scripts working
   ★ MILESTONE: "Orange OS booting" printed on a real screen

 PHASE 1  ██░░░░░░░░  CPU FOUNDATIONS                         ~1 week
 ─────────────────────────────────────────────────────────────────────
   ▸ GDT + TSS + IST stacks
   ▸ IDT, all 32 exception handlers with readable diagnostics
   ▸ Panic handler: register dump, stack backtrace, symbolized
   ★ MILESTONE: a null dereference prints a full diagnosis, not a reboot

 PHASE 2  ███░░░░░░░  MEMORY                                  ~2 weeks
 ─────────────────────────────────────────────────────────────────────
   ▸ Buddy physical allocator from the Limine memory map
   ▸ Our own page tables, HHDM, kernel remap
   ▸ Slab caches + kalloc/kfree
   ▸ Page fault handler with demand paging
   ★ MILESTONE: dynamic allocation works; a stress test survives

 PHASE 3  ████░░░░░░  INTERRUPTS & TIME                       ~1 week
 ─────────────────────────────────────────────────────────────────────
   ▸ ACPI parsing (MADT, FADT, MCFG, HPET)
   ▸ LAPIC + IOAPIC, IRQ routing, timer at 1000 Hz
   ▸ TSC calibration, monotonic clock, timer wheel
   ★ MILESTONE: a periodic heartbeat ticks reliably

 PHASE 4  █████░░░░░  PROCESSES                               ~4 weeks
 ─────────────────────────────────────────────────────────────────────
   ▸ Task/thread structures, context switch, MLFQ scheduler
   ▸ Address spaces, ELF loader, ring 3 transition
   ▸ syscall/sysret, the dispatch table, pointer validation
   ▸ fork with COW, exec, exit, wait
   ★ MILESTONE: a userspace program runs and returns from a syscall
   ⚠ THE HARDEST PHASE. Expect a week lost to one context-switch bug.

 PHASE 5  ██████░░░░  STORAGE & FILES                         ~4 weeks
 ─────────────────────────────────────────────────────────────────────
   ▸ PCI enumeration, AHCI/NVMe/virtio-blk drivers
   ▸ GPT partition parsing, block layer with a request queue
   ▸ VFS: mounts, inodes, dentries, fd tables, page cache
   ▸ CitrusFS: format, read, write, journal
   ▸ FAT32 for interop; tmpfs, devfs, procfs
   ★ MILESTONE: cat /etc/motd works from a real disk

 PHASE 6  ███████░░░  USERLAND & IPC                          ~4 weeks
 ─────────────────────────────────────────────────────────────────────
   ▸ Pulp libc: crt0, stdio, malloc, string, pthread
   ▸ Ports, channels, capabilities, shared memory
   ▸ Seed (PID 1) with dependency-ordered service startup
   ▸ Juice shell + the coreutils set
   ★ MILESTONE: an interactive shell over serial, running real programs

 PHASE 7  ████████░░  GRAPHICS                                ~8 weeks
 ─────────────────────────────────────────────────────────────────────
   ▸ PS/2 keyboard + mouse, evdev event queue
   ▸ Peel: compositor, scene graph, damage tracking, SIMD blitters
   ▸ Window management: move, resize, stack, focus, decorations
   ▸ Segment: canvas, rasterizer, TrueType text, widgets, layout, theme
   ▸ Grove: panel, dock, launcher, wallpaper
   ▸ Squeeze: terminal emulator
   ★ MILESTONE: ══ A DESKTOP. Drag a window. Type in a terminal. ══
   ★ This is the screenshot that makes the project real.

 PHASE 8  █████████░  MATURITY                             ~6+ months
 ─────────────────────────────────────────────────────────────────────
   ▸ SMP: AP bring-up, per-CPU data, real locking, load balancing
   ▸ Network stack: e1000, ARP, IP, UDP, TCP, sockets, DHCP
   ▸ USB: xHCI, hubs, HID, mass storage   ⚠ months on its own
   ▸ Audio: HDA driver, mixing daemon
   ▸ More apps: files, settings, editor, monitor
   ▸ Crate package manager
   ★ MILESTONE: a self-sufficient desktop OS

 PHASE 9  ██████████  HARDWARE REACH                         open-ended
 ─────────────────────────────────────────────────────────────────────
   ▸ Boot on real x86_64 hardware (Intel Mac, generic UEFI laptop)
   ▸ GPU acceleration: virtio-gpu, then real drivers
   ▸ aarch64 port behind the arch wall
   ▸ Apple Silicon  ⚠ depends on undocumented hardware. See §3.
   ★ MILESTONE: Orange OS boots from a USB stick on real metal
```

### 16.1 Honest cumulative timeline

| Reaching | Cumulative | What you have |
|----------|-----------|---------------|
| End of Phase 2 | **~1 month** | A kernel that manages memory |
| End of Phase 4 | **~2.5 months** | A real OS running userspace programs |
| End of Phase 6 | **~4.5 months** | A shell, files, and a working system |
| End of Phase 7 | **~6.5 months** | ══ **A DESKTOP OS** ══ |
| End of Phase 8 | **~12–18 months** | Something genuinely usable |
| Phase 9 | **open-ended** | Real hardware, and the honest unknowns |

### 16.2 Resource budget (the differentiator, tracked from Phase 0)

Run it with:

```sh
./scripts/budget.sh
```

That builds with `-Dbudget`, boots the result, collects the measurements the
kernel and `/bin/bench` emit on the serial line, and compares them against the
limits below. Measured on QEMU q35, 512 MiB, `-smp 4`, UEFI, root on NVMe.

| Metric | Limit | Measured | Class | Emitted by |
|--------|-------|----------|-------|------------|
| Kernel image (linked) | < 2 MB | **0.80 MB** | hard | `budget.reportImage` |
| — of which `.bss` | < 512 KB | **171 KB** | hard | `budget.reportImage` |
| Full desktop idle RSS | < 128 MB | **22.2 MB** | hard | `budget.reportMemory` |
| Boot to scheduler | < 2 s | 3.5–4.3 s † | timing | `budget.reportBoot` |
| Context switch | < 500 ns | **17–60 ns** | timing † | `budget.benchContextSwitch` |
| Syscall round-trip | < 200 ns | **136–157 ns** † | timing | `userland/bin/bench` |
| Idle CPU (desktop shown) | < 1 % | **0.00–0.02 %** | hard | `budget.benchIdleCpu` |

† Development runs QEMU's TCG interpreter emulating x86_64 on an arm64 Mac,
which is nothing like the hardware these limits describe. Size, memory, and
idle-CPU figures describe what the build consumes rather than how quickly the
host can emulate it, so they are **hard**: exceeding one fails `budget.sh` with
a non-zero exit. Latency and boot-time figures are reported and compared but do
not fail the script, because a check that is red every run is one everyone
learns to ignore. They become hard once there is a native-speed reference
machine to run them on.

> A change that regresses a hard limit is a **failed build**, not a
> discussion. This is the entire product thesis — it has to be defended
> mechanically, because it cannot be retrofitted.

**Where the numbers come from.** `kernel/debug/budget.zig` prints each
measurement as a rigid `[budget] key value` line; `tools/budget/check.py`
parses those and renders the table. A human-friendly format would have been
easier to write and impossible to diff. The syscall figure is taken from ring 3
by `userland/bin/bench` rather than from inside the kernel, because measuring
only the handler would omit the `syscall`/`sysret` transition, the `swapgs`
pair and the stack switch — which is most of what a syscall costs.

## 17. Coding Conventions

```
   NAMING
   ──────
   Types            PascalCase        Task, AddressSpace, PageTable
   Functions        camelCase         allocPage, mapRange, findVma
   Variables        snake_case        page_count, next_free, vma_root
   Constants        SCREAMING_SNAKE   PAGE_SIZE, KERNEL_BASE, MAX_FDS
   Files            snake_case.zig    page_table.zig, context_switch.S
   Modules          snake_case        mm, sched, vfs, ipc

   ERROR HANDLING
   ──────────────
   ✅  fn allocPage() !PhysAddr          errors are in the type
   ❌  fn allocPage() ?PhysAddr          "null" hides the reason
   ✅  const p = try allocPage();        propagate or handle
   ❌  const p = allocPage() catch unreachable;   ← never in kernel code

   SAFETY
   ──────
   ▸ No user pointer is dereferenced outside copy_from_user/copy_to_user
   ▸ Every public function documents its locking requirements
   ▸ Every unsafe cast carries a comment explaining why it is sound
   ▸ Assertions are compiled IN for debug builds, out for release

   COMMENTS
   ────────
   Explain WHY, never WHAT. The code already says what.

   ✅  // Red zone must be off: an interrupt arriving here would
       // clobber the 128 bytes below rsp that the ABI says are ours.

   ❌  // increment the counter
       counter += 1;

   ORGANIZATION
   ────────────
   ▸ One subsystem per directory, with a <name>.zig public entry point
   ▸ Nothing outside kernel/arch/ references CPU-specific concepts
   ▸ Files stay under ~600 lines; split by concern when they grow
   ▸ Cyclic imports between subsystems are a design error, not a nuisance

   COMMITS
   ───────
   subsystem: short imperative summary

   mm: fix buddy coalescing across zone boundaries
   sched: add anti-starvation boost every 1000ms
   peel: track damage per-surface instead of per-frame
```

---

## 18. Glossary

| Term | Meaning |
|------|---------|
| **ABI** | Application Binary Interface — the binary-level contract between components |
| **ACPI** | Firmware tables describing hardware topology and power management |
| **APIC** | Advanced Programmable Interrupt Controller — modern IRQ routing |
| **Buddy allocator** | Physical allocator that splits and merges power-of-two blocks |
| **Capability** | An unforgeable handle granting a specific right to a specific object |
| **COW** | Copy-on-write — share pages until someone writes, then duplicate |
| **CR3** | The x86 register holding the physical address of the page table root |
| **Damage tracking** | Recompositing only the screen regions that actually changed |
| **Dentry** | Cached directory entry — the name→inode mapping |
| **Extent** | A contiguous run of blocks, stored as (start, length) |
| **GDT** | Global Descriptor Table — x86 segment definitions |
| **HHDM** | Higher-Half Direct Map — all physical RAM linearly mapped in kernel space |
| **Higher-half** | Kernel lives in the upper half of the virtual address space |
| **IDT** | Interrupt Descriptor Table — vector → handler mapping |
| **Inode** | The filesystem's record of a file's metadata and data location |
| **IST** | Interrupt Stack Table — guaranteed-good stacks for critical faults |
| **Journaling** | Writing intended changes to a log first, so crashes never corrupt |
| **Long mode** | x86_64's native 64-bit operating mode |
| **MLFQ** | Multi-Level Feedback Queue — the scheduling algorithm |
| **MSR** | Model-Specific Register — CPU config registers |
| **PML4** | Page Map Level 4 — the top level of x86_64 page tables |
| **Red zone** | 128 bytes below rsp the ABI reserves; must be disabled in kernels |
| **Ring 0 / Ring 3** | Kernel privilege / user privilege |
| **Slab** | Object cache for same-sized allocations |
| **TLB** | Translation Lookaside Buffer — the CPU's page-table cache |
| **Triple fault** | A fault while handling a fault while handling a fault → CPU reset |
| **TSS** | Task State Segment — holds the ring-0 stack pointer |
| **VFS** | Virtual File System — the abstraction over concrete filesystems |
| **VMA** | Virtual Memory Area — one mapped region in a process |

---

<div align="center">

## 🍊

**Orange OS**

*Phase 0 begins with one line printed over a serial port.*

**`Orange OS v0.1.0 — Zest kernel booting...`**

---

Written from scratch. Every layer. On purpose.

</div>

---

<div align="center">

### Official Vishwateja

**Developed by Vishwateja S B**
*Software Developer and AI Data Analyst*

Copyright © 2026 Official Vishwateja
Dual-licensed: MIT OR Apache-2.0

</div>
