/* Writable files through musl on OrangeOS's in-memory /tmp: stdio writes and
 * appends, positioned I/O, truncation, rename, unlink while open, directory
 * listing, capacity reporting, the errors POSIX requires, concurrent writers
 * and appenders, and every page returned once the files are gone.
 *
 * SPDX-License-Identifier: MIT OR Apache-2.0
 */
#define _POSIX_C_SOURCE 200809L
#define _DEFAULT_SOURCE /* d_type and DT_* */
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <unistd.h>

#define CHECK(condition, what)                                                   \
	do {                                                                         \
		if (!(condition)) {                                                      \
			printf("file-probe: FAIL %s (errno %d)\n", (what), errno);           \
			return 1;                                                            \
		}                                                                        \
	} while (0)

enum { LINES = 20000, WRITERS = 4, WRITER_BYTES = 64 * 1024, APPENDERS = 2, RECORDS = 1000, RECORD_BYTES = 24 };

static long file_size(const char *path)
{
	struct stat status;
	return stat(path, &status) == 0 ? (long)status.st_size : -1;
}

static void *writer(void *argument)
{
	long id = (long)argument;
	char path[64], block[4096];
	snprintf(path, sizeof path, "/tmp/probe/writer-%ld", id);
	int fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0644);
	if (fd < 0)
		return (void *)1;
	memset(block, 'A' + (int)id, sizeof block);
	for (int done = 0; done < WRITER_BYTES; done += (int)sizeof block)
		if (write(fd, block, sizeof block) != (ssize_t)sizeof block)
			return (void *)2;
	return close(fd) == 0 ? NULL : (void *)3;
}

static void *appender(void *argument)
{
	long id = (long)argument;
	int fd = open("/tmp/probe/log", O_WRONLY | O_APPEND);
	if (fd < 0)
		return (void *)1;
	char record[32];
	for (int i = 0; i < RECORDS; i++) {
		/* Fixed-size records: each append is one write, and none may tear. */
		if (snprintf(record, sizeof record, "appender %ld record %05d\n", id, i) != RECORD_BYTES)
			return (void *)4;
		if (write(fd, record, RECORD_BYTES) != RECORD_BYTES)
			return (void *)2;
	}
	return close(fd) == 0 ? NULL : (void *)3;
}

int main(void)
{
	struct statvfs tmp_before, root;
	CHECK(statvfs("/tmp", &tmp_before) == 0 && !(tmp_before.f_flag & ST_RDONLY) && tmp_before.f_bfree > 0, "statvfs /tmp");
	CHECK(statvfs("/", &root) == 0 && (root.f_flag & ST_RDONLY), "statvfs / is read-only");
	CHECK(access("/tmp", W_OK) == 0, "access /tmp W_OK");
	errno = 0;
	CHECK(access("/etc", W_OK) == -1 && errno == EROFS, "access /etc W_OK");

	CHECK(mkdir("/tmp/probe", 0755) == 0, "mkdir");
	errno = 0;
	CHECK(mkdir("/tmp/probe", 0755) == -1 && errno == EEXIST, "mkdir existing");

	/* A 20,000-line file through stdio, read back line by line. */
	FILE *out = fopen("/tmp/probe/data.txt", "w");
	CHECK(out != NULL, "fopen w");
	long expected = 0;
	for (int i = 0; i < LINES; i++)
		expected += fprintf(out, "line %d of the probe file\n", i);
	CHECK(fclose(out) == 0 && file_size("/tmp/probe/data.txt") == expected, "write and size");
	FILE *in = fopen("/tmp/probe/data.txt", "r");
	CHECK(in != NULL, "fopen r");
	char line[64], want[64];
	for (int i = 0; i < LINES; i++) {
		snprintf(want, sizeof want, "line %d of the probe file\n", i);
		CHECK(fgets(line, sizeof line, in) && strcmp(line, want) == 0, "read back");
	}
	CHECK(fgets(line, sizeof line, in) == NULL && feof(in), "end of file");
	fclose(in);

	FILE *append = fopen("/tmp/probe/data.txt", "a");
	CHECK(append && fputs("appended\n", append) >= 0 && fclose(append) == 0, "append");
	CHECK(file_size("/tmp/probe/data.txt") == expected + 9, "append size");

	/* Positioned I/O leaves the descriptor offset alone. */
	int fd = open("/tmp/probe/data.txt", O_RDWR);
	CHECK(fd >= 0 && (fcntl(fd, F_GETFL) & O_ACCMODE) == O_RDWR, "open O_RDWR");
	CHECK(pwrite(fd, "LINE", 4, 0) == 4, "pwrite");
	char head[8] = { 0 };
	CHECK(pread(fd, head, 7, 0) == 7 && strcmp(head, "LINE 0 ") == 0, "pread");
	CHECK(lseek(fd, 0, SEEK_CUR) == 0, "offset untouched");
	CHECK(lseek(fd, -9, SEEK_END) == expected && read(fd, line, 9) == 9 && memcmp(line, "appended\n", 9) == 0, "seek end");

	/* Shrink, then grow: the regrown range reads as zeros. */
	CHECK(ftruncate(fd, 10) == 0 && file_size("/tmp/probe/data.txt") == 10, "shrink");
	CHECK(ftruncate(fd, 8192) == 0 && file_size("/tmp/probe/data.txt") == 8192, "grow");
	char block[8192];
	CHECK(pread(fd, block, 4096, 0) == 4096 && pread(fd, block + 4096, 4096, 4096) == 4096, "read grown");
	int zeros = 1;
	for (int i = 10; i < 8192; i++)
		zeros &= block[i] == 0;
	CHECK(zeros && memcmp(block, "LINE 0 of ", 10) == 0, "grown range is zero");
	CHECK(close(fd) == 0, "close");

	/* Rename, including over an existing file. */
	CHECK(rename("/tmp/probe/data.txt", "/tmp/probe/moved.txt") == 0, "rename");
	errno = 0;
	CHECK(file_size("/tmp/probe/data.txt") == -1 && errno == ENOENT, "old name gone");
	FILE *other = fopen("/tmp/probe/other.txt", "w");
	CHECK(other && fputs("other\n", other) >= 0 && fclose(other) == 0, "second file");
	CHECK(rename("/tmp/probe/other.txt", "/tmp/probe/moved.txt") == 0 && file_size("/tmp/probe/moved.txt") == 6, "rename replaces");

	/* An unlinked file stays usable through a descriptor already open. */
	fd = open("/tmp/probe/moved.txt", O_RDONLY);
	CHECK(fd >= 0 && unlink("/tmp/probe/moved.txt") == 0, "unlink open file");
	CHECK(read(fd, line, 6) == 6 && memcmp(line, "other\n", 6) == 0, "read after unlink");
	close(fd);

	/* Concurrent writers each fill their own file; appenders share one. */
	CHECK(close(open("/tmp/probe/log", O_WRONLY | O_CREAT, 0644)) == 0, "create log");
	pthread_t threads[WRITERS + APPENDERS];
	for (long i = 0; i < WRITERS; i++)
		CHECK(pthread_create(&threads[i], NULL, writer, (void *)i) == 0, "writer thread");
	for (long i = 0; i < APPENDERS; i++)
		CHECK(pthread_create(&threads[WRITERS + i], NULL, appender, (void *)i) == 0, "appender thread");
	for (int i = 0; i < WRITERS + APPENDERS; i++) {
		void *result;
		CHECK(pthread_join(threads[i], &result) == 0 && result == NULL, "thread result");
	}
	for (long i = 0; i < WRITERS; i++) {
		char path[64];
		snprintf(path, sizeof path, "/tmp/probe/writer-%ld", i);
		CHECK(file_size(path) == WRITER_BYTES, "writer size");
		FILE *check = fopen(path, "r");
		int intact = check != NULL, c;
		while (intact && (c = fgetc(check)) != EOF)
			intact = c == 'A' + i;
		CHECK(intact && fclose(check) == 0, "writer contents");
	}
	CHECK(file_size("/tmp/probe/log") == APPENDERS * RECORDS * RECORD_BYTES, "log size");
	FILE *log = fopen("/tmp/probe/log", "r");
	CHECK(log != NULL, "open log");
	int next[APPENDERS] = { 0 };
	long id;
	int record;
	while (fgets(line, sizeof line, log)) {
		CHECK(sscanf(line, "appender %ld record %d", &id, &record) == 2 && id >= 0 && id < APPENDERS, "record intact");
		CHECK(record == next[id]++, "records in order per appender");
	}
	fclose(log);

	/* The listing names exactly what is there. */
	DIR *dir = opendir("/tmp/probe");
	CHECK(dir != NULL, "opendir");
	int seen = 0;
	struct dirent *entry;
	while ((entry = readdir(dir))) {
		if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0)
			continue;
		CHECK(entry->d_type == DT_REG, "entry type");
		CHECK(strcmp(entry->d_name, "log") == 0 || strncmp(entry->d_name, "writer-", 7) == 0, "entry name");
		seen++;
	}
	rewinddir(dir);
	int again = 0;
	while (readdir(dir))
		again++;
	closedir(dir);
	CHECK(seen == WRITERS + 1 && again == seen + 2, "listing and rewind");

	/* The errors POSIX requires. */
	errno = 0;
	CHECK(rmdir("/tmp/probe") == -1 && errno == ENOTEMPTY, "rmdir non-empty");
	errno = 0;
	CHECK(unlink("/tmp/probe") == -1 && errno == EISDIR, "unlink directory");
	errno = 0;
	CHECK(rmdir("/tmp/probe/log") == -1 && errno == ENOTDIR, "rmdir file");
	errno = 0;
	CHECK(open("/tmp/probe/log", O_WRONLY | O_CREAT | O_EXCL, 0644) == -1 && errno == EEXIST, "O_EXCL");
	errno = 0;
	CHECK(fopen("/etc/new", "w") == NULL && errno == EROFS, "create on read-only root");
	errno = 0;
	CHECK(unlink("/etc/motd") == -1 && errno == EROFS, "unlink on read-only root");
	errno = 0;
	CHECK(rename("/tmp/probe/log", "/etc/log") == -1 && errno == EXDEV, "rename across filesystems");
	errno = 0;
	CHECK(rmdir("/tmp") == -1 && errno == EBUSY, "rmdir mount point");

	/* Remove everything; the space comes back. */
	for (long i = 0; i < WRITERS; i++) {
		char path[64];
		snprintf(path, sizeof path, "/tmp/probe/writer-%ld", i);
		CHECK(unlink(path) == 0, "unlink writer");
	}
	CHECK(unlink("/tmp/probe/log") == 0 && rmdir("/tmp/probe") == 0, "cleanup");
	struct statvfs tmp_after;
	CHECK(statvfs("/tmp", &tmp_after) == 0 && tmp_after.f_bfree == tmp_before.f_bfree, "space returned");

	printf("file-probe: PASS stdio, pread/pwrite, truncate, rename, unlink-while-open, readdir, errors, "
	       "%d writers and %d appenders, space returned\n",
	       WRITERS, APPENDERS);
	return 0;
}
