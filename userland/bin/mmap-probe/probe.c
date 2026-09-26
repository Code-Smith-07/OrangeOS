/* Memory the way V8, PartitionAlloc and musl use it, through musl on
 * OrangeOS: huge PROT_NONE reservations committed by mprotect, aligned
 * reservations trimmed with munmap, MAP_FIXED and MAP_FIXED_NOREPLACE inside
 * them, hints, contents kept across protection changes, MADV_DONTNEED and
 * MADV_FREE zeroing, mremap shrink/grow/move, kernel copies and futex waits
 * on untouched pages, a deep main-thread stack, a big thread stack, sparse
 * large allocations, W^X code, and munmap across holes.
 *
 * SPDX-License-Identifier: MIT OR Apache-2.0
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

#define CHECK(condition, what)                                                   \
	do {                                                                         \
		if (!(condition)) {                                                      \
			printf("mmap-probe: FAIL %s (errno %d)\n", (what), errno);           \
			return 1;                                                            \
		}                                                                        \
	} while (0)

#define FUTEX_WAIT 0 /* <linux/futex.h> */
#define PAGE 4096UL
#define GiB (1024UL * 1024 * 1024)
#define MiB (1024UL * 1024)

/* Uses about 3 MiB of stack, well past the old 256 KiB. */
static int __attribute__((noinline)) deep(int depth)
{
	volatile char frame[4000];
	frame[0] = (char)depth;
	frame[sizeof frame - 1] = (char)depth;
	if (depth == 0)
		return frame[0];
	return deep(depth - 1) + frame[sizeof frame - 1] - (char)depth;
}

static void *big_stack(void *unused)
{
	(void)unused;
	volatile char buffer[3 * MiB];
	for (size_t i = 0; i < sizeof buffer; i += PAGE)
		buffer[i] = (char)i;
	return (void *)(long)buffer[PAGE];
}

int main(void)
{
	/* A 16 GiB reservation (V8's cage is 4 GiB), committed piecewise. */
	size_t cage = 16 * GiB;
	char *reserved = mmap(NULL, cage, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
	CHECK(reserved != MAP_FAILED, "16 GiB PROT_NONE reservation");
	char *chunk = reserved + 5 * GiB;
	CHECK(mprotect(chunk, 2 * MiB, PROT_READ | PROT_WRITE) == 0, "commit by mprotect");
	CHECK(chunk[0] == 0 && chunk[2 * MiB - 1] == 0, "committed pages read zero");
	memset(chunk, 0x5a, 2 * MiB);
	CHECK(chunk[123456] == 0x5a, "committed pages hold data");

	/* Contents survive PROT_NONE and back, as a JIT's pages must. */
	CHECK(mprotect(chunk, 2 * MiB, PROT_NONE) == 0 && mprotect(chunk, 2 * MiB, PROT_READ) == 0, "protection round trip");
	CHECK(chunk[2 * MiB - 1] == 0x5a, "contents kept across protection changes");
	CHECK(mprotect(chunk, 2 * MiB, PROT_READ | PROT_WRITE) == 0, "writable again");

	/* MAP_FIXED inside the reservation replaces what was there. */
	char *fixed = mmap(chunk + PAGE, PAGE, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED, -1, 0);
	CHECK(fixed == chunk + PAGE && fixed[0] == 0 && chunk[0] == 0x5a && chunk[2 * PAGE] == 0x5a, "MAP_FIXED replaces one page");
	errno = 0;
	CHECK(mmap(chunk, PAGE, PROT_READ, MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED_NOREPLACE, -1, 0) == MAP_FAILED && errno == EEXIST, "MAP_FIXED_NOREPLACE refuses");
	CHECK(munmap(reserved, cage) == 0, "release the reservation");

	/* Aligned reservation: over-reserve, then trim both ends. */
	size_t align = 4 * GiB, want = 4 * GiB;
	char *raw = mmap(NULL, want + align, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	CHECK(raw != MAP_FAILED, "over-reservation");
	char *aligned = (char *)(((uintptr_t)raw + align - 1) & ~(uintptr_t)(align - 1));
	if (aligned > raw)
		CHECK(munmap(raw, aligned - raw) == 0, "trim head");
	CHECK(munmap(aligned + want, raw + want + align - (aligned + want)) == 0, "trim tail");
	CHECK(((uintptr_t)aligned & (align - 1)) == 0, "4 GiB aligned");
	CHECK(mprotect(aligned, PAGE, PROT_READ | PROT_WRITE) == 0 && (aligned[0] = 1) == 1, "use the aligned reservation");
	CHECK(munmap(aligned, want) == 0, "release it");

	/* A free hint is honoured; a taken one is not. */
	char *hinted = mmap(aligned, 64 * PAGE, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	CHECK(hinted == aligned, "free hint honoured");
	char *elsewhere = mmap(aligned, PAGE, PROT_READ, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	CHECK(elsewhere != MAP_FAILED && elsewhere != aligned, "taken hint placed elsewhere");
	munmap(elsewhere, PAGE);

	/* MADV_DONTNEED and MADV_FREE: zeros afterwards. */
	memset(hinted, 0x77, 64 * PAGE);
	CHECK(madvise(hinted, 32 * PAGE, MADV_DONTNEED) == 0 && hinted[0] == 0 && hinted[32 * PAGE - 1] == 0 && hinted[32 * PAGE] == 0x77, "MADV_DONTNEED");
	CHECK(madvise(hinted + 32 * PAGE, 32 * PAGE, MADV_FREE) == 0 && hinted[40 * PAGE] == 0, "MADV_FREE");
	CHECK(madvise(hinted, PAGE, MADV_WILLNEED) == 0, "other advice accepted");

	/* mremap: shrink, grow in place, and move with the contents. */
	memset(hinted, 0x11, 64 * PAGE);
	CHECK(mremap(hinted, 64 * PAGE, 16 * PAGE, 0) == hinted, "shrink in place");
	CHECK(mremap(hinted, 16 * PAGE, 48 * PAGE, 0) == hinted && hinted[20 * PAGE] == 0 && hinted[15 * PAGE] == 0x11, "grow in place");
	char *blocker = mmap(hinted + 48 * PAGE, PAGE, PROT_READ, MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED_NOREPLACE, -1, 0);
	CHECK(blocker == hinted + 48 * PAGE, "block growth");
	errno = 0;
	CHECK(mremap(hinted, 48 * PAGE, 96 * PAGE, 0) == MAP_FAILED && errno == ENOMEM, "cannot grow in place");
	char *moved = mremap(hinted, 48 * PAGE, 96 * PAGE, MREMAP_MAYMOVE);
	CHECK(moved != MAP_FAILED && moved != hinted && moved[0] == 0x11 && moved[15 * PAGE] == 0x11 && moved[90 * PAGE] == 0, "moved with contents");
	munmap(blocker, PAGE);
	munmap(moved, 96 * PAGE);

	/* Kernel copies and futex waits on pages never touched. */
	char *fresh = mmap(NULL, 4 * PAGE, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	int motd = open("/etc/motd", O_RDONLY);
	CHECK(read(motd, fresh + PAGE, 7) == 7 && memcmp(fresh + PAGE, "Welcome", 7) == 0, "read() into an untouched page");
	close(motd);
	int p[2];
	CHECK(pipe(p) == 0 && write(p[1], fresh + 2 * PAGE, 16) == 16, "write() from an untouched page");
	close(p[0]);
	close(p[1]);
	struct timespec brief = { 0, 20 * 1000 * 1000 };
	errno = 0;
	CHECK(syscall(SYS_futex, (int *)(fresh + 3 * PAGE), FUTEX_WAIT, 0, &brief) == -1 && errno == ETIMEDOUT, "futex wait on an untouched page");
	munmap(fresh, 4 * PAGE);

	/* munmap across several mappings and the holes between them. */
	char *a = mmap(NULL, 3 * PAGE, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	CHECK(munmap(a + PAGE, PAGE) == 0 && munmap(a, 3 * PAGE) == 0, "munmap over a hole");

	/* Stacks: 3 MiB on the main thread and on a thread with a 4 MiB stack. */
	CHECK(deep(750) == 0, "deep recursion on the main thread");
	pthread_attr_t attributes;
	pthread_attr_init(&attributes);
	pthread_attr_setstacksize(&attributes, 4 * MiB);
	pthread_t thread;
	void *result;
	CHECK(pthread_create(&thread, &attributes, big_stack, NULL) == 0 && pthread_join(thread, &result) == 0, "big thread stack");

	/* A 256 MiB allocation touched sparsely costs only what is touched. */
	char *big = malloc(256 * MiB);
	CHECK(big != NULL, "256 MiB malloc");
	for (size_t i = 0; i < 256 * MiB; i += 16 * MiB)
		big[i] = 1;
	free(big);
	char *zeroed = calloc(64, MiB);
	CHECK(zeroed && zeroed[63 * MiB] == 0, "calloc of lazily backed memory");
	free(zeroed);

	/* W^X code in lazily backed memory. */
	unsigned char *code = mmap(NULL, PAGE, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	const unsigned char body[] = { 0xb8, 42, 0, 0, 0, 0xc3 }; /* mov eax, 42; ret */
	memcpy(code, body, sizeof body);
	CHECK(mprotect(code, PAGE, PROT_READ | PROT_EXEC) == 0, "flip to executable");
	int (*function)(void) = (int (*)(void))(void *)code;
	CHECK(function() == 42, "run generated code");
	errno = 0;
	CHECK(mprotect(code, PAGE, PROT_READ | PROT_WRITE | PROT_EXEC) == -1, "writable and executable refused");
	munmap(code, PAGE);

	printf("mmap-probe: PASS 16 GiB reservation, mprotect commits, aligned trims, MAP_FIXED(_NOREPLACE), hints, "
	       "DONTNEED/FREE, mremap, untouched-page copies and futex, 3 MiB stacks, sparse 256 MiB, W^X\n");
	return 0;
}
