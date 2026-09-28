/* data-probe: /data survives a reboot (docs/design/013).
 *
 * tools/data_volume_smoke.py boots the same data disk several times with
 * this probe started at boot. The first boot finds /data empty and saves a
 * tree: a 3 MiB patterned file, a sparse file, nested directories, a file
 * renamed into place and one removed, then fsync. Each later boot checks
 * everything the previous boot left, counts the boot in /data/probe/boots,
 * and saves again. It also checks what must not work: renaming between
 * /tmp and /data, which are separate volumes.
 *
 * SPDX-License-Identifier: MIT OR Apache-2.0
 */
#define _DEFAULT_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define CHECK(condition, what)                                                   \
	do {                                                                         \
		if (!(condition)) {                                                      \
			printf("data-probe: FAIL %s (errno %d)\n", (what), errno);           \
			return 1;                                                            \
		}                                                                        \
	} while (0)

#define BIG (3 * 1024 * 1024)

static unsigned char pattern(size_t i, unsigned boot)
{
	return (unsigned char)(i * 131 + 7 + boot);
}

static int write_file(const char *path, const void *data, size_t length)
{
	int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
	if (fd < 0)
		return -1;
	size_t done = 0;
	while (done < length) {
		ssize_t n = write(fd, (const char *)data + done, length - done);
		if (n <= 0) {
			close(fd);
			return -1;
		}
		done += (size_t)n;
	}
	int saved = fsync(fd);
	close(fd);
	return saved;
}

static long read_file(const char *path, void *data, size_t capacity)
{
	int fd = open(path, O_RDONLY);
	if (fd < 0)
		return -1;
	size_t done = 0;
	for (;;) {
		ssize_t n = read(fd, (char *)data + done, capacity - done);
		if (n < 0) {
			close(fd);
			return -1;
		}
		if (n == 0)
			break;
		done += (size_t)n;
	}
	close(fd);
	return (long)done;
}

/* What boot `boot` saves; the next boot checks it. */
static int save(unsigned boot, unsigned char *big)
{
	CHECK(mkdir("/data/probe", 0755) == 0 || errno == EEXIST, "mkdir /data/probe");
	CHECK(mkdir("/data/probe/a", 0755) == 0 || errno == EEXIST, "mkdir /data/probe/a");
	CHECK(mkdir("/data/probe/a/b", 0755) == 0 || errno == EEXIST, "mkdir /data/probe/a/b");
	for (size_t i = 0; i < BIG; i++)
		big[i] = pattern(i, boot);
	CHECK(write_file("/data/probe/a/b/big.bin", big, BIG) == 0, "write and fsync the 3 MiB file");

	/* A sparse file: 1 MiB hole, then 5 bytes. */
	int fd = open("/data/probe/sparse", O_WRONLY | O_CREAT | O_TRUNC, 0644);
	CHECK(fd >= 0, "create the sparse file");
	CHECK(pwrite(fd, "tail!", 5, 1 << 20) == 5, "write past a hole");
	CHECK(fsync(fd) == 0, "fsync the sparse file");
	close(fd);

	/* Replaced atomically, as SQLite and editors do. */
	char text[32];
	int length = snprintf(text, sizeof text, "%u\n", boot);
	CHECK(write_file("/data/probe/boots.new", text, (size_t)length) == 0, "write the new count");
	CHECK(rename("/data/probe/boots.new", "/data/probe/boots") == 0, "rename it into place");
	CHECK(write_file("/data/probe/gone", "x", 1) == 0 && unlink("/data/probe/gone") == 0, "a removed file");
	sync();
	return 0;
}

int main(void)
{
	struct stat status;
	if (stat("/data", &status) != 0 || access("/data", W_OK) != 0) {
		printf("data-probe: FAIL /data is not a writable volume (errno %d)\n", errno);
		return 1;
	}
	unsigned char *big = malloc(BIG), *back = malloc(BIG + 1);
	CHECK(big && back, "memory");

	/* Separate volumes. */
	CHECK(write_file("/tmp/data-probe", "t", 1) == 0, "a /tmp file");
	errno = 0;
	CHECK(rename("/tmp/data-probe", "/data/data-probe") == -1 && errno == EXDEV, "rename /tmp -> /data is EXDEV");

	char text[32] = { 0 };
	long n = read_file("/data/probe/boots", text, sizeof text - 1);
	if (n < 0) {
		CHECK(errno == ENOENT, "an empty volume has no count");
		if (save(1, big))
			return 1;
		printf("data-probe: PASS empty /data; saved boot 1\n");
		return 0;
	}
	unsigned boot = (unsigned)strtoul(text, NULL, 10);
	CHECK(boot >= 1, "a saved count");

	CHECK(read_file("/data/probe/a/b/big.bin", back, BIG + 1) == BIG, "the 3 MiB file is there, its size unchanged");
	for (size_t i = 0; i < BIG; i++)
		if (back[i] != pattern(i, boot)) {
			printf("data-probe: FAIL byte %zu of big.bin\n", i);
			return 1;
		}
	CHECK(stat("/data/probe/sparse", &status) == 0 && status.st_size == (1 << 20) + 5, "the sparse file's size");
	int fd = open("/data/probe/sparse", O_RDONLY);
	CHECK(fd >= 0, "open the sparse file");
	CHECK(pread(fd, back, 4096, 4096) == 4096, "read inside the hole");
	for (int i = 0; i < 4096; i++)
		CHECK(back[i] == 0, "the hole reads as zeros");
	CHECK(pread(fd, back, 5, 1 << 20) == 5 && memcmp(back, "tail!", 5) == 0, "the bytes after the hole");
	close(fd);
	CHECK(access("/data/probe/gone", F_OK) == -1 && errno == ENOENT, "the removed file stays removed");
	CHECK(access("/data/probe/boots.new", F_OK) == -1 && errno == ENOENT, "the renamed file is only at its new name");

	if (save(boot + 1, big))
		return 1;
	printf("data-probe: PASS found boot %u's files; saved boot %u\n", boot, boot + 1);
	return 0;
}
