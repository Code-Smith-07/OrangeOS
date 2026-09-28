#!/usr/bin/env python3
"""Verify native runtime support on two virtual CPUs with a disposable disk.

Build: zig build -Dmm-test -Druntime-test -Ddesktop-profile; scripts/mkdisk.sh
"""
import http.server
import os
import pathlib
import re
import ssl
import argparse
import socketserver
import threading
from desktop_smoke import Guest

# The guest's tcp-probe reaches this through QEMU's host alias 10.0.2.2.
# Loopback only; the port is fixed because guest programs take no arguments.
TCP_FIXTURE_PORT = 38457
TCP_PAYLOAD = 6000


# inet-probe's patterned bulk replies: byte i is (131 i + 7) mod 256.
BULK_BLOCK = bytes((i * 131 + 7) & 0xFF for i in range(256))
UDP_FIXTURE_PORT = 38458
HTTPS_FIXTURE_PORT = 38459
ROOT_DIR = pathlib.Path(__file__).resolve().parent.parent


class TcpFixture(socketserver.StreamRequestHandler):
    """Answer "orange-tcp <token>" with a payload derived from the token,
    and "orange-bulk <bytes>" with that many patterned bytes."""

    def handle(self):
        parts = self.rfile.readline(64).decode("ascii", "replace").split()
        if len(parts) == 2 and parts[0] == "orange-bulk" and parts[1].isdigit():
            count = min(int(parts[1]), 8 << 20)
            payload = BULK_BLOCK * (count // 256 + 1)
            self.wfile.write(payload[:count])
            with self.server.lock:
                self.server.bulk += 1
            return
        if len(parts) != 2 or parts[0] != "orange-tcp" or not parts[1].isdigit():
            return
        token = int(parts[1]) & 0xFF
        self.wfile.write(bytes((i * 31 + token) & 0xFF for i in range(TCP_PAYLOAD)))
        with self.server.lock:
            self.server.served += 1


class FixtureServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

    def __init__(self):
        self.lock = threading.Lock()
        self.served = 0
        self.bulk = 0
        try:
            super().__init__(("127.0.0.1", TCP_FIXTURE_PORT), TcpFixture)
        except OSError as error:
            raise SystemExit(f"TCP fixture port 127.0.0.1:{TCP_FIXTURE_PORT} unavailable: {error}")


class HttpsFixture(http.server.BaseHTTPRequestHandler):
    """GET /orange over TLS with the test CA's certificate (https-probe)."""
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        body = b"orange over https\n" if self.path == "/orange" else b"not found\n"
        self.send_response(200 if self.path == "/orange" else 404)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


def save_rendered_png(log):
    """Keep the page wpe-render drew: base64 between its PNG markers."""
    import base64
    lines = [line.split("wpe-render: PNG ", 1)[1].strip() for line in log.splitlines() if "wpe-render: PNG " in line]
    if lines:
        out = ROOT_DIR / "build/tmp/wpe-render.png"
        out.write_bytes(base64.b64decode("".join(lines)))
        print(f"rendered page saved to {out}", flush=True)


def https_server():
    """The HTTPS fixture on 127.0.0.1:38459 (10.0.2.2 in the guest)."""
    certs = ROOT_DIR / "build/wpe/test-certs"
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(certs / "server.pem", certs / "server.key")
    server = http.server.ThreadingHTTPServer(("127.0.0.1", HTTPS_FIXTURE_PORT), HttpsFixture)
    server.socket = context.wrap_socket(server.socket, server_side=True)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


class UdpEcho(socketserver.BaseRequestHandler):
    """Send each datagram back reversed."""

    def handle(self):
        data, sock = self.request
        sock.sendto(data[::-1], self.client_address)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--orphan-waves", type=int, default=8,
                        help="must match -Druntime-orphan-waves in the build")
    args = parser.parse_args()
    if not 1 <= args.orphan_waves <= 1024:
        parser.error("--orphan-waves must be 1..1024")
    fixture = FixtureServer()
    threading.Thread(target=fixture.serve_forever, daemon=True).start()
    try:
        udp_fixture = socketserver.ThreadingUDPServer(("127.0.0.1", UDP_FIXTURE_PORT), UdpEcho)
    except OSError as error:
        raise SystemExit(f"UDP fixture port 127.0.0.1:{UDP_FIXTURE_PORT} unavailable: {error}")
    threading.Thread(target=udp_fixture.serve_forever, daemon=True).start()
    https_fixture = https_server() if os.environ.get("ORANGE_WPE_PROBES") == "1" else None
    guest = Guest()
    print(f"Evidence: {guest.output}", flush=True)
    try:
        guest.until(lambda: "runtime: PASS repeated VM processes" in guest.log(),
                    "three complete ring-3 VM probes", 90)
        log = guest.log()
        guest.until(lambda: f"[pass] TLB IPI: 32 remaps acknowledged across {guest.profile.cpus} CPUs" in guest.log(),
                    "remote TLB shootdown and remap readback", 30)
        guest.until(lambda: "[pass] TLB targeted IPI: CPU " in guest.log(),
                    "one selected CPU receives the IPI", 30)
        guest.until(lambda: "[pass] preemption guard: nested pinning keeps timer interrupts live" in guest.log(),
                    "CPU pinning defers scheduling but keeps interrupts live", 30)
        if guest.profile.cpus > 1:
            guest.until(lambda: "[pass] pinned residency: 64 remaps without a reader CR3 reload" in guest.log(),
                        "remote translations refresh without scheduler CR3 flushes", 60)
        guest.until(lambda: "[pass] address-space residency: 8 workers, 64 remaps" in guest.log(),
                    "shared-PML4 scheduling, contending shootdowns and final CPU detach", 60)
        guest.until(lambda: "[pass] TLB contention: 512 worker requests" in guest.log(),
                    "simultaneous shootdown senders accept each other's IPIs", 30)
        if guest.profile.cpus > 1:
            for kind, pages in (("unmap/remap", 8), ("unmap/remap", 48), ("decommit/commit", 8)):
                marker = f"[pass] concurrent user VM: 64 {kind} rounds of {pages} pages refresh a pinned remote TLB"
                guest.until(lambda: marker in guest.log() or "[FAIL] concurrent user VM" in guest.log(),
                            f"{kind} of {pages} pages refreshes a pinned remote TLB", 90)
                assert marker in guest.log(), guest.log()[-2000:]
            for pages in (8, 48):
                marker = f"[pass] concurrent user VM: 64 detaches of {pages} borrowed pages"
                guest.until(lambda: marker in guest.log() or "[FAIL] concurrent user VM" in guest.log(),
                            f"deterministic detach of {pages} pages never leaves a stale remote TLB entry", 90)
                assert marker in guest.log(), guest.log()[-2000:]
        guest.until(lambda: "[pass] concurrent user VM: 192 detaches raced" in guest.log()
                    or "[FAIL] concurrent user VM" in guest.log(),
                    "kernel copies racing detach never touch detached frames", 90)
        assert "[FAIL] concurrent user VM" not in guest.log(), guest.log()[-2000:]
        race = re.search(r"192 detaches raced (\d+) kernel copies \((\d+) clean faults\)", guest.log())
        print(f"PASS copies racing detach: {race.group(1)} copies, {race.group(2)} clean faults", flush=True)
        guest.until(lambda: "[pass] concurrent user VM: 8 detaches waited for an in-flight access" in guest.log()
                    or "[FAIL] concurrent user VM" in guest.log(),
                    "a detach waits for an access that began before it", 60)
        assert "[FAIL] concurrent user VM" not in guest.log(), guest.log()[-2000:]
        guest.until(lambda: "[pass] current task: " in guest.log() or "[FAIL] current task" in guest.log(),
                    "current-thread identity across migration", 60)
        assert "[pass] current task: 1600 reads after resuming name the reader" in guest.log(), guest.log()[-2000:]
        log = guest.log()
        assert log.count("vm-probe: PASS mapping, subranges, sparse reservation, protection, reuse and capacity") == 3
        assert "[FAIL]" not in log and "vm-probe: FAIL" not in log
        for marker in (
            "user VM: 64 cycles return frames AND page tables",
            "user VM: subranges, hole reuse and frame conservation",
            "user VM: sparse reserve, commit, decommit and cleanup",
            "user VM: lazy regions allocate on touch, keep contents across protection and return every page",
            "user VM: exit cleanup frees protected and writable memory",
            "user VM: address-space teardown conserves every page",
            "address space: mappings survive intermediate owner releases",
            "address space: 64 final releases reclaim image, VM, SHM and page tables",
        ):
            assert f"[pass] {marker}" in log, marker
        print("PASS frame/page-table conservation and cleanup", flush=True)
        guest.until(lambda: "runtime: PASS null, read-only, NX, W^X and invalid-opcode containment" in guest.log(),
                    "faulting apps terminate without halting the OS", 30)
        assert guest.log().count("[app fault]") == 5
        guest.until(lambda: "runtime: PASS W^X code generation across threads" in guest.log(),
                    "JIT-style W^X flips run on both threads", 60)
        assert guest.log().count("jit-probe: PASS 64 W^X re-patches run on both threads; RWX refused") == 2
        guest.until(lambda: "runtime: PASS C program on musl" in guest.log() or "musl-probe: FAIL" in guest.log()
                    or "runtime: FAIL musl" in guest.log(), "a C11 program on musl", 60)
        assert "musl-probe: PASS stdio, formatting, malloc, qsort, clocks, files, TLS and 4 pthreads" in guest.log(), guest.log()[-2000:]
        print("PASS C11 program on musl: stdio, formatting, malloc, clocks, files, TLS and pthreads", flush=True)
        guest.until(lambda: "runtime: PASS C++ program on libc++" in guest.log() or "cxx-probe: FAIL" in guest.log()
                    or "runtime: FAIL libc++" in guest.log(), "a C++20 program on libc++", 60)
        assert "cxx-probe: PASS iostreams, containers, format, exceptions, RTTI, thread-safe statics, threads and futures" in guest.log(), guest.log()[-2000:]
        print("PASS C++20 program on libc++: iostreams, format, exceptions, RTTI, thread-safe statics and threads", flush=True)
        guest.until(lambda: "runtime: PASS writable files in /tmp" in guest.log() or "file-probe: FAIL" in guest.log()
                    or "runtime: FAIL writable files" in guest.log(), "writable files in /tmp", 90)
        assert "file-probe: PASS stdio, pread/pwrite, truncate, rename, unlink-while-open, readdir, errors, 4 writers and 2 appenders, record locks, space returned" in guest.log(), guest.log()[-2000:]
        print("PASS writable tmpfs through musl: stdio, positioned I/O, truncate, rename, readdir, errors, concurrency, space returned", flush=True)
        guest.until(lambda: "runtime: PASS 511 threads in one program" in guest.log() or "thread-capacity: FAIL" in guest.log()
                    or "runtime: FAIL thread capacity" in guest.log(), "511 POSIX threads in one program, twice", 180)
        assert "thread-capacity: PASS 2 waves of 511 concurrent threads, EAGAIN beyond, all joined" in guest.log(), guest.log()[-2000:]
        guest.until(lambda: "runtime: PASS pipes, eventfd and descriptor duplication" in guest.log() or "pipe-probe: FAIL" in guest.log()
                    or "runtime: FAIL pipes and descriptors" in guest.log(), "pipes, eventfd and descriptor duplication", 120)
        assert re.search(r"pipe-probe: PASS pipes \(EOF, EPIPE, nonblocking, 64 KiB, 1 MiB stream, atomic writes from 4 threads\), "
                         r"eventfd, dup family and 25[0-3] descriptors", guest.log()), guest.log()[-2000:]
        guest.until(lambda: "runtime: PASS epoll, poll and select" in guest.log() or "epoll-probe: FAIL" in guest.log()
                    or "runtime: FAIL readiness" in guest.log(), "epoll, poll and select", 120)
        assert "epoll-probe: PASS level/edge/oneshot, OUT/HUP/ERR, blocking and timed waits, removal on close, eventfd pump, 64 pipes, poll and select" in guest.log(), guest.log()[-2000:]
        guest.until(lambda: "runtime: PASS socket pairs and descriptor passing" in guest.log() or "unix-probe: FAIL" in guest.log()
                    or "runtime: FAIL socket pairs" in guest.log(), "socket pairs and descriptor passing", 120)
        assert ("unix-probe: PASS stream, seqpacket, datagram, SCM_RIGHTS (pipes, shared offsets, CTRUNC, CLOEXEC), "
                "EOF/EPIPE/shutdown, 256 KiB, epoll and 200 descriptor-passing rounds") in guest.log(), guest.log()[-2000:]
        guest.until(lambda: "runtime: PASS posix_spawn, working directories and cross-process descriptors" in guest.log()
                    or "spawn-probe: FAIL" in guest.log() or "runtime: FAIL program launch" in guest.log(),
                    "posix_spawn, working directories and cross-process descriptors", 120)
        assert ("spawn-probe: PASS posix_spawn(p) with argv, env, dup2/close/open/chdir actions and close-on-exec; "
                "stdio pipes; cross-process descriptor passing; waitpid; chdir/fchdir/*at") in guest.log(), guest.log()[-2000:]
        guest.until(lambda: "runtime: PASS lazily backed memory for V8 and PartitionAlloc" in guest.log()
                    or "mmap-probe: FAIL" in guest.log() or "runtime: FAIL lazily backed memory" in guest.log(),
                    "lazily backed memory for V8 and PartitionAlloc", 180)
        assert ("mmap-probe: PASS 16 GiB reservation, mprotect commits, aligned trims, MAP_FIXED(_NOREPLACE), hints, "
                "DONTNEED/FREE, mremap, untouched-page copies and futex, 3 MiB stacks, sparse 256 MiB, W^X") in guest.log(), guest.log()[-2000:]
        guest.until(lambda: "runtime: PASS shared memory and file mappings" in guest.log()
                    or "shm-probe: FAIL" in guest.log() or "runtime: FAIL shared memory" in guest.log(),
                    "shared memory and file mappings", 120)
        assert ("shm-probe: PASS memfd, aliasing shared views, a child sharing a memfd, seals, DONTNEED, "
                "unlinked mappings, MAP_PRIVATE files, pages returned") in guest.log(), guest.log()[-2000:]
        guest.until(lambda: "runtime: PASS randomness and device files" in guest.log()
                    or "random-probe: FAIL" in guest.log() or "runtime: FAIL randomness" in guest.log(),
                    "randomness and device files", 120)
        assert re.search(r"random-probe: PASS getrandom, getentropy, 1 MiB urandom \(chi-square \d+\), /dev/random, "
                         r"/dev/null, /dev/zero, /dev listing", guest.log()), guest.log()[-2000:]
        guest.until(lambda: "runtime: PASS POSIX signals" in guest.log()
                    or "signal-probe: FAIL" in guest.log() or "runtime: FAIL signals" in guest.log(),
                    "POSIX signals", 120)
        assert ("signal-probe: PASS handlers with siginfo, masks and pending, SIG_IGN, SA_RESETHAND, sigaltstack, "
                "SIGSEGV repair, SIGILL rip edit, SIGFPE siglongjmp, EINTR, kill of children, abort") in guest.log(), guest.log()[-2000:]
        guest.until(lambda: "runtime: PASS internet sockets" in guest.log()
                    or "inet-probe: FAIL" in guest.log() or "runtime: FAIL internet sockets" in guest.log(),
                    "internet sockets", 120)
        inet = re.search(r"inet-probe: PASS /etc/hosts and DNS, blocking and nonblocking TCP with epoll, 2 MiB at (\d+) KiB/s, "
                         r"half-close, refused, UDP sendto/recvfrom/connect/MSG_TRUNC, options, refusals", guest.log())
        assert inet, guest.log()[-2000:]
        assert fixture.bulk == 2, fixture.bulk
        print(f"PASS BSD sockets through musl: DNS, TCP (2 MiB at {inet.group(1)} KiB/s), UDP, epoll, refusals", flush=True)
        # WPE WebKit trial probes run only in images built with -Dwpe-probes.
        if os.environ.get("ORANGE_WPE_PROBES") == "1":
            guest.until(lambda: "runtime: PASS GLib, GObject and GIO" in guest.log()
                        or "glib-probe: FAIL" in guest.log() or "runtime: FAIL GLib" in guest.log(),
                        "GLib, GObject and GIO", 180)
            assert re.search(r"glib-probe: PASS GLib 2\.88\.3 strings, Unicode, PCRE2 regex, GVariant, SHA-256, threads, "
                             r"async queue, thread pool, main loop sources and wakeups, GObject signals via libffi, "
                             r"GIO files and streams, zlib, g_spawn", guest.log()), guest.log()[-2000:]
            guest.until(lambda: "runtime: PASS WPE base libraries" in guest.log()
                        or "wpe-libs-probe: FAIL" in guest.log() or "runtime: FAIL WPE libraries" in guest.log(),
                        "WPE base libraries", 240)
            assert ("wpe-libs-probe: PASS PNG, JPEG, WebP, FreeType, HarfBuzz+ICU, fontconfig, WOFF2, ICU locales, "
                    "libxml2, libxslt, SQLite on tmpfs, libgcrypt AES-GCM, libtasn1, brotli, xkbcommon, no EGL") in guest.log(), guest.log()[-2000:]
            guest.until(lambda: "runtime: PASS JavaScriptCore" in guest.log()
                        or "jsc-probe: FAIL" in guest.log() or "runtime: FAIL JavaScriptCore" in guest.log(),
                        "JavaScriptCore", 300)
            jsc = re.search(r"jsc-probe: PASS (\d+) checks \(.*\) in (\d+) ms", guest.log())
            assert jsc and int(jsc.group(1)) == 17, guest.log()[-3000:]
            print(f"PASS JavaScriptCore (LLInt): {jsc.group(1)} checks, workload {jsc.group(2)} ms", flush=True)
            guest.until(lambda: "runtime: PASS HTTPS" in guest.log()
                        or "https-probe: FAIL" in guest.log() or "runtime: FAIL HTTPS" in guest.log(),
                        "HTTPS", 180)
            assert ("https-probe: PASS OpenSSL TLS backend, libsoup GET over TLS with keep-alive, "
                    "certificate verification (unknown CA refused), Mozilla trust store") in guest.log(), guest.log()[-2000:]
            guest.until(lambda: "runtime: PASS WPE WebKit render" in guest.log()
                        or "wpe-render: FAIL" in guest.log() or "runtime: FAIL WPE WebKit render" in guest.log(),
                        "WPE WebKit headless render", 900)
            render = re.search(r"wpe-render: PASS rendered (\S+) at (\d+)x(\d+) on the CPU .*", guest.log())
            assert render, guest.log()[-3000:]
            save_rendered_png(guest.log())
            print(f"PASS WPE WebKit render: {render.group(0)[len('wpe-render: PASS '):]}", flush=True)
        guest.until(lambda: "runtime: PASS concurrent SIMD process isolation" in guest.log(),
                    "twelve native SIMD probes in two concurrent waves", 90)
        masks = [int(mask, 16) for mask in re.findall(r"simd-probe: PASS pid=\d+ cpus=([0-9a-f]+)", guest.log())]
        assert len(masks) == 12, masks
        assert all(mask != 0 for mask in masks)
        combined = 0
        for mask in masks:
            combined |= mask
        cores = guest.profile.cpus
        if combined.bit_count() < min(cores, 2):
            raise AssertionError(f"SIMD probes did not cover both virtual CPUs: {masks}")
        if cores > 1:
            assert any(mask.bit_count() > 1 for mask in masks), f"No SIMD process migrated between CPUs: {masks}"
        assert "simd-probe: FAIL" not in guest.log()
        print(f"PASS eager x87, all sixteen XMM registers, MXCSR and migration; CPU masks={masks}", flush=True)
        guest.until(lambda: "runtime: PASS per-task FS TLS across two CPUs" in guest.log(),
                    "twelve concurrent FS-base TLS probes", 90)
        tls_masks = [int(mask, 16) for mask in re.findall(r"tls-probe: PASS pid=\d+ cpus=([0-9a-f]+)", guest.log())]
        assert len(tls_masks) == 12, tls_masks
        combined_tls = 0
        for mask in tls_masks:
            combined_tls |= mask
        assert combined_tls.bit_count() >= min(cores, 2), tls_masks
        if cores > 1:
            assert any(mask.bit_count() > 1 for mask in tls_masks), f"TLS probes did not migrate: {tls_masks}"
        print(f"PASS FS-base isolation, invalid-address rejection and migration; CPU masks={tls_masks}", flush=True)
        guest.until(lambda: "runtime: PASS 24 shared-word wait/wake process cycles" in guest.log(),
                    "shared-frame wait/wake lifecycle stress", 90)
        assert guest.log().count("futex-probe: PASS shared-frame wake-one, timeout and validation") == 24
        guest.until(lambda: "runtime: PASS freestanding C floating-point ABI" in guest.log(),
                    "four concurrent compiler-generated C/Zig floating-point probes", 90)
        assert guest.log().count("c-abi-probe: PASS") == 4
        guest.until(lambda: "runtime: PASS freestanding C++ language ABI" in guest.log(),
                    "four concurrent native C++ ABI probes", 90)
        assert guest.log().count("cxx-abi-probe: PASS") == 4
        guest.until(lambda: "runtime: PASS multi-threaded programs" in guest.log(),
                    "eight multi-threaded programs, two at a time", 180)
        thread_masks = [int(mask, 16) for mask in re.findall(r"thread-probe: PASS pid=\d+ threads=5 cpus=([0-9a-f]+)", guest.log())]
        assert len(thread_masks) == 8, thread_masks
        combined_threads = 0
        for mask in thread_masks:
            combined_threads |= mask
        assert combined_threads.bit_count() >= min(cores, 2), thread_masks
        print(f"PASS threads share memory, mutex and VM across CPUs; CPU masks={thread_masks}", flush=True)
        guest.until(lambda: "runtime: PASS program exit ends futex, port, console, wait, sleeping and spinning threads" in guest.log(),
                    "program exit ends every blocked, sleeping and spinning thread", 90)
        guest.until(lambda: "runtime: PASS a faulting thread ends its whole program" in guest.log(),
                    "a faulting thread ends its program", 60)
        assert guest.log().count("[app fault]") == 9, guest.log().count("[app fault]")
        guest.until(lambda: "runtime: PASS a program outlives its first thread" in guest.log(),
                    "the last thread's status becomes the program's", 60)
        guest.until(lambda: "runtime: PASS threads share the network stack" in guest.log(),
                    "threads share the network stack; long waits accept shootdowns", 120)
        assert guest.log().count("net-thread-probe: PASS 24/24 concurrent pings") == 2, guest.log()[-1500:]
        unmaps = re.findall(r"UDP churn, (\d+) unmaps during a 3 s network wait", guest.log())
        print(f"PASS concurrent pings and UDP churn; unmaps during network waits: {unmaps}", flush=True)
        guest.until(lambda: "runtime: PASS program exit interrupts a network wait" in guest.log(),
                    "program exit interrupts a network wait", 60)
        guest.until(lambda: "runtime: TCP probes finished" in guest.log(), "concurrent TCP fetches from the host fixture", 90)
        assert guest.log().count("tcp-probe: PASS 2 threads each fetched 6000 verified bytes concurrently") == 2, guest.log()[-1500:]
        assert fixture.served == 4, fixture.served
        print("PASS two threads fetch verified payloads over concurrent TCP connections, twice", flush=True)
        guest.until(lambda: "runtime: PASS 300 child reaps, slot reuse and wait ownership" in guest.log(),
                    "300 child reaps, slot reuse and wait ownership", 240)
        guest.until(lambda: "runtime: PASS full task table rejects spawn and recovers after reaping" in guest.log(),
                    "full task table rejects spawn and recovers after reaping", 240)
        parent_exits = args.orphan_waves * 12
        guest.until(lambda: f"runtime: PASS orphan children are collected across {parent_exits} parent exits" in guest.log(),
                    f"orphan cleanup across {parent_exits} exiting parents", max(90, args.orphan_waves * 2))
        guest.until(lambda: "runtime: PASS private file descriptors and 96 exit cleanups" in guest.log(),
                    "file descriptor isolation and exit cleanup", 90)
        guest.until(lambda: "runtime: PASS private UDP sockets and 48 exit cleanups" in guest.log(),
                    "UDP socket isolation and exit cleanup", 90)
        guest.until(lambda: "runtime: PASS 96 IPC registry reuse, mappings and exit cleanups" in guest.log(),
                    "IPC object ownership and exit cleanup", 90)
        guest.until(lambda: '"Welcome"' in guest.log() and "squeeze: window" in guest.log(),
                    "desktop starts after runtime stress", 60)
        guest.screenshot("runtime-desktop")
    except AssertionError:
        try:
            print(f"QEMU CPUs at failure:\n{guest.monitor('info cpus')}", flush=True)
            print(f"QEMU selected CPU registers:\n{guest.monitor('info registers')[:1200]}", flush=True)
        except (OSError, RuntimeError) as error:
            print(f"QEMU CPU state unavailable: {error}", flush=True)
        raise
    finally:
        guest.close()
        fixture.shutdown()
        udp_fixture.shutdown()
        if https_fixture:
            https_fixture.shutdown()
        fixture.server_close()


if __name__ == "__main__":
    main()
