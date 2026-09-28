/* A program for spawn-probe to start. Its first argument picks what it does,
 * and it reports on stdout what it was started with.
 *
 * SPDX-License-Identifier: MIT OR Apache-2.0
 */
#define _GNU_SOURCE
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

static int echo(int argc, char **argv)
{
	printf("argc=%d\n", argc);
	for (int i = 0; i < argc; i++)
		printf("[%s]\n", argv[i]);
	const char *foo = getenv("FOO"), *empty = getenv("EMPTY");
	printf("FOO=%s EMPTY=%s MISSING=%s\n", foo ? foo : "(unset)", empty ? empty : "(unset)", getenv("MISSING") ? "set" : "(unset)");
	return 0;
}

static int list_fds(void)
{
	printf("open:");
	for (int fd = 0; fd < 64; fd++)
		if (fcntl(fd, F_GETFD) >= 0)
			printf(" %d", fd);
	printf("\n");
	return 0;
}

static int upper(void)
{
	char buffer[256];
	ssize_t n;
	while ((n = read(0, buffer, sizeof buffer)) > 0) {
		for (ssize_t i = 0; i < n; i++)
			buffer[i] = (char)toupper((unsigned char)buffer[i]);
		if (write(1, buffer, n) != n)
			return 2;
	}
	return n == 0 ? 0 : 3;
}

static void pause_or_sleep(void)
{
	struct timespec pause = { 0, 5 * 1000 * 1000 };
	nanosleep(&pause, NULL);
}

/* Map the memfd inherited at 3, check the parent's pattern, answer on the
 * second page. */
static int shared_memory_child(void)
{
	unsigned char *view = mmap(NULL, 2 * 4096, PROT_READ | PROT_WRITE, MAP_SHARED, 3, 0);
	if (view == MAP_FAILED)
		return 9;
	for (int i = 0; i < 4096; i++)
		if (view[i] != (unsigned char)(i * 7))
			return 10;
	memcpy(view + 4096, "child was here", 15);
	return munmap(view, 2 * 4096) == 0 ? 0 : 11;
}

static volatile int terminated;
static void on_term(int sig)
{
	(void)sig;
	terminated = 1;
}

/* Say "ready" on stdout, then wait for SIGTERM and report it. */
static int trap_term(void)
{
	struct sigaction action = { .sa_handler = on_term };
	sigemptyset(&action.sa_mask);
	if (sigaction(SIGTERM, &action, NULL) != 0)
		return 12;
	if (write(1, "ready\n", 6) != 6)
		return 13;
	while (!terminated)
		pause_or_sleep();
	return write(1, "term\n", 5) == 5 ? 0 : 14;
}

static int socket_child(void)
{
	/* A descriptor arrives over the inherited socket at 3. */
	char byte, control[CMSG_SPACE(sizeof(int))];
	struct iovec vector = { &byte, 1 };
	struct msghdr message = { .msg_iov = &vector, .msg_iovlen = 1, .msg_control = control, .msg_controllen = sizeof control };
	if (recvmsg(3, &message, 0) != 1)
		return 4;
	struct cmsghdr *header = CMSG_FIRSTHDR(&message);
	if (!header || header->cmsg_type != SCM_RIGHTS)
		return 5;
	int fd;
	memcpy(&fd, CMSG_DATA(header), sizeof fd);
	const char text[] = "from child\n";
	return write(fd, text, sizeof text - 1) == (ssize_t)(sizeof text - 1) ? 0 : 6;
}

/* Record locks against the holder in file-probe. "probe": report the
 * conflicting lock, take a free range, then wait for the held one.
 * "deadlock": hold 200, then wait for 300, which the parent holds. */
static int lock_child(const char *path, const char *step)
{
	int fd = open(path, O_RDWR);
	if (fd < 0)
		return 20;
	struct flock lock = { .l_type = F_WRLCK, .l_whence = SEEK_SET, .l_start = 0, .l_len = 10 };
	if (strcmp(step, "probe") == 0) {
		if (fcntl(fd, F_SETLK, &lock) != -1 || errno != EAGAIN)
			return 21;
		struct flock query = lock;
		if (fcntl(fd, F_GETLK, &query) != 0)
			return 22;
		printf("held by %d %s %ld %ld\n", (int)query.l_pid, query.l_type == F_WRLCK ? "write" : "other",
		       (long)query.l_start, (long)query.l_len);
		fflush(stdout);
		struct flock free_range = { .l_type = F_RDLCK, .l_whence = SEEK_SET, .l_start = 100, .l_len = 10 };
		if (fcntl(fd, F_SETLK, &free_range) != 0)
			return 23;
		if (fcntl(fd, F_SETLKW, &lock) != 0)
			return 24;
	} else if (strcmp(step, "deadlock") == 0) {
		struct flock mine = { .l_type = F_WRLCK, .l_whence = SEEK_SET, .l_start = 200, .l_len = 1 };
		if (fcntl(fd, F_SETLK, &mine) != 0)
			return 25;
		printf("waiting\n");
		fflush(stdout);
		struct flock theirs = { .l_type = F_WRLCK, .l_whence = SEEK_SET, .l_start = 300, .l_len = 1 };
		if (fcntl(fd, F_SETLKW, &theirs) != 0)
			return 26;
	} else
		return 27;
	printf("acquired\n");
	return 0;
}

int main(int argc, char **argv)
{
	if (argc < 2)
		return 100;
	const char *mode = argv[1];
	if (strcmp(mode, "echo") == 0)
		return echo(argc, argv);
	if (strcmp(mode, "fds") == 0)
		return list_fds();
	if (strcmp(mode, "cwd") == 0) {
		char cwd[256];
		return getcwd(cwd, sizeof cwd) && printf("%s\n", cwd) > 0 ? 0 : 7;
	}
	if (strcmp(mode, "upper") == 0)
		return upper();
	if (strcmp(mode, "motd20") == 0) {
		char line[64];
		ssize_t n = read(20, line, sizeof line);
		return n > 0 && write(1, line, n) == n ? 0 : 8;
	}
	if (strcmp(mode, "lock") == 0 && argc > 3)
		return lock_child(argv[2], argv[3]);
	if (strcmp(mode, "socket") == 0)
		return socket_child();
	if (strcmp(mode, "shm") == 0)
		return shared_memory_child();
	if (strcmp(mode, "trap-term") == 0)
		return trap_term();
	if (strcmp(mode, "abort") == 0)
		abort();
	if (strcmp(mode, "exit") == 0 && argc > 2)
		return atoi(argv[2]);
	if (strcmp(mode, "sleep") == 0 && argc > 2) {
		struct timespec pause = { 0, atol(argv[2]) * 1000000L };
		nanosleep(&pause, NULL);
		return 3;
	}
	if (strcmp(mode, "stdout-closed") == 0) {
		errno = 0;
		return write(1, "x", 1) == -1 ? errno : 0;
	}
	return 101;
}
