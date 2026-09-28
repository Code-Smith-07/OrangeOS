/* Writable files through musl on OrangeOS's in-memory /tmp: stdio writes and
 * appends, positioned I/O, truncation, rename, unlink while open, directory
 * listing, capacity reporting, the errors POSIX requires, concurrent writers
 * and appenders, record locks between processes, and every page returned
 * once the files are gone.
 *
 * SPDX-License-Identifier: MIT OR Apache-2.0
 */
#define _POSIX_C_SOURCE 200809L
#define _DEFAULT_SOURCE /* d_type and DT_* */
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <sys/wait.h>
#include <unistd.h>

#ifndef F_OFD_GETLK
#define F_OFD_GETLK 36
#define F_OFD_SETLK 37
#define F_OFD_SETLKW 38
#endif

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

/* ── Record locks ─────────────────────────────────────────────────────────── */

extern char **environ;
#define LOCK_PATH "/tmp/lock-probe"

static int set_lock(int fd, int command, short type, off_t start, off_t length)
{
	struct flock lock = { .l_type = type, .l_whence = SEEK_SET, .l_start = start, .l_len = length };
	return fcntl(fd, command, &lock);
}

/* What F_OFD_GETLK through `fd` reports for an exclusive lock over the range. */
static struct flock probe_lock(int fd, off_t start, off_t length)
{
	struct flock lock = { .l_type = F_WRLCK, .l_whence = SEEK_SET, .l_start = start, .l_len = length };
	if (fcntl(fd, F_OFD_GETLK, &lock) != 0)
		lock.l_type = -1;
	return lock;
}

/* Start spawn-child in lock mode `step`, with its standard output on a pipe. */
static pid_t lock_child(const char *step, int *output)
{
	int pipe_fds[2];
	if (pipe(pipe_fds) != 0)
		return -1;
	posix_spawn_file_actions_t actions;
	posix_spawn_file_actions_init(&actions);
	posix_spawn_file_actions_adddup2(&actions, pipe_fds[1], 1);
	posix_spawn_file_actions_addclose(&actions, pipe_fds[0]);
	char *argv[] = { "spawn-child", "lock", LOCK_PATH, (char *)step, NULL };
	pid_t pid;
	int r = posix_spawn(&pid, "/bin/spawn-child", &actions, NULL, argv, environ);
	posix_spawn_file_actions_destroy(&actions);
	close(pipe_fds[1]);
	if (r != 0) {
		close(pipe_fds[0]);
		return -1;
	}
	*output = pipe_fds[0];
	return pid;
}

static int read_line(int fd, char *line, size_t size)
{
	size_t n = 0;
	while (n + 1 < size) {
		char c;
		if (read(fd, &c, 1) != 1)
			break;
		line[n++] = c;
		if (c == '\n')
			break;
	}
	line[n] = '\0';
	return (int)n;
}

static int child_status(pid_t pid)
{
	int status = -1;
	if (waitpid(pid, &status, 0) != pid || !WIFEXITED(status))
		return -1;
	return WEXITSTATUS(status);
}

static int record_locks(void)
{
	int fd = open(LOCK_PATH, O_RDWR | O_CREAT | O_TRUNC, 0644);
	CHECK(fd >= 0, "open lock file");
	char block[512];
	memset(block, 'l', sizeof block);
	CHECK(write(fd, block, sizeof block) == (ssize_t)sizeof block, "fill lock file");

	/* A process's own locks never block it. */
	CHECK(set_lock(fd, F_SETLK, F_WRLCK, 0, 50) == 0, "exclusive lock");
	struct flock own = { .l_type = F_WRLCK, .l_whence = SEEK_SET, .l_start = 0, .l_len = 10 };
	CHECK(fcntl(fd, F_GETLK, &own) == 0 && own.l_type == F_UNLCK, "own lock is not a conflict");

	/* Another process: refused, told who holds it, a disjoint range is
	 * free, and a waiting lock is granted once the holder lets go. */
	int output;
	pid_t child = lock_child("probe", &output);
	CHECK(child > 0, "spawn lock child");
	char line[96], expected[96];
	read_line(output, line, sizeof line);
	snprintf(expected, sizeof expected, "held by %d write 0 50\n", (int)getpid());
	if (strcmp(line, expected) != 0) {
		printf("file-probe: FAIL lock child saw \"%s\"\n", line);
		return 1;
	}
	struct timespec pause = { 0, 50 * 1000 * 1000 };
	nanosleep(&pause, NULL);
	CHECK(set_lock(fd, F_SETLK, F_UNLCK, 0, 0) == 0, "unlock");
	read_line(output, line, sizeof line);
	CHECK(strcmp(line, "acquired\n") == 0, "waiting lock granted after unlock");
	CHECK(child_status(child) == 0, "lock child exit");
	close(output);

	/* Splitting: unlocking the middle of a lock leaves two. Observed through
	 * another open file description, whose OFD locks conflict with ours. */
	int other = open(LOCK_PATH, O_RDWR);
	CHECK(other >= 0, "second description");
	CHECK(set_lock(fd, F_SETLK, F_WRLCK, 0, 100) == 0 && set_lock(fd, F_SETLK, F_UNLCK, 40, 20) == 0, "split lock");
	struct flock seen = probe_lock(other, 45, 1);
	CHECK(seen.l_type == F_UNLCK, "unlocked middle");
	seen = probe_lock(other, 10, 1);
	CHECK(seen.l_type == F_WRLCK && seen.l_start == 0 && seen.l_len == 40 && seen.l_pid == getpid(), "head of split lock");
	seen = probe_lock(other, 70, 1);
	CHECK(seen.l_type == F_WRLCK && seen.l_start == 60 && seen.l_len == 40, "tail of split lock");

	/* POSIX: closing any descriptor for the file drops the process's locks. */
	int third = open(LOCK_PATH, O_RDONLY);
	CHECK(third >= 0 && close(third) == 0, "open and close a third descriptor");
	CHECK(probe_lock(other, 10, 1).l_type == F_UNLCK, "close releases POSIX locks");

	/* OFD locks belong to the description: shared by dup, released with it. */
	CHECK(set_lock(fd, F_OFD_SETLK, F_WRLCK, 0, 10) == 0, "OFD lock");
	errno = 0;
	CHECK(set_lock(other, F_OFD_SETLK, F_WRLCK, 5, 1) == -1 && errno == EAGAIN, "OFD conflict between descriptions");
	int copy = dup(fd);
	CHECK(set_lock(copy, F_OFD_SETLK, F_WRLCK, 5, 1) == 0, "OFD lock shared by dup");
	close(fd);
	CHECK(set_lock(other, F_OFD_SETLK, F_WRLCK, 5, 1) == -1, "OFD lock outlives one of its descriptors");
	close(copy);
	CHECK(set_lock(other, F_OFD_SETLK, F_WRLCK, 5, 1) == 0 && set_lock(other, F_OFD_SETLK, F_UNLCK, 0, 0) == 0, "OFD lock released with its description");

	/* Deadlock: the child holds 200 and waits for 300, which we hold; our
	 * wait for 200 would close the cycle and must fail instead. */
	CHECK(set_lock(other, F_SETLK, F_WRLCK, 300, 1) == 0, "lock for deadlock test");
	child = lock_child("deadlock", &output);
	CHECK(child > 0, "spawn deadlock child");
	read_line(output, line, sizeof line);
	CHECK(strcmp(line, "waiting\n") == 0, "deadlock child waiting");
	nanosleep(&pause, NULL);
	errno = 0;
	CHECK(set_lock(other, F_SETLKW, F_WRLCK, 200, 1) == -1 && errno == EDEADLK, "deadlock detected");
	CHECK(set_lock(other, F_SETLK, F_UNLCK, 300, 1) == 0, "release for deadlock child");
	read_line(output, line, sizeof line);
	CHECK(strcmp(line, "acquired\n") == 0 && child_status(child) == 0, "deadlock child finishes");
	close(output);
	/* The child's locks went with it. */
	CHECK(set_lock(other, F_SETLK, F_WRLCK, 0, 0) == 0, "exited child's locks released");

	/* Access and argument errors. */
	int reader = open(LOCK_PATH, O_RDONLY);
	errno = 0;
	CHECK(set_lock(reader, F_SETLK, F_WRLCK, 0, 1) == -1 && errno == EBADF, "exclusive lock needs write access");
	errno = 0;
	CHECK(set_lock(reader, F_SETLK, F_RDLCK, -5, 1) == -1 && errno == EINVAL, "negative start");
	close(reader);
	close(other);
	CHECK(unlink(LOCK_PATH) == 0, "remove lock file");
	return 0;
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

	if (record_locks() != 0)
		return 1;

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
	       "%d writers and %d appenders, record locks, space returned\n",
	       WRITERS, APPENDERS);
	return 0;
}
