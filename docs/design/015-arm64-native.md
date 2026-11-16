# 015: Orange OS on Arm64, at native speed on Apple Silicon

Status: stage A0 done (16 Nov 2026). A1 onward not started.

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
the virtual GPU), from `tools/arm_boot_smoke.py`:

| | Emulated (TCG) | Native (Apple Hypervisor) |
|---|---|---|
| Speed test | 303 ms | 38 ms (8 times faster) |
| Full frames drawn and shown | 822 a second | 3,884 a second |
| Timer interrupts on time | 132 of 200 | 200 of 200 |

The x86 system is slower still than the emulated column, because x86 on
Arm is a harder translation than Arm on Arm. The timer row matters for
sound: late interrupts are the gaps you hear.

## 4. What stage A0 is

`zig build arm` builds `zig-out/bin/kernel-arm64.elf`;
`scripts/run-arm.sh` boots it (native on an Arm host, emulated elsewhere).

| File | What it does |
|---|---|
| `boot/linker-aarch64.ld` | Loaded at physical 0x40200000, linked in the upper half |
| `kernel/arch/aarch64/boot.S` | Entry for every processor: leaves EL2 if started there, turns the memory map on, sets the stack |
| `vectors.S`, `exceptions.zig` | The 16 exception slots, register save and restore, a readable crash report |
| `fdt.zig` | Device tree reader (4 unit tests): memory, processors, device addresses |
| `uart.zig` | PL011 serial log, one whole line at a time |
| `gic.zig` | GICv3 interrupt controller |
| `timer.zig` | 1000 Hz tick on every processor, counted from deadlines so time stays right when interrupts are late |
| `cpu.zig` | System registers, the counter, PSCI calls to start processors and power off |
| `virtio_gpu.zig`, `display.zig` | virtio-gpu 2D over the memory-mapped transport; the boot picture |
| `start.zig` | Runs the checks and prints one line for each |

Shared with the x86 kernel already: `kernel/lib/fmt.zig` and
`kernel/drivers/video/font.zig`. Everything else of the x86 kernel is not
yet in the Arm build.

`tools/arm_boot_smoke.py` boots five machine shapes (emulated with 4 and 1
processors, emulated started at EL2, native with 4 and 8 processors) and
checks the kernel's report and a screenshot of each.

Found on the way, worth remembering:
- QEMU only places the device tree at the start of memory if the kernel
  leaves a full megabyte free there.
- `for (big_array) |x|` copies the array to the stack. With 4 MB of pixels
  that ran the stack below the start of memory. Under the hypervisor this
  kills QEMU with `Assertion failed: (isv)`, which looks like a display
  bug and is not. Stage A1 adds a guard page under every kernel stack.
- The kernel is built without floating point and SIMD registers, like the
  x86 kernel.

Limits of A0, stated plainly: it runs no programs. There is no memory
allocator, no scheduler, no file system, no disk, no keyboard. Physical
memory is mapped with one fixed table of 1 GB blocks, writable and
executable. Only GICv3 and QEMU's "virt" machine are supported.

## 5. The stages to a smooth YouTube

Each stage ends with a test that passes natively and emulated. Sizes are
honest guesses in working sessions, not promises.

| Stage | What | Proven by | Size |
|---|---|---|---|
| A0 | Boot, device tree, exceptions, interrupts, timer, all processors, virtual GPU | `arm_boot_smoke.py` | done |
| A1 | One kernel, two processors: an `arch` interface (interrupt on/off, per-processor data, context switch, page tables, system call entry, user copy) that the shared code uses instead of importing `arch/x86_64` directly (29 files do today). Arm page tables with proper permissions and stack guard pages. | The x86 tests still pass; the kernel's own memory, scheduler and file system tests pass on Arm | large |
| A2 | Programs: user mode (EL0), system calls by `svc`, signals, FPU/SIMD state per task, ELF loading. musl for Arm64 through `userland/libs/musl-orange` (six assembly files to redo). | The runtime suite on Arm | large |
| A3 | Devices: PCI (ECAM from the device tree), then virtio-blk, virtio-net, virtio-input (keyboard, tablet), virtio-sound, virtio-gpu with interrupts. The existing NVMe, AHCI, e1000, xHCI and HDA drivers work over PCI once A1 is done. | Disk, network and input tests on Arm | medium |
| A4 | The desktop: Peel and every app are Zig with no x86 code, so this is a rebuild for the Arm target plus the display path. | `desktop_smoke.py` and the rest on Arm | small |
| A5 | The browser: rebuild the 27 libraries and WPE WebKit for `aarch64-linux-musl` with the same scripts (`tools/wpe/build_deps.py`, a second cross file). JavaScriptCore's Arm64 JIT is its best supported one, and its separated write/execute heap (our patch 0008) was written for Arm64 first. Many hours of compiling, about 18 GB of build tree. | `browser_smoke.py` on Arm | large, mostly machine time |
| A6 | YouTube again, natively: `tools/youtube_check.py` on Arm. Target: 720p at the film's own frame rate, film time equal to real time, no gaps in the sound. Raise the default video limit when measured. | The numbers in a table here | small |
| A7 | Run it like an app: the Mac preview (`scripts/run-desktop.sh` and the companion) starts the Arm system; UEFI boot so UTM, VMware Fusion and Parallels can start it too. | The owner uses it | medium |

The x86 system stays the one for Intel and AMD computers, where it already
runs at full speed under VirtualBox, VMware, KVM and Hyper-V. From A1 on
both are built from the same source.

## 6. What not to do

- Do not spend more time tuning the x86 browser for this Mac. Section 10
  of 014 is the ceiling.
- Do not build on ramfb or the Bochs display for the hypervisor: QEMU's
  issue tracker reports them slow or failing there (issue 1635 above).
  This was not re-tested here; the one failure seen with ramfb in this
  work turned out to be the stack overflow in section 4. virtio-gpu is the
  device every other system uses, and it is measured above.
- Do not add a 3D path (virgl, Venus) before A6 is measured. Video on a
  web page is drawn by the processor in our WebKit build; the 2D path at
  3,884 full frames a second is not the limit.
