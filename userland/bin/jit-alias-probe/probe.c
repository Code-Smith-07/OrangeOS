/* jit-alias-probe: the executable memory OrangeOS gives JavaScriptCore's JIT
 * (docs/design/012 §4.5), done the way JSC does it.
 *
 * JSC reserves its JIT pool, then (patch 0008) maps one memfd over it
 * read/execute and a second time elsewhere read/write, and writes all code
 * through the second mapping. No page is ever writable and executable in the
 * same mapping, so W^X holds. This probe checks each step against the
 * kernel: the reservation, the two mappings of a sparse 256 MiB memfd, code
 * written through one alias and run through the other, re-patching while a
 * second thread runs the code, MADV_DONTNEED keeping shared contents, and
 * writable+executable still refused.
 *
 * SPDX-License-Identifier: MIT OR Apache-2.0
 */
#define _GNU_SOURCE
#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#define CHECK(condition, what)                                                   \
	do {                                                                         \
		if (!(condition)) {                                                      \
			printf("jit-alias-probe: FAIL %s (errno %d)\n", (what), errno);      \
			return 1;                                                            \
		}                                                                        \
	} while (0)

#define POOL (256UL << 20)
#define PAGE 4096UL
#define ROUNDS 200

typedef uint32_t (*function)(void);

static uint8_t *exec_base;
static uint8_t *write_base;
static _Atomic uint32_t phase;
static _Atomic uint32_t seen;
static _Atomic int failed;

/* mov eax, imm32; ret */
static void emit(uint8_t *code, uint32_t value)
{
	uint8_t bytes[6] = { 0xB8, 0, 0, 0, 0, 0xC3 };
	memcpy(bytes + 1, &value, 4);
	memcpy(code, bytes, sizeof bytes);
}

/* Cross-modifying code: the thread that runs new code serializes after it
 * learns the code changed and before it runs it (Intel SDM 8.1.3). */
static void serialize(void)
{
	uint32_t a = 0, b, c = 0, d;
	__asm__ volatile("cpuid" : "+a"(a), "=b"(b), "+c"(c), "=d"(d) : : "memory");
}

static void *runner(void *unused)
{
	(void)unused;
	function run = (function)(void *)(exec_base + 8 * PAGE);
	uint32_t last = 0;
	for (;;) {
		uint32_t p = atomic_load(&phase);
		if (p == UINT32_MAX)
			return NULL;
		if (p == last) {
			sched_yield();
			continue;
		}
		serialize();
		if (run() != p)
			atomic_store(&failed, 1);
		last = p;
		atomic_store(&seen, p);
	}
}

int main(void)
{
	/* JSC's reservation: read/execute, no pages yet (MAP_NORESERVE and
	 * MADV_DONTNEED), with a guard page on each side. */
	uint8_t *reservation = mmap(NULL, POOL + 2 * PAGE, PROT_READ | PROT_EXEC, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
	CHECK(reservation != MAP_FAILED, "reserve the pool read/execute");
	CHECK(mmap(reservation, PAGE, PROT_NONE, MAP_FIXED | MAP_PRIVATE | MAP_ANONYMOUS, -1, 0) == reservation, "front guard page");
	CHECK(mmap(reservation + PAGE + POOL, PAGE, PROT_NONE, MAP_FIXED | MAP_PRIVATE | MAP_ANONYMOUS, -1, 0) == reservation + PAGE + POOL, "back guard page");
	CHECK(madvise(reservation + PAGE, POOL, MADV_DONTNEED) == 0, "decommit the reservation");

	/* The aliases. The first pool page stays reserved, as in JSC. */
	size_t size = POOL - PAGE;
	int fd = memfd_create("jsc-jit", MFD_CLOEXEC);
	CHECK(fd >= 0, "memfd_create");
	CHECK(ftruncate(fd, (off_t)size) == 0, "size the memfd (sparse)");
	exec_base = mmap(reservation + 2 * PAGE, size, PROT_READ | PROT_EXEC, MAP_SHARED | MAP_FIXED, fd, 0);
	CHECK(exec_base == reservation + 2 * PAGE, "map the memfd read/execute over the pool");
	write_base = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	CHECK(write_base != MAP_FAILED, "map the memfd read/write elsewhere");
	CHECK(close(fd) == 0, "close the memfd; the mappings keep it");

	/* Code written through one alias runs through the other. */
	emit(write_base + 8 * PAGE, 42);
	function run = (function)(void *)(exec_base + 8 * PAGE);
	CHECK(run() == 42, "code written read/write runs read/execute");
	emit(write_base + size - PAGE, 7);
	CHECK(((function)(void *)(exec_base + size - PAGE))() == 7, "the last pool page");

	/* W^X is unchanged: neither alias may become writable+executable, and
	 * the executable one cannot be written. */
	errno = 0;
	CHECK(mprotect(exec_base, PAGE, PROT_READ | PROT_WRITE | PROT_EXEC) == -1, "RWX refused on the executable alias");
	errno = 0;
	CHECK(mprotect(write_base, PAGE, PROT_READ | PROT_WRITE | PROT_EXEC) == -1, "RWX refused on the writable alias");
	errno = 0;
	CHECK(mmap(NULL, PAGE, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0) == MAP_FAILED, "RWX anonymous memory refused");

	/* Re-patching while another thread runs the code. */
	pthread_t thread;
	atomic_store(&phase, 0);
	CHECK(pthread_create(&thread, NULL, runner, NULL) == 0, "runner thread");
	for (uint32_t round = 1; round <= ROUNDS; round++) {
		emit(write_base + 8 * PAGE, round);
		atomic_store(&phase, round);
		while (atomic_load(&seen) != round && !atomic_load(&failed))
			sched_yield();
		CHECK(!atomic_load(&failed), "the other thread runs each new version");
		serialize();
		CHECK(run() == round, "this thread runs each new version");
	}
	atomic_store(&phase, UINT32_MAX);
	CHECK(pthread_join(thread, NULL) == 0, "join");

	/* libpas decommits JIT pages with MADV_DONTNEED: for shared memory the
	 * contents stay in the memfd and come back on the next touch. */
	CHECK(madvise(exec_base, 16 * PAGE, MADV_DONTNEED) == 0, "decommit JIT pages");
	CHECK(madvise(write_base, 16 * PAGE, MADV_DONTNEED) == 0, "decommit the writable alias");
	CHECK(run() == ROUNDS, "code survives decommit");

	CHECK(munmap(write_base, size) == 0 && munmap(exec_base, size) == 0, "unmap both aliases");
	printf("jit-alias-probe: PASS 256 MiB memfd mapped read/execute and read/write, %d re-patches run on two threads, "
	       "decommit keeps code, RWX refused\n",
	       ROUNDS);
	return 0;
}
