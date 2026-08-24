//! Orange OS — root build script.
//!
//!   zig build            → build/orange.iso
//!   zig build run        → boot in QEMU
//!   zig build debug      → boot halted, GDB stub on :1234
//!   zig build trace      → boot with interrupt/fault tracing

const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .Debug });

    // ── Bare-metal target ────────────────────────────────────────────────────
    // The kernel must not touch FPU/SIMD registers: we don't save them on
    // interrupt entry, so the compiler must never emit them implicitly.
    const Feature = std.Target.x86.Feature;
    var disabled = std.Target.Cpu.Feature.Set.empty;
    var enabled = std.Target.Cpu.Feature.Set.empty;
    disabled.addFeature(@intFromEnum(Feature.mmx));
    disabled.addFeature(@intFromEnum(Feature.sse));
    disabled.addFeature(@intFromEnum(Feature.sse2));
    disabled.addFeature(@intFromEnum(Feature.avx));
    disabled.addFeature(@intFromEnum(Feature.avx2));
    enabled.addFeature(@intFromEnum(Feature.soft_float));

    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .freestanding,
        .abi = .none,
        .cpu_features_sub = disabled,
        .cpu_features_add = enabled,
    });

    // ── Build options ────────────────────────────────────────────────────────
    const fault_test = b.option(
        bool,
        "fault-test",
        "After boot, dereference null from nested calls to exercise the fault path",
    ) orelse false;

    const mm_test = b.option(
        bool,
        "mm-test",
        "Run memory subsystem stress tests at boot",
    ) orelse false;

    const tick_hz = b.option(
        u32,
        "tick-hz",
        "Scheduler tick frequency (default 1000). QEMU's TCG emulation cannot " ++
            "service 1000 Hz on a non-x86 host and will drop ticks; timekeeping " ++
            "is TSC-based so only scheduling granularity is affected.",
    ) orelse 1000;

    const options = b.addOptions();
    options.addOption(u32, "tick_hz", tick_hz);
    options.addOption(bool, "fault_test", fault_test);
    options.addOption(bool, "mm_test", mm_test);

    const blk_test = b.option(bool, "blk-test", "Run block device tests at boot") orelse false;
    options.addOption(bool, "blk_test", blk_test);

    const fs_test = b.option(bool, "fs-test", "Run filesystem tests at boot") orelse false;
    options.addOption(bool, "fs_test", fs_test);

    const sched_test_opt = b.option(
        bool,
        "sched-test",
        "Run scheduler tests at boot. Off by default: the test threads spin " ++
            "at interactive priority and starve real work.",
    ) orelse false;
    options.addOption(bool, "sched_test", sched_test_opt);

    const verbose_exec = b.option(bool, "verbose-exec", "Log every process load") orelse false;
    options.addOption(bool, "verbose_exec", verbose_exec);

    const no_ps2 = b.option(
        bool,
        "no-ps2",
        "Skip the PS/2 driver, so input can only arrive over USB. Used to " ++
            "prove HID reports are actually being delivered.",
    ) orelse false;
    options.addOption(bool, "no_ps2", no_ps2);

    const late_fault = b.option(
        bool,
        "late-fault",
        "Fault deliberately once the desktop is up, to check that a panic " ++
            "takes the screen back and shows the log",
    ) orelse false;
    options.addOption(bool, "late_fault", late_fault);

    const budget = b.option(bool, "budget", "Measure and report the ARCHITECTURE.md 16.2 resource budget") orelse false;
    options.addOption(bool, "budget", budget);

    // ── Userland ─────────────────────────────────────────────────────────────
    // Every program links against Pulp and nothing else: no libc, no runtime,
    // static ELF, same bare-metal target as the kernel.
    const pulp_mod = b.createModule(.{
        .root_source_file = b.path("userland/libs/pulp/pulp.zig"),
        .target = target,
        .optimize = optimize,
        .red_zone = false,
        .pic = false,
        .stack_protector = false,
        .stack_check = false,
        .sanitize_c = false,
        .single_threaded = true,
    });

    const libpeel_mod = b.createModule(.{
        .root_source_file = b.path("userland/libs/libpeel/libpeel.zig"),
        .target = target,
        .optimize = optimize,
        .red_zone = false,
        .pic = false,
        .stack_protector = false,
        .stack_check = false,
        .sanitize_c = false,
        .single_threaded = true,
    });
    libpeel_mod.addImport("pulp", pulp_mod);

    const segment_mod = b.createModule(.{
        .root_source_file = b.path("userland/libs/segment/segment.zig"),
        .target = target,
        .optimize = optimize,
        .red_zone = false,
        .pic = false,
        .stack_protector = false,
        .stack_check = false,
        .sanitize_c = false,
        .single_threaded = true,
    });
    segment_mod.addImport("pulp", pulp_mod);
    segment_mod.addImport("libpeel", libpeel_mod);

    const UserProgram = struct { name: []const u8, path: []const u8 };
    const programs = [_]UserProgram{
        .{ .name = "init", .path = "userland/servers/seed/main.zig" },
        .{ .name = "juice", .path = "userland/bin/juice/main.zig" },
        .{ .name = "echo", .path = "userland/bin/echo/main.zig" },
        .{ .name = "uname", .path = "userland/bin/uname/main.zig" },
        .{ .name = "greetd", .path = "userland/bin/greetd/main.zig" },
        .{ .name = "greet", .path = "userland/bin/greet/main.zig" },
        .{ .name = "peel", .path = "userland/servers/peel/main.zig" },
        .{ .name = "clock", .path = "userland/bin/clock/main.zig" },
        .{ .name = "squeeze", .path = "userland/apps/squeeze/main.zig" },
        .{ .name = "grove", .path = "userland/apps/grove/main.zig" },
        .{ .name = "about", .path = "userland/apps/about/main.zig" },
        .{ .name = "ping", .path = "userland/bin/ping/main.zig" },
        .{ .name = "net", .path = "userland/bin/net/main.zig" },
        .{ .name = "fetch", .path = "userland/bin/fetch/main.zig" },
        .{ .name = "bench", .path = "userland/bin/bench/main.zig" },
    };

    for (programs) |prog| {
        const mod = b.createModule(.{
            .root_source_file = b.path(prog.path),
            .target = target,
            .optimize = optimize,
            .red_zone = false,
            .pic = false,
            .stack_protector = false,
            .stack_check = false,
            .sanitize_c = false,
            .single_threaded = true,
        });
        mod.addImport("pulp", pulp_mod);
        mod.addImport("libpeel", libpeel_mod);
        mod.addImport("segment", segment_mod);

        const exe = b.addExecutable(.{
            .name = prog.name,
            .root_module = mod,
            .use_lld = true,
        });
        exe.setLinkerScript(b.path("userland/user.ld"));
        exe.entry = .{ .symbol_name = "_start" };
        b.installArtifact(exe);
    }

    // ── Zest kernel ──────────────────────────────────────────────────────────
    const kernel_mod = b.createModule(.{
        .root_source_file = b.path("kernel/main.zig"),
        .target = target,
        .optimize = optimize,
        .code_model = .kernel, // required for the higher-half address
        .red_zone = false, // interrupts would clobber it
        .omit_frame_pointer = false, // frame pointers make panics traceable
        .pic = false, // fixed load address
        .stack_protector = false, // no __stack_chk_fail at ring 0
        .stack_check = false,
        .sanitize_c = false, // UBSan runtime uses f128/SSE we cannot link
        .strip = false,
        .single_threaded = true, // SMP arrives in Phase 8
    });

    kernel_mod.addOptions("build_options", options);
    // Userland is NOT embedded in the kernel. scripts/mkdisk.sh copies the
    // installed binaries onto the CitrusFS image, and they are loaded from
    // disk at runtime.

    const kernel = b.addExecutable(.{
        .name = "kernel.elf",
        .root_module = kernel_mod,
        // Zig 0.16's self-hosted ELF linker ignores linker scripts; LLD honors
        // them. Without this the kernel lands at 0x1000000 instead of the
        // higher-half address -mcmodel=kernel assumes.
        .use_lld = true,
    });
    kernel.setLinkerScript(b.path("boot/linker-x86_64.ld"));
    kernel.entry = .{ .symbol_name = "kmain" };
    // Keep the Limine request markers even at high optimization levels.
    kernel.link_gc_sections = false;

    const install_kernel = b.addInstallArtifact(kernel, .{});

    // ── ISO assembly ─────────────────────────────────────────────────────────
    // Depends on the kernel artifact directly, not on the install step, so the
    // install step can depend on the ISO without forming a cycle.
    const iso = b.addSystemCommand(&.{ "sh", "scripts/mkiso.sh" });
    iso.step.dependOn(&install_kernel.step);
    const iso_step = b.step("iso", "Assemble the bootable ISO");
    iso_step.dependOn(&iso.step);
    b.getInstallStep().dependOn(&iso.step);

    // ── Run targets ──────────────────────────────────────────────────────────
    // A SATA disk is attached on every run target. scripts/mkdisk.sh creates
    // it; AHCI simply reports no disks if the file is missing.
    const qemu_base = [_][]const u8{
        "qemu-system-x86_64",
        "-M",     "q35",
        "-m",     "512M",
        "-cdrom", "build/orange.iso",
        "-boot",  "d",
        "-drive", "id=disk0,file=build/disk.img,format=raw,if=none",
        "-device", "ahci,id=ahci",
        "-device", "ide-hd,drive=disk0,bus=ahci.0",
        "-netdev", "user,id=n0",
        "-device", "e1000,netdev=n0",
        "-serial", "stdio",
        "-no-reboot", "-no-shutdown",
    };

    const run = b.addSystemCommand(&qemu_base);
    run.step.dependOn(iso_step);
    b.step("run", "Boot Orange OS in QEMU").dependOn(&run.step);

    const debug = b.addSystemCommand(&(qemu_base ++ [_][]const u8{ "-s", "-S" }));
    debug.step.dependOn(iso_step);
    b.step("debug", "Boot halted with a GDB stub on :1234").dependOn(&debug.step);

    const trace = b.addSystemCommand(&(qemu_base ++ [_][]const u8{
        "-d", "int,cpu_reset,guest_errors",
    }));
    trace.step.dependOn(iso_step);
    b.step("trace", "Boot with interrupt and fault tracing").dependOn(&trace.step);

    // Boot the single USB image under UEFI firmware, which is how a real
    // machine starts. Worth keeping as a build target rather than a one-off
    // command: it exercises a different firmware path, a far more fragmented
    // memory map, and ACPI's XSDT instead of the RSDT.
    const uefi = b.addSystemCommand(&.{ "sh", "scripts/run-uefi.sh" });
    b.step("uefi", "Boot the USB image under UEFI firmware").dependOn(&uefi.step);
}
