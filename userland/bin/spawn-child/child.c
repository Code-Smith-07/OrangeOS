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
	if (strcmp(mode, "socket") == 0)
		return socket_child();
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
