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
    const qemu_base = [_][]const u8{
        "qemu-system-x86_64",
        "-M",         "q35",
        "-m",         "512M",
        "-cdrom",     "build/orange.iso",
        "-boot",      "d",
        "-serial",    "stdio",
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
}
