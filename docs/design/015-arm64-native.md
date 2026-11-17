# 015: Orange OS on Arm64, at native speed on Apple Silicon

Status: stages A0, A1 and A2 done (17 Nov 2026). A3 onward not started.

## 1. Why

On the owner's Mac (Apple Silicon), YouTube in Orange Browser plays at
about 5 frames a second with gaps in the sound (docs/design/014, section
10). Windows 11 in Parallels on the same Mac plays 4K smoothly. The
question was what Parallels does that we do not.

## 2. What the others do (researched 16 Nov 2026)

1. **They do not emulate the processor.** Parallels on Apple Silicon runs
   the Arm build of Windows. Apple's Hypervisor framework lets the guest's
   Arm instructions run directly on the Mac's processor. A hypervisor can
   only do this when the guest and the host are the same kind of processor.
2. **Orange OS is an x86 system.** On an Apple Silicon Mac no hypervisor
   can run it directly, so QEMU translates every x86 instruction in
   software (TCG). That is 5 to 20 times slower, and worst for exactly the
   work a browser does (video decoding, JavaScript compiled at run time).
   Parallels has the same limit: it cannot run x86 Windows fast on these
   Macs either. VirtualBox was fast for the owner on Intel hardware for the
   same reason, in reverse.
3. **They do not pretend to be a real video card.** The guest keeps the
   picture in ordinary memory and sends the host short messages (virtio-gpu
   in QEMU, Parallels' and VMware's own devices). The host draws with Metal.
   Drawing causes no traps to the host.
4. **Same for disk, network and sound:** paravirtual devices (virtio)
   instead of emulated hardware.

So no setting inside the x86 guest can fix this. The fix is the one
Parallels uses: an Arm64 build of Orange OS, run by Apple's Hypervisor
(`qemu-system-aarch64 -M virt -accel hvf`), with virtio devices.

Sources:
- https://www.parallels.com/blogs/windows-11-arm-apple-m-series
- https://www.thurrott.com/cloud/340680/parallels-desktop-27-is-launching-today-with-opengl-4-3-and-ai-acceleration-support
- https://ww2.coastal.edu/mmurphy2/oer/qemu/accel/
- https://qemu.readthedocs.io/en/v8.1.5/system/arm/virt.html
- https://www.collabora.com/news-and-blog/blog/2025/01/15/the-state-of-gfx-virtualization-using-virglrenderer/
- https://gitlab.com/qemu-project/qemu/-/issues/1635
- https://gitlab.com/qemu-project/qemu/-/issues/2196

## 3. Proof on this Mac (measured, not assumed)

The Arm kernel's own speed test (primes below two million, twenty times)
and its screen test (draw the whole 1280x800 picture and show it through
the virtual GPU), measured with the stage A0 kernel:

| | Emulated (TCG) | Native (Apple Hypervisor) |
|---|---|---|
| Speed test | 303 ms | 38 ms (8 times faster) |
| Full frames drawn and shown | 822 a second | 3,884 a second |
| Timer interrupts on time | 132 of 200 | 200 of 200 |

The x86 system is slower still than the emulated column, because x86 on
Arm is a harder translation than Arm on Arm. The timer row matters for
sound: late interrupts are the gaps you hear.

## 4. What exists now (A0 to A2)

```sh
zig build arm               # the kernel and 36 programs for Arm64
scripts/mkdisk-arm.sh       # build/arm64-disk.img
scripts/run-arm.sh          # native on an Arm host, emulated elsewhere
python3 tools/arm_smoke.py  # everything below, natively and emulated
```

It boots to the shell on the serial console: init (PID 1) starts Juice,
and typed commands run programs from the disk. There is no desktop yet.

### A0: the machine

| File (kernel/arch/aarch64/) | What it does |
|---|---|
| `boot.S` | Entry for every processor: leaves EL2 if started there, maps memory the way Limine does on a PC (the direct map at 0xFFFF800000000000, the kernel at 0xFFFFFFFF80000000), sets the stack |
| `vectors.S`, `isr.zig` | The 16 exception slots; interrupts, system calls (`svc`, number in x8, arguments in x0-x5) and faults; a readable crash report |
| `fdt.zig`, `bootinfo.zig` | Device tree reader (4 unit tests), turned into the same memory map and answers the x86 kernel gets from Limine |
| `gic.zig`, `apic.zig` | GICv3: private, shared and between-processor interrupts; the 1000 Hz generic timer, counted from deadlines |
| `smp.zig`, `cpu.zig` | Starting the other processors (PSCI), interrupting them (TLB shootdowns, panic halt) |
| `uart.zig`, `serial.zig`, `rtc.zig` | PL011 console with receive interrupts; PL031 clock |
| `virtio_gpu.zig`, `display.zig` | virtio-gpu 2D; the boot picture |

### A1: one kernel, two processors

`kernel/arch/arch.zig` is the wall between the shared kernel and the
processor. Shared code imports it and never a processor directory; each
name in it (`io`, `percpu`, `context`, `fpu`, `mmu`, `pte`, `smp`, `isr`,
`tsc`, `boot`, `serial`, ...) is the x86 or the Arm module of that name.
29 files used to import `arch/x86_64` directly; none do now. On x86 every
name is the module it always was, so the x86 kernel is unchanged in
behaviour.

The memory manager, scheduler, system calls, file systems, IPC and
signals are the same source on both. Their few x86 assumptions became
functions: page table bits (`pte.zig`, with a round-trip test), loading a
page table and flushing translations (`mmu.zig`), where a direct map
starts (memory on Arm sits above the devices), the saved registers of a
system call (`frame.arg(n)`, `frame.setResult`), the signal frame
(`aarch64/signal_frame.zig`, Linux's Arm64 layout), random-number and
cycle-counter instructions (`entropy.zig`).

Proven: the kernel's own tests pass on both (23 memory, 5 scheduler, and
the 14 cross-processor TLB, residency and current-task tests of
`-Druntime-test`), and the full x86 suite (`runtime_smoke.py`, desktop,
Files, browser) still passes.

### A2: programs

- User level (EL0) with each thread's own stack, thread pointer
  (TPIDR_EL0, read back on every switch because programs may change it)
  and all 32 vector registers plus FPCR/FPSR, switched eagerly.
- Programs start as on Linux Arm64: the stack pointer on argc, 16-byte
  aligned (x86 has a zero return slot below argc).
- Faults become the same exit statuses and signals as on x86, so tests
  and programs need no processor knowledge.
- Instruction caches are synchronised when a program starts, when a page
  is brought in, and when memory is made executable: Arm does not keep
  them coherent by itself.
- Each processor's number is in TPIDRRO_EL0, which programs may read,
  as x86 programs use CPUID.
- `userland/libs/pulp` makes system calls with `svc`; 24 Zig programs
  are built for Arm (init, the shell, the probes).
- musl for Arm64: musl's own aarch64 sources, except the five assembly
  files that make system calls, which `musl-orange` replaces. Arm's Linux
  call numbers are generated from musl's header (`SysArm`); structure
  layouts that differ (`stat`, `epoll_event`, `O_DIRECTORY`) are handled.
  12 C programs are built.
- The disk is the same GPT and CitrusFS image as on x86, loaded into
  memory by the virtual machine (`ramdisk=` on the command line).

Proven by `tools/arm_smoke.py`: all 29 program checks pass (faults,
threads across 4 processors, vector register isolation, futexes, 300
child reaps, descriptors, IPC, musl, files, 511 threads, pipes, epoll,
socket pairs with descriptor passing, posix_spawn, lazy memory, shared
memory, randomness, POSIX signals), natively and emulated.

Measured on this Mac (M4, 4 processors), `tools/arm_smoke.py` and `bench`:

| | Emulated (TCG) | Native (Apple Hypervisor) |
|---|---|---|
| A system call from a program (`bench`, 1,000,000 calls) | 1,084 ns | 61 ns (18 times faster) |
| All kernel tests and program checks | 12 s | 6 s |

The second row is mostly waiting by design (sleeps, timeouts, 1 ms
ticks), so it understates the difference; the first row and the A0 speed
test (8 times) are the honest measure of work.

Two kernel bugs only native speed showed, both fixed and then checked
with 40 native runs in a row (20 at 4 processors, 10 at 8, 10 more
before), all passing:
- The page-fault path kept interrupts masked while it waited for the
  memory lock. Another processor holding that lock while waiting for this
  one to acknowledge a TLB shootdown then waited forever ("TLB shootdown
  timeout", 3 runs in 10). x86 already turns interrupts on there; Arm
  now does the same.
- Sending an interrupt to another processor (a GIC system register write)
  is not ordered after earlier memory writes on Arm. A `dsb ishst` now
  comes first, as in Linux, so the target always sees the request the
  interrupt is about.

One kernel test was made stronger rather than looser: the current-task
test needs threads to move between processors to prove anything, and at
native speed they hardly ever did (0 to 77 moves in 1,600). Its workers
now keep the processors busy for 1 ms before sleeping; it sees about
1,000 moves a run, on x86 as well.

### Found on the way

- QEMU only places the device tree at the start of memory if the kernel
  leaves a full megabyte free there.
- `for (big_array) |x|` copies the array to the stack. Under the
  hypervisor a stack that runs off into non-memory kills QEMU with
  `Assertion failed: (isv)`, which looks like a display bug and is not.
- The linker puts the compiler's address table (`.got`) after the image
  unless told; the kernel's own page tables then did not map it.
- Three test programs carried x86 machine code as bytes (`ret`, `mov eax,
  42`) and one assumed integer division by zero traps (Arm returns 0).
- A C program's message control buffer is a `char` array: on Arm it was
  not 4-byte aligned, and musl-orange read it as aligned integers.
- Not Arm-specific: the open-file limit raised to 1024 for the browser
  (014, section 10) had not been carried into two probes and the runtime
  test; they now expect 1024.

### Limits, stated plainly

- No desktop: no keyboard or mouse device, no display beyond the boot
  picture (A3, A4). The console is the serial line.
- The disk is a copy in memory: writes are lost at power off (A3 brings
  virtio-blk). No network yet.
- Not yet on Arm: C++ programs (libc++), the JIT probes (they generate x86
  code), the browser (A5).
- Kernel thread stacks have no guard pages, on either processor.
- Only QEMU's `virt` machine with GICv3.

## 5. The stages to a smooth YouTube

Each stage ends with a test that passes natively and emulated. Sizes are
honest guesses in working sessions, not promises.

| Stage | What | Proven by | Size |
|---|---|---|---|
| A0 | Boot, device tree, exceptions, interrupts, timer, all processors, virtual GPU | `arm_smoke.py` | done |
| A1 | One kernel, two processors: an `arch` interface (interrupt on/off, per-processor data, context switch, page tables, system call entry, user copy) that the shared code uses instead of importing `arch/x86_64` directly (29 files did). Arm page tables with proper permissions. | The x86 tests still pass; the kernel's own memory, scheduler and file system tests pass on Arm | done 17 Nov 2026 |
| A2 | Programs: user mode (EL0), system calls by `svc`, signals, FPU/SIMD state per task, ELF loading. musl for Arm64 through `userland/libs/musl-orange` (five assembly files redone). | The runtime suite on Arm | done 17 Nov 2026 |
| A3 | Devices: PCI (ECAM from the device tree), then virtio-blk, virtio-net, virtio-input (keyboard, tablet), virtio-sound, virtio-gpu with interrupts. The existing NVMe, AHCI, e1000, xHCI and HDA drivers work over PCI once A1 is done. | Disk, network and input tests on Arm | medium |
| A4 | The desktop: Peel and every app are Zig with no x86 code, so this is a rebuild for the Arm target plus the display path. | `desktop_smoke.py` and the rest on Arm | small |
| A5 | The browser: rebuild the 27 libraries and WPE WebKit for `aarch64-linux-musl` with the same scripts (`tools/wpe/build_deps.py`, a second cross file). JavaScriptCore's Arm64 JIT is its best supported one, and its separated write/execute heap (our patch 0008) was written for Arm64 first. Many hours of compiling, about 18 GB of build tree. | `browser_smoke.py` on Arm | large, mostly machine time |
| A6 | YouTube again, natively: `tools/youtube_check.py` on Arm. Target: 720p at the film's own frame rate, film time equal to real time, no gaps in the sound. Raise the default video limit when measured. | The numbers in a table here | small |
| A7 | Run it like an app: the Mac preview (`scripts/run-desktop.sh` and the companion) starts the Arm system; UEFI boot so UTM, VMware Fusion and Parallels can start it too. | The owner uses it | medium |

The x86 system stays the one for Intel and AMD computers, where it already
runs at full speed under VirtualBox, VMware, KVM and Hyper-V. Since A1
both are built from the same source.

## 6. What not to do

- Do not spend more time tuning the x86 browser for this Mac. Section 10
  of 014 is the ceiling.
- Do not build on ramfb or the Bochs display for the hypervisor: QEMU's
  issue tracker reports them slow or failing there (issue 1635 above).
  This was not re-tested here; the one failure seen with ramfb in this
  work turned out to be a stack overflow (section 4). virtio-gpu is the
  device every other system uses, and it is measured above.
- Do not add a 3D path (virgl, Venus) before A6 is measured. Video on a
  web page is drawn by the processor in our WebKit build; the 2D path at
  3,884 full frames a second is not the limit.
