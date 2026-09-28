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
    // User code may use baseline x86-64 SSE2 now that every task owns eager
    // FPU state. Never reuse this target for kernel/interrupt code. AVX stays
    // unavailable until a larger XSAVE context and its policy are implemented.
    const user_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .freestanding,
        .abi = .none,
        .cpu_model = .baseline,
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
    const ui_options = b.addOptions();
    const runtime_test = b.option(bool, "runtime-test", "Run userspace runtime probes before desktop startup") orelse false;
    const orphan_waves = b.option(u32, "runtime-orphan-waves", "Orphan cleanup stress waves (12 parents per wave)") orelse 8;
    if (orphan_waves == 0 or orphan_waves > 1024) @panic("runtime-orphan-waves must be 1..1024");
    ui_options.addOption(u32, "runtime_orphan_waves", orphan_waves);
    ui_options.addOption(bool, "runtime_test", runtime_test);
    options.addOption(bool, "runtime_test", runtime_test);
    // WPE WebKit trial (docs/design/012): probes linked against libraries
    // cross-built by tools/wpe/build_deps.py. Off by default, since a plain
    // checkout has no build/wpe/sysroot.
    const wpe_probes = b.option(bool, "wpe-probes", "Build WPE trial probes against build/wpe/sysroot (run tools/wpe/build_deps.py first)") orelse false;
    ui_options.addOption(bool, "wpe_probes", wpe_probes);
    ui_options.addOption(bool, "wpe_first", b.option(bool, "wpe-first", "Run the WPE trial probes before the other runtime probes (for iterating on them)") orelse false);
    ui_options.addOption(bool, "desktop_profile", b.option(bool, "desktop-profile", "Emit compositor frame timing for QEMU profiling") orelse false);
    const timezone = b.option(i32, "timezone-minutes", "Local offset from UTC in minutes (default India +330)") orelse 330;
    if (timezone < -720 or timezone > 840) @panic("timezone-minutes must be -720..840");
    ui_options.addOption(i32, "timezone_minutes", timezone);
    const calendar_mod = b.createModule(.{ .root_source_file = b.path("userland/libs/pulp/calendar.zig"), .target = target, .optimize = optimize });
    const user_calendar_mod = b.createModule(.{ .root_source_file = b.path("userland/libs/pulp/calendar.zig"), .target = user_target, .optimize = optimize });
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
    // static ELF, baseline SSE2 app target distinct from the soft-float kernel.
    // Software composition needs optimization even while the kernel is being
    // debugged. ReleaseSafe retains bounds/overflow checks. Override with
    // -Duser-optimize=Debug when stepping through userland instructions.
    const user_optimize = b.option(std.builtin.OptimizeMode, "user-optimize", "Userland optimization mode") orelse
        (if (optimize == .Debug) .ReleaseSafe else optimize);
    const typography_mod = b.createModule(.{
        .root_source_file = b.path("userland/libs/typography/typography.zig"),
        .target = user_target,
        .optimize = user_optimize,
    });
    const pulp_mod = b.createModule(.{
        .root_source_file = b.path("userland/libs/pulp/pulp.zig"),
        .target = user_target,
        .optimize = user_optimize,
        .red_zone = false,
        .pic = false,
        .stack_protector = false,
        .stack_check = false,
        .sanitize_c = false,
        .single_threaded = false,
    });

    const libpeel_mod = b.createModule(.{
        .root_source_file = b.path("userland/libs/libpeel/libpeel.zig"),
        .target = user_target,
        .optimize = user_optimize,
        .red_zone = false,
        .pic = false,
        .stack_protector = false,
        .stack_check = false,
        .sanitize_c = false,
        .single_threaded = false,
    });
    libpeel_mod.addImport("pulp", pulp_mod);
    pulp_mod.addOptions("ui_options", ui_options);
    pulp_mod.addImport("calendar", user_calendar_mod);

    const segment_mod = b.createModule(.{
        .root_source_file = b.path("userland/libs/segment/segment.zig"),
        .target = user_target,
        .optimize = user_optimize,
        .red_zone = false,
        .pic = false,
        .stack_protector = false,
        .stack_check = false,
        .sanitize_c = false,
        .single_threaded = false,
    });
    segment_mod.addImport("pulp", pulp_mod);
    segment_mod.addImport("libpeel", libpeel_mod);
    segment_mod.addImport("typography", typography_mod);
    const gfx_mod = b.createModule(.{ .root_source_file = b.path("userland/servers/peel/gfx.zig"), .target = user_target, .optimize = user_optimize });
    const ui_mod = b.createModule(.{ .root_source_file = b.path("userland/libs/desktop-ui/ui.zig"), .target = user_target, .optimize = user_optimize });
    ui_mod.addImport("gfx", gfx_mod);
    ui_mod.addImport("typography", typography_mod);
    const files_mod = b.createModule(.{ .root_source_file = b.path("userland/libs/files-view/files.zig"), .target = user_target, .optimize = user_optimize });
    files_mod.addImport("ui", ui_mod);
    files_mod.addImport("pulp", pulp_mod);
    files_mod.addImport("libpeel", libpeel_mod);
    files_mod.addImport("keymap", b.createModule(.{ .root_source_file = b.path("userland/apps/squeeze/keymap.zig"), .target = user_target, .optimize = user_optimize }));

    const host_protocol_mod = b.createModule(.{ .root_source_file = b.path("userland/libs/host-services/protocol.zig"), .target = user_target, .optimize = user_optimize });
    const host_model_mod = b.createModule(.{ .root_source_file = b.path("userland/apps/hardware/model.zig"), .target = user_target, .optimize = user_optimize });
    const UserProgram = struct { name: []const u8, path: []const u8 };
    const programs = [_]UserProgram{
        .{ .name = "init", .path = "userland/servers/seed/main.zig" },
        .{ .name = "host-agent", .path = "userland/servers/host-agent/main.zig" },
        .{ .name = "host-probe", .path = "userland/bin/host-probe/main.zig" },
        .{ .name = "vm-probe", .path = "userland/bin/vm-probe/main.zig" },
        .{ .name = "simd-probe", .path = "userland/bin/simd-probe/main.zig" },
        .{ .name = "c-abi-probe", .path = "userland/bin/c-abi-probe/main.zig" },
        .{ .name = "cxx-abi-probe", .path = "userland/bin/cxx-abi-probe/main.zig" },
        .{ .name = "reap-probe", .path = "userland/bin/reap-probe/main.zig" },
        .{ .name = "orphan-probe", .path = "userland/bin/orphan-probe/main.zig" },
        .{ .name = "orphan-slow", .path = "userland/bin/orphan-slow/main.zig" },
        .{ .name = "fd-probe", .path = "userland/bin/fd-probe/main.zig" },
        .{ .name = "socket-probe", .path = "userland/bin/socket-probe/main.zig" },
        .{ .name = "ipc-probe", .path = "userland/bin/ipc-probe/main.zig" },
        .{ .name = "tls-probe", .path = "userland/bin/tls-probe/main.zig" },
        .{ .name = "futex-probe", .path = "userland/bin/futex-probe/main.zig" },
        .{ .name = "futex-waiter", .path = "userland/bin/futex-waiter/main.zig" },
        .{ .name = "thread-probe", .path = "userland/bin/thread-probe/main.zig" },
        .{ .name = "thread-exit-probe", .path = "userland/bin/thread-exit-probe/main.zig" },
        .{ .name = "thread-fault-probe", .path = "userland/bin/thread-fault-probe/main.zig" },
        .{ .name = "thread-last-probe", .path = "userland/bin/thread-last-probe/main.zig" },
        .{ .name = "net-thread-probe", .path = "userland/bin/net-thread-probe/main.zig" },
        .{ .name = "net-exit-probe", .path = "userland/bin/net-exit-probe/main.zig" },
        .{ .name = "tcp-probe", .path = "userland/bin/tcp-probe/main.zig" },
        .{ .name = "jit-probe", .path = "userland/bin/jit-probe/main.zig" },
        .{ .name = "fault-wx", .path = "userland/bin/fault-wx/main.zig" },
        .{ .name = "fault-null", .path = "userland/bin/fault-null/main.zig" },
        .{ .name = "fault-ro", .path = "userland/bin/fault-ro/main.zig" },
        .{ .name = "fault-nx", .path = "userland/bin/fault-nx/main.zig" },
        .{ .name = "fault-opcode", .path = "userland/bin/fault-opcode/main.zig" },
        .{ .name = "hardware", .path = "userland/apps/hardware/main.zig" },
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
        .{ .name = "files", .path = "userland/apps/files/main.zig" },
        .{ .name = "trash", .path = "userland/apps/trash/main.zig" },
        .{ .name = "ping", .path = "userland/bin/ping/main.zig" },
        .{ .name = "net", .path = "userland/bin/net/main.zig" },
        .{ .name = "fetch", .path = "userland/bin/fetch/main.zig" },
        .{ .name = "bench", .path = "userland/bin/bench/main.zig" },
    };

    for (programs) |prog| {
        const mod = b.createModule(.{
            .root_source_file = b.path(prog.path),
            .target = user_target,
            .optimize = user_optimize,
            .strip = user_optimize != .Debug,
            .red_zone = false,
            .pic = false,
            .stack_protector = false,
            .stack_check = false,
            .sanitize_c = false,
            .single_threaded = false,
        });
        mod.addImport("pulp", pulp_mod);
        mod.addImport("host_protocol", host_protocol_mod);
        mod.addImport("host_model", host_model_mod);
        mod.addImport("libpeel", libpeel_mod);
        mod.addImport("segment", segment_mod);
        mod.addImport("typography", typography_mod);
        mod.addImport("ui", ui_mod);
        mod.addImport("files_view", files_mod);
        mod.addImport("gfx", gfx_mod);
        if (std.mem.eql(u8, prog.name, "c-abi-probe")) mod.addCSourceFile(.{
            .file = b.path("userland/bin/c-abi-probe/probe.c"),
            .flags = &.{ "-std=c11", "-ffreestanding", "-fno-stack-protector", "-mno-red-zone", "-mno-avx", "-Wall", "-Wextra", "-Werror" },
        });
        if (std.mem.eql(u8, prog.name, "cxx-abi-probe")) {
            for ([_][]const u8{ "userland/libs/cxx-abi/runtime.cpp", "userland/bin/cxx-abi-probe/probe.cpp" }) |source| {
                mod.addCSourceFile(.{
                    .file = b.path(source),
                    .flags = &.{ "-std=c++20", "-ffreestanding", "-fno-exceptions", "-fno-rtti", "-fno-stack-protector", "-mno-red-zone", "-mno-avx", "-Wall", "-Wextra", "-Werror" },
                });
            }
        }

        const exe = b.addExecutable(.{
            .name = prog.name,
            .root_module = mod,
            .use_lld = true,
        });
        exe.setLinkerScript(b.path("userland/user.ld"));
        exe.entry = .{ .symbol_name = "_start" };
        b.installArtifact(exe);
    }

    // ── C programs on musl ───────────────────────────────────────────────────
    // musl is compiled from the copy bundled with the pinned Zig toolchain,
    // following musl's own Makefile: every src/*/*.c plus mallocng, with the
    // x86-64 overrides. Its system calls are routed to the OrangeOS layer in
    // userland/libs/musl-orange, which also replaces the six x86-64 assembly
    // files that execute `syscall` directly.
    const zig_lib = b.graph.zig_lib_directory.path orelse @panic("zig lib directory unknown");
    const musl_root = b.pathJoin(&.{ zig_lib, "libc", "musl" });
    const musl_headers = [_][]const u8{
        b.pathJoin(&.{ zig_lib, "libc", "include", "x86_64-linux-musl" }),
        b.pathJoin(&.{ zig_lib, "libc", "include", "generic-musl" }),
    };
    const musl_mod = b.createModule(.{
        .root_source_file = b.path("userland/libs/musl-orange/orange.zig"),
        .target = user_target,
        .optimize = user_optimize,
        .red_zone = false,
        .pic = false,
        .stack_protector = false,
        .stack_check = false,
        .sanitize_c = false,
        .single_threaded = false,
    });
    musl_mod.addIncludePath(b.path("userland/libs/musl-orange/arch"));
    for ([_][]const u8{ "arch/x86_64", "arch/generic", "src/include", "src/internal" }) |dir| {
        musl_mod.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ musl_root, dir }) });
    }
    for (musl_headers) |dir| musl_mod.addIncludePath(.{ .cwd_relative = dir });
    const musl_sources = collectMuslSources(b, musl_root) catch |e| std.debug.panic("musl sources: {s}", .{@errorName(e)});
    const musl_src = b.pathJoin(&.{ musl_root, "src" });
    musl_mod.addCSourceFiles(.{
        .root = .{ .cwd_relative = musl_src },
        .files = musl_sources.c,
        .flags = &.{ "-std=c99", "-nostdinc", "-ffreestanding", "-fexcess-precision=standard", "-frounding-math", "-fno-strict-aliasing", "-D_XOPEN_SOURCE=700", "-fno-stack-protector", "-mno-red-zone", "-mno-avx", "-w" },
    });
    for (musl_sources.asm_files) |file| {
        musl_mod.addAssemblyFile(.{ .cwd_relative = b.pathJoin(&.{ musl_src, file }) });
    }
    const musl_lib = b.addLibrary(.{ .linkage = .static, .name = "c", .root_module = musl_mod });

    const CProgram = struct { name: []const u8, sources: []const []const u8 };
    const c_programs = [_]CProgram{
        .{ .name = "musl-probe", .sources = &.{"userland/bin/musl-probe/probe.c"} },
        .{ .name = "file-probe", .sources = &.{"userland/bin/file-probe/probe.c"} },
        .{ .name = "thread-capacity", .sources = &.{"userland/bin/thread-capacity/probe.c"} },
        .{ .name = "pipe-probe", .sources = &.{"userland/bin/pipe-probe/probe.c"} },
        .{ .name = "epoll-probe", .sources = &.{"userland/bin/epoll-probe/probe.c"} },
        .{ .name = "unix-probe", .sources = &.{"userland/bin/unix-probe/probe.c"} },
        .{ .name = "spawn-probe", .sources = &.{"userland/bin/spawn-probe/probe.c"} },
        .{ .name = "spawn-child", .sources = &.{"userland/bin/spawn-child/child.c"} },
        .{ .name = "mmap-probe", .sources = &.{"userland/bin/mmap-probe/probe.c"} },
        .{ .name = "shm-probe", .sources = &.{"userland/bin/shm-probe/probe.c"} },
        .{ .name = "random-probe", .sources = &.{"userland/bin/random-probe/probe.c"} },
        .{ .name = "signal-probe", .sources = &.{"userland/bin/signal-probe/probe.c"} },
        .{ .name = "inet-probe", .sources = &.{"userland/bin/inet-probe/probe.c"} },
    };
    for (c_programs) |program| {
        const mod = b.createModule(.{
            .root_source_file = b.path("userland/libs/musl-orange/crt.zig"),
            .target = user_target,
            .optimize = user_optimize,
            .strip = user_optimize != .Debug,
            .red_zone = false,
            .pic = false,
            .stack_protector = false,
            .stack_check = false,
            .sanitize_c = false,
            .single_threaded = false,
        });
        mod.addCSourceFiles(.{
            .files = program.sources,
            .flags = &.{ "-std=c11", "-nostdinc", "-fno-stack-protector", "-mno-red-zone", "-mno-avx", "-Wall", "-Wextra", "-Werror" },
        });
        for (musl_headers) |dir| mod.addSystemIncludePath(.{ .cwd_relative = dir });
        mod.linkLibrary(musl_lib);
        const exe = b.addExecutable(.{ .name = program.name, .root_module = mod, .use_lld = true });
        exe.setLinkerScript(b.path("userland/libs/musl-orange/program.ld"));
        exe.entry = .{ .symbol_name = "_start" };
        b.installArtifact(exe);
    }

    // ── C++ standard library on musl ─────────────────────────────────────────
    // libc++, libc++abi and libunwind (LLVM 19) from the pinned Zig
    // toolchain, configured the way Zig configures them for a musl target
    // (Zig replaces __config_site with -D flags). Exceptions and RTTI are on:
    // libunwind finds each program's .eh_frame_hdr through musl's
    // dl_iterate_phdr, which reads the program headers the kernel passes in
    // the auxiliary vector. `-fhosted` undoes the -ffreestanding Zig adds for
    // the freestanding target: these are hosted libraries over musl. The
    // libc++ headers go in with -I, ahead of Zig's builtin C headers, because
    // they wrap them (<stddef.h> and friends) with #include_next; they mark
    // themselves as system headers.
    const cxx_config = [_][]const u8{
        "-D_LIBCPP_ABI_VERSION=1",
        "-D_LIBCPP_ABI_NAMESPACE=__1",
        "-D_LIBCPP_HAS_THREAD_API_PTHREAD",
        "-D_LIBCPP_HAS_MUSL_LIBC",
        "-D_LIBCPP_HAS_NO_VENDOR_AVAILABILITY_ANNOTATIONS",
        "-D_LIBCPP_PSTL_BACKEND_SERIAL",
        "-D_LIBCPP_HARDENING_MODE_DEFAULT=_LIBCPP_HARDENING_MODE_NONE",
        "-D_LIBCPP_DISABLE_VISIBILITY_ANNOTATIONS",
        "-D_LIBCXXABI_DISABLE_VISIBILITY_ANNOTATIONS",
        "-D_LIBUNWIND_DISABLE_VISIBILITY_ANNOTATIONS",
        // What clang's Linux driver defines for C++; musl otherwise hides
        // POSIX declarations under a strict -std=c++NN.
        "-D_GNU_SOURCE",
    };
    const cxx_common = [_][]const u8{ "-nostdinc", "-nostdinc++", "-fhosted", "-fno-stack-protector", "-mno-red-zone", "-mno-avx" };
    const libcxx_root = b.pathJoin(&.{ zig_lib, "libcxx" });
    const libcxxabi_root = b.pathJoin(&.{ zig_lib, "libcxxabi" });
    const libunwind_root = b.pathJoin(&.{ zig_lib, "libunwind" });
    const cxx_headers = [_][]const u8{
        b.pathJoin(&.{ libcxx_root, "include" }),
        b.pathJoin(&.{ libcxxabi_root, "include" }),
        b.pathJoin(&.{ libunwind_root, "include" }),
    };
    const cxx_mod = b.createModule(.{
        .target = user_target,
        .optimize = user_optimize,
        .red_zone = false,
        .pic = false,
        .stack_protector = false,
        .stack_check = false,
        .sanitize_c = false,
        .single_threaded = false,
        .unwind_tables = .sync,
    });
    for (cxx_headers) |dir| cxx_mod.addIncludePath(.{ .cwd_relative = dir });
    for (musl_headers) |dir| cxx_mod.addSystemIncludePath(.{ .cwd_relative = dir });
    cxx_mod.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ libcxx_root, "src" }) });
    const libcxx_sources = collectSources(b, b.pathJoin(&.{ libcxx_root, "src" }), ".cpp", &libcxx_skipped) catch |e| std.debug.panic("libc++ sources: {s}", .{@errorName(e)});
    cxx_mod.addCSourceFiles(.{
        .root = .{ .cwd_relative = b.pathJoin(&.{ libcxx_root, "src" }) },
        .files = libcxx_sources,
        .flags = &(cxx_common ++ cxx_config ++ [_][]const u8{ "-std=c++23", "-D_LIBCPP_BUILDING_LIBRARY", "-DLIBCXX_BUILDING_LIBCXXABI", "-D_LIBCPP_REMOVE_TRANSITIVE_INCLUDES", "-w" }),
    });
    const libcxxabi_sources = collectSources(b, b.pathJoin(&.{ libcxxabi_root, "src" }), ".cpp", &libcxxabi_skipped) catch |e| std.debug.panic("libc++abi sources: {s}", .{@errorName(e)});
    cxx_mod.addCSourceFiles(.{
        .root = .{ .cwd_relative = b.pathJoin(&.{ libcxxabi_root, "src" }) },
        .files = libcxxabi_sources,
        .flags = &(cxx_common ++ cxx_config ++ [_][]const u8{ "-std=c++23", "-D_LIBCXXABI_BUILDING_LIBRARY", "-D_LIBCPP_BUILDING_LIBRARY", "-DHAS_THREAD_LOCAL", "-w" }),
    });
    const cxx_lib = b.addLibrary(.{ .linkage = .static, .name = "c++", .root_module = cxx_mod });

    // libunwind is C and C++ built against musl alone (its C files must not
    // see libc++'s wrapper headers), so it is its own library.
    const unwind_mod = b.createModule(.{
        .target = user_target,
        .optimize = user_optimize,
        .red_zone = false,
        .pic = false,
        .stack_protector = false,
        .stack_check = false,
        .sanitize_c = false,
        .single_threaded = false,
        .unwind_tables = .sync,
    });
    unwind_mod.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ libunwind_root, "include" }) });
    for (musl_headers) |dir| unwind_mod.addSystemIncludePath(.{ .cwd_relative = dir });
    const unwind_flags = [_][]const u8{ "-nostdinc", "-fhosted", "-fno-stack-protector", "-mno-red-zone", "-mno-avx", "-D_LIBUNWIND_IS_NATIVE_ONLY", "-D_LIBUNWIND_DISABLE_VISIBILITY_ANNOTATIONS", "-D_GNU_SOURCE", "-fno-exceptions", "-funwind-tables", "-w" };
    unwind_mod.addCSourceFiles(.{
        .root = .{ .cwd_relative = b.pathJoin(&.{ libunwind_root, "src" }) },
        .files = &.{ "UnwindLevel1.c", "UnwindLevel1-gcc-ext.c", "gcc_personality_v0.c" },
        .flags = &([_][]const u8{"-std=c99"} ++ unwind_flags),
    });
    unwind_mod.addCSourceFiles(.{
        .root = .{ .cwd_relative = b.pathJoin(&.{ libunwind_root, "src" }) },
        .files = &.{"libunwind.cpp"},
        .flags = &([_][]const u8{ "-std=c++17", "-nostdinc++", "-fno-rtti" } ++ unwind_flags),
    });
    unwind_mod.addCSourceFiles(.{
        .root = .{ .cwd_relative = b.pathJoin(&.{ libunwind_root, "src" }) },
        .files = &.{ "UnwindRegistersSave.S", "UnwindRegistersRestore.S" },
        .flags = &.{ "-nostdinc", "-D_LIBUNWIND_IS_NATIVE_ONLY" },
    });
    const unwind_lib = b.addLibrary(.{ .linkage = .static, .name = "unwind", .root_module = unwind_mod });

    const cxx_programs = [_]CProgram{
        .{ .name = "cxx-probe", .sources = &.{"userland/bin/cxx-probe/probe.cpp"} },
    };
    for (cxx_programs) |program| {
        const mod = b.createModule(.{
            .root_source_file = b.path("userland/libs/musl-orange/crt.zig"),
            .target = user_target,
            .optimize = user_optimize,
            .strip = user_optimize != .Debug,
            .red_zone = false,
            .pic = false,
            .stack_protector = false,
            .stack_check = false,
            .sanitize_c = false,
            .single_threaded = false,
            .unwind_tables = .sync,
        });
        mod.addCSourceFiles(.{
            .files = program.sources,
            .flags = &(cxx_common ++ cxx_config ++ [_][]const u8{ "-std=c++20", "-Wall", "-Wextra", "-Werror" }),
        });
        for (cxx_headers) |dir| mod.addIncludePath(.{ .cwd_relative = dir });
        for (musl_headers) |dir| mod.addSystemIncludePath(.{ .cwd_relative = dir });
        mod.linkLibrary(cxx_lib);
        mod.linkLibrary(unwind_lib);
        mod.linkLibrary(musl_lib);
        const exe = b.addExecutable(.{ .name = program.name, .root_module = mod, .use_lld = true });
        exe.setLinkerScript(b.path("userland/libs/musl-orange/program.ld"));
        exe.entry = .{ .symbol_name = "_start" };
        exe.link_eh_frame_hdr = true;
        b.installArtifact(exe);
    }

    // ── WPE WebKit trial probes ──────────────────────────────────────────────
    // Built like the C and C++ programs above, plus static libraries from the
    // trial sysroot. Those were compiled for x86_64-linux-musl with the same
    // code-generation flags (tools/wpe/bin/orange-cc) and link here against
    // OrangeOS's musl, which has the same headers and ABI, and, for C++
    // libraries (ICU, HarfBuzz, woff2), against the libc++ built above.
    if (wpe_probes) {
        const sysroot = "build/wpe/sysroot";
        const WpeProbe = struct { name: []const u8, sources: []const []const u8, libs: []const []const u8, cxx: bool };
        const wpe_programs = [_]WpeProbe{
            .{ .name = "glib-probe", .sources = &.{"userland/bin/glib-probe/probe.c"}, .cxx = false, .libs = &.{
                "gio-2.0", "gmodule-2.0", "gobject-2.0", "ffi", "glib-2.0", "pcre2-8", "z",
            } },
            .{ .name = "wpe-libs-probe", .sources = &.{ "userland/bin/wpe-libs-probe/probe.c", "userland/bin/wpe-libs-probe/woff2.cpp" }, .cxx = true, .libs = &.{
                "png16",     "jpeg",       "webpdemux",  "webp",        "sharpyuv",     "harfbuzz-icu", "harfbuzz",
                "fontconfig", "expat",     "freetype",   "icui18n",     "icuuc",        "icudata",      "xslt",
                "xml2",      "sqlite3",    "gcrypt",     "gpg-error",   "tasn1",        "xkbcommon",    "epoxy",
                "woff2enc",  "woff2dec",   "woff2common", "brotlienc",  "brotlidec",    "brotlicommon", "glib-2.0",
                "pcre2-8",   "z",
            } },
            .{ .name = "jsc-probe", .sources = &.{"userland/bin/jsc-probe/probe.c"}, .cxx = false, .libs = &.{} },
            // JavaScriptCore's own shell, compiled by the JSCOnly build
            // (tools/wpe/build_deps.py wpewebkit) and linked here.
            .{ .name = "jsc", .sources = &.{}, .cxx = true, .libs = &.{
                "jsc-shell.o", "JavaScriptCore", "JavaScriptCoreJIT", "WTF", "bmalloc", "icui18n", "icuuc", "icudata",
            } },
        };
        for (wpe_programs) |program| {
            const mod = b.createModule(.{
                .root_source_file = b.path("userland/libs/musl-orange/crt.zig"),
                .target = user_target,
                .optimize = user_optimize,
                .strip = user_optimize != .Debug,
                .red_zone = false,
                .pic = false,
                .stack_protector = false,
                .stack_check = false,
                .sanitize_c = false,
                .single_threaded = false,
                .unwind_tables = if (program.cxx) .sync else null,
            });
            // libc++'s headers wrap the C ones, so only C++ files may see them.
            var cxx_includes: [cxx_headers.len][]const u8 = undefined;
            for (cxx_headers, 0..) |dir, i| cxx_includes[i] = b.fmt("-I{s}", .{dir});
            // The freestanding target defines no platform macro, and Khronos's
            // eglplatform.h has a portable fallback for exactly that case.
            const wpe_defines = [_][]const u8{"-DEGL_NO_PLATFORM_SPECIFIC_TYPES"};
            for (program.sources) |source| {
                if (std.mem.endsWith(u8, source, ".cpp")) {
                    mod.addCSourceFile(.{ .file = b.path(source), .flags = b.allocator.dupe([]const u8, &(cxx_includes ++ cxx_common ++ cxx_config ++ wpe_defines ++ [_][]const u8{ "-std=c++20", "-Wall", "-Wextra", "-Werror" })) catch @panic("OOM") });
                } else {
                    mod.addCSourceFile(.{ .file = b.path(source), .flags = &(wpe_defines ++ [_][]const u8{ "-std=gnu11", "-nostdinc", "-fno-stack-protector", "-mno-red-zone", "-mno-avx", "-Wall", "-Wextra", "-Werror" }) });
                }
            }
            for ([_][]const u8{ "include", "include/glib-2.0", "lib/glib-2.0/include", "include/harfbuzz", "include/freetype2", "include/libxml2" }) |dir| {
                mod.addSystemIncludePath(b.path(b.pathJoin(&.{ sysroot, dir })));
            }
            for (musl_headers) |dir| mod.addSystemIncludePath(.{ .cwd_relative = dir });
            for (program.libs) |lib| {
                const file = if (std.mem.endsWith(u8, lib, ".o")) b.fmt("{s}/lib/{s}", .{ sysroot, lib }) else b.fmt("{s}/lib/lib{s}.a", .{ sysroot, lib });
                mod.addObjectFile(b.path(file));
            }
            if (program.cxx) {
                mod.linkLibrary(cxx_lib);
                mod.linkLibrary(unwind_lib);
            }
            mod.linkLibrary(musl_lib);
            const exe = b.addExecutable(.{ .name = program.name, .root_module = mod, .use_lld = true });
            exe.setLinkerScript(b.path("userland/libs/musl-orange/program.ld"));
            exe.entry = .{ .symbol_name = "_start" };
            if (program.cxx) exe.link_eh_frame_hdr = true;
            b.installArtifact(exe);
        }
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
        // SMP: atomics must synchronize across CPUs, not just one thread.
        .single_threaded = false,
    });

    kernel_mod.addOptions("build_options", options);
    kernel_mod.addImport("calendar", calendar_mod);
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
        "sh",
        "scripts/run-qemu.sh",
        "-M",
        "q35",
        "-cdrom",
        "build/orange.iso",
        "-boot",
        "d",
        "-drive",
        "id=disk0,file=build/disk.img,format=raw,if=none",
        "-device",
        "ahci,id=ahci",
        "-device",
        "ide-hd,drive=disk0,bus=ahci.0",
        "-netdev",
        "user,id=n0",
        "-device",
        "e1000,netdev=n0",
        "-serial",
        "stdio",
        "-no-reboot",
        "-no-shutdown",
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

const MuslSources = struct { c: []const []const u8, asm_files: []const []const u8 };

/// musl assembly that executes `syscall` itself, replaced by
/// userland/libs/musl-orange/orange.zig (vfork and the signal restorers fall
/// back to musl's generic C, which reports ENOSYS or is never called).
const musl_replaced_asm = [_][]const u8{
    "thread/x86_64/__unmapself.s",
    "thread/x86_64/clone.s",
    "thread/x86_64/syscall_cp.s",
    "thread/x86_64/__set_thread_area.s",
    "signal/x86_64/restore.s",
    "process/x86_64/vfork.s",
};
/// Generic C versions of functions orange.zig provides.
const musl_replaced_c = [_][]const u8{
    "thread/__unmapself.c",
    "thread/clone.c",
    "thread/__set_thread_area.c",
    // No fork/exec: posix_spawn is built on OrangeOS's spawn_process.
    "process/posix_spawn.c",
    "process/posix_spawnp.c",
    // The signal restorer calls OrangeOS's sigreturn (orange.zig).
    "signal/restore.c",
};

/// libc++ sources not built: other platforms' support code, the libdispatch
/// parallel backend, the time-zone database (there is no zoneinfo), and
/// new.cpp, whose operators libc++abi's stdlib_new_delete.cpp provides.
const libcxx_skipped = [_][]const u8{
    "new.cpp",
    "pstl/",
    "support/",
    "experimental/tzdb.cpp",
    "experimental/tzdb_list.cpp",
    "experimental/time_zone.cpp",
    "experimental/chrono_exception.cpp",
};
/// libc++abi's no-exceptions variant; this build has exceptions.
const libcxxabi_skipped = [_][]const u8{"cxa_noexception.cpp"};

/// Every file with `extension` under `root` (recursively), relative to it,
/// sorted, except those named in `skipped` (an entry ending in "/" skips
/// that whole directory).
fn collectSources(b: *std.Build, root: []const u8, extension: []const u8, skipped: []const []const u8) ![]const []const u8 {
    var dir = try std.fs.openDirAbsolute(root, .{ .iterate = true });
    defer dir.close();
    var walker = try dir.walk(b.allocator);
    defer walker.deinit();
    var files = std.ArrayList([]const u8).init(b.allocator);
    outer: while (try walker.next()) |entry| {
        if (entry.kind != .file or !std.mem.eql(u8, std.fs.path.extension(entry.path), extension)) continue;
        for (skipped) |skip| {
            const directory = std.mem.endsWith(u8, skip, "/");
            if (if (directory) std.mem.startsWith(u8, entry.path, skip) else std.mem.eql(u8, entry.path, skip)) continue :outer;
        }
        try files.append(b.dupe(entry.path));
    }
    std.mem.sort([]const u8, files.items, {}, struct {
        fn less(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.less);
    return files.items;
}

fn contains(list: []const []const u8, item: []const u8) bool {
    for (list) |entry| if (std.mem.eql(u8, entry, item)) return true;
    return false;
}

fn collectMuslSources(b: *std.Build, musl_root: []const u8) !MuslSources {
    const src = b.pathJoin(&.{ musl_root, "src" });
    var dirs = std.ArrayList([]const u8).init(b.allocator);
    var src_dir = try std.fs.openDirAbsolute(src, .{ .iterate = true });
    defer src_dir.close();
    var it = src_dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind == .directory) try dirs.append(b.dupe(entry.name));
    }
    try dirs.append("malloc/mallocng");
    std.mem.sort([]const u8, dirs.items, {}, struct {
        fn less(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.less);

    var c = std.ArrayList([]const u8).init(b.allocator);
    var asm_files = std.ArrayList([]const u8).init(b.allocator);
    for (dirs.items) |dir| {
        // Architecture files replace the generic C file of the same name.
        var overridden = std.StringHashMap(void).init(b.allocator);
        const arch_rel = b.pathJoin(&.{ dir, "x86_64" });
        if (std.fs.openDirAbsolute(b.pathJoin(&.{ src, arch_rel }), .{ .iterate = true })) |arch_dir_value| {
            var arch_dir = arch_dir_value;
            defer arch_dir.close();
            var arch_it = arch_dir.iterate();
            while (try arch_it.next()) |entry| {
                if (entry.kind != .file) continue;
                const ext = std.fs.path.extension(entry.name);
                const rel = b.pathJoin(&.{ arch_rel, entry.name });
                if (contains(&musl_replaced_asm, rel)) continue;
                if (std.mem.eql(u8, ext, ".c")) {
                    try c.append(rel);
                } else if (std.mem.eql(u8, ext, ".s") or std.mem.eql(u8, ext, ".S")) {
                    try asm_files.append(rel);
                } else continue;
                try overridden.put(b.dupe(std.fs.path.stem(entry.name)), {});
            }
        } else |_| {}

        var base_dir = try std.fs.openDirAbsolute(b.pathJoin(&.{ src, dir }), .{ .iterate = true });
        defer base_dir.close();
        var base_it = base_dir.iterate();
        while (try base_it.next()) |entry| {
            if (entry.kind != .file or !std.mem.eql(u8, std.fs.path.extension(entry.name), ".c")) continue;
            if (overridden.contains(std.fs.path.stem(entry.name))) continue;
            const rel = b.pathJoin(&.{ dir, entry.name });
            if (contains(&musl_replaced_c, rel)) continue;
            try c.append(rel);
        }
    }
    return .{ .c = c.items, .asm_files = asm_files.items };
}
