/* Local socket pairs and descriptor passing through musl on OrangeOS:
 * stream joining and partial reads, seqpacket and datagram boundaries and
 * truncation, SCM_RIGHTS moving pipe ends and shared file offsets, rights
 * never merged into earlier data, MSG_CTRUNC closing what does not fit,
 * MSG_CMSG_CLOEXEC, EOF/EPIPE/shutdown, nonblocking capacity, epoll, a
 * Mojo-like exchange between threads, and in-flight descriptors released
 * when both ends close.
 *
 * SPDX-License-Identifier: MIT OR Apache-2.0
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/epoll.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>

#define CHECK(condition, what)                                                   \
	do {                                                                         \
		if (!(condition)) {                                                      \
			printf("unix-probe: FAIL %s (errno %d)\n", (what), errno);           \
			return 1;                                                            \
		}                                                                        \
	} while (0)

enum { ROUNDS = 200 };

static ssize_t send_fds(int socket, const void *data, size_t length, const int *fds, int count)
{
	char control[CMSG_SPACE(sizeof(int) * 8)];
	struct iovec vector = { (void *)data, length };
	struct msghdr message = { .msg_iov = &vector, .msg_iovlen = 1 };
	if (count > 0) {
		message.msg_control = control;
		message.msg_controllen = CMSG_SPACE(sizeof(int) * count);
		struct cmsghdr *header = CMSG_FIRSTHDR(&message);
		header->cmsg_level = SOL_SOCKET;
		header->cmsg_type = SCM_RIGHTS;
		header->cmsg_len = CMSG_LEN(sizeof(int) * count);
		memcpy(CMSG_DATA(header), fds, sizeof(int) * count);
	}
	return sendmsg(socket, &message, 0);
}

/* Receive up to `room` descriptors; returns bytes, fills fds/count/flags. */
static ssize_t receive_fds(int socket, void *data, size_t length, int *fds, int room, int *count, int *flags, int options)
{
	char control[CMSG_SPACE(sizeof(int) * 8)];
	struct iovec vector = { data, length };
	struct msghdr message = { .msg_iov = &vector, .msg_iovlen = 1, .msg_control = control,
	                          .msg_controllen = room > 0 ? CMSG_SPACE(sizeof(int) * room) : 0 };
	ssize_t r = recvmsg(socket, &message, options);
	*count = 0;
	if (r >= 0) {
		/* One SCM_RIGHTS message at most (musl's CMSG_NXTHDR trips
		 * -Wsign-compare, so it is not used). */
		struct cmsghdr *h = CMSG_FIRSTHDR(&message);
		if (h && h->cmsg_level == SOL_SOCKET && h->cmsg_type == SCM_RIGHTS) {
			*count = (int)((h->cmsg_len - CMSG_LEN(0)) / sizeof(int));
			memcpy(fds, CMSG_DATA(h), sizeof(int) * *count);
		}
		*flags = message.msg_flags;
	}
	return r;
}

static int exchange[2];
static void *peer(void *unused)
{
	(void)unused;
	for (int i = 0; i < ROUNDS; i++) {
		char tag;
		int fd, count, flags;
		if (receive_fds(exchange[1], &tag, 1, &fd, 1, &count, &flags, MSG_CMSG_CLOEXEC) != 1 || count != 1)
			return (void *)1;
		if (write(fd, &i, sizeof i) != sizeof i || close(fd) != 0)
			return (void *)2;
	}
	return NULL;
}

int main(void)
{
	int sv[2], p[2], fds[8], count, flags;
	char buffer[512];
	struct stat status;

	/* A stream pair: both directions, joined sends, partial reads. */
	CHECK(socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, sv) == 0, "socketpair");
	CHECK(fstat(sv[0], &status) == 0 && S_ISSOCK(status.st_mode) && (fcntl(sv[0], F_GETFD) & FD_CLOEXEC), "a socket, close-on-exec");
	CHECK(write(sv[0], "abc", 3) == 3 && send(sv[0], "def", 3, 0) == 3, "two sends");
	CHECK(recv(sv[1], buffer, 2, 0) == 2 && memcmp(buffer, "ab", 2) == 0, "partial read");
	CHECK(read(sv[1], buffer, sizeof buffer) == 4 && memcmp(buffer, "cdef", 4) == 0, "joined remainder");
	CHECK(write(sv[1], "back", 4) == 4 && read(sv[0], buffer, sizeof buffer) == 4, "other direction");

	/* A pipe's write end moves through the socket; the sender's copy closes. */
	CHECK(pipe(p) == 0 && send_fds(sv[0], "w", 1, &p[1], 1) == 1 && close(p[1]) == 0, "send a pipe end");
	CHECK(receive_fds(sv[1], buffer, sizeof buffer, fds, 1, &count, &flags, 0) == 1 && count == 1 && buffer[0] == 'w', "receive it");
	CHECK(write(fds[0], "hi", 2) == 2 && read(p[0], buffer, sizeof buffer) == 2 && memcmp(buffer, "hi", 2) == 0, "write through the received end");
	CHECK(close(fds[0]) == 0 && read(p[0], buffer, sizeof buffer) == 0, "closing the only copy gives EOF");
	close(p[0]);

	/* A passed file shares its offset. */
	int file = open("/etc/motd", O_RDONLY);
	CHECK(read(file, buffer, 3) == 3 && send_fds(sv[0], "f", 1, &file, 1) == 1, "send a file");
	CHECK(receive_fds(sv[1], buffer, sizeof buffer, fds, 1, &count, &flags, 0) == 1 && count == 1, "receive the file");
	CHECK(read(fds[0], buffer, 4) == 4 && memcmp(buffer, "come", 4) == 0 && lseek(file, 0, SEEK_CUR) == 7, "shared offset");
	close(fds[0]);
	close(file);

	/* Rights never merge into earlier plain data. */
	CHECK(pipe(p) == 0, "rights pipe");
	CHECK(write(sv[0], "x", 1) == 1 && send_fds(sv[0], "y", 1, &p[1], 1) == 1 && close(p[1]) == 0, "plain then rights");
	CHECK(receive_fds(sv[1], buffer, sizeof buffer, fds, 1, &count, &flags, 0) == 1 && buffer[0] == 'x' && count == 0, "plain data alone");
	CHECK(receive_fds(sv[1], buffer, sizeof buffer, fds, 1, &count, &flags, MSG_CMSG_CLOEXEC) == 1 && buffer[0] == 'y' && count == 1, "rights with their byte");
	CHECK(fcntl(fds[0], F_GETFD) & FD_CLOEXEC, "MSG_CMSG_CLOEXEC");
	close(fds[0]);
	CHECK(read(p[0], buffer, 1) == 0, "moved end closed");
	close(p[0]);

	/* More rights than room: MSG_CTRUNC, and the rest are closed. */
	int readers[3], writers[3];
	for (int i = 0; i < 3; i++) {
		int q[2];
		CHECK(pipe(q) == 0, "ctrunc pipes");
		readers[i] = q[0];
		writers[i] = q[1];
	}
	CHECK(send_fds(sv[0], "3", 1, writers, 3) == 1, "send three");
	for (int i = 0; i < 3; i++)
		close(writers[i]);
	/* CMSG_SPACE of two descriptors holds exactly two, as on Linux. */
	CHECK(receive_fds(sv[1], buffer, sizeof buffer, fds, 2, &count, &flags, 0) == 1 && count == 2 && (flags & MSG_CTRUNC), "MSG_CTRUNC");
	CHECK(read(readers[2], buffer, 1) == 0, "the dropped right is closed");
	CHECK(write(fds[0], "k", 1) == 1 && read(readers[0], buffer, 1) == 1, "the first kept one works");
	CHECK(write(fds[1], "k", 1) == 1 && read(readers[1], buffer, 1) == 1, "the second kept one works");
	close(fds[0]);
	close(fds[1]);
	for (int i = 0; i < 3; i++)
		close(readers[i]);

	/* Nonblocking: EAGAIN when empty, and a 256 KiB queue. */
	errno = 0;
	CHECK(recv(sv[1], buffer, 1, MSG_DONTWAIT) == -1 && errno == EAGAIN, "MSG_DONTWAIT");
	CHECK(fcntl(sv[0], F_SETFL, O_NONBLOCK) == 0, "nonblocking sender");
	long queued = 0;
	for (ssize_t w; (w = write(sv[0], buffer, sizeof buffer)) > 0;)
		queued += w;
	CHECK(errno == EAGAIN && queued == 256 * 1024, "256 KiB queued, then EAGAIN");
	for (long drained = 0; drained < queued;) {
		ssize_t r = read(sv[1], buffer, sizeof buffer);
		CHECK(r > 0, "drain");
		drained += r;
	}
	CHECK(fcntl(sv[0], F_SETFL, 0) == 0, "blocking again");

	/* epoll sees data, then the peer's shutdown. */
	int ep = epoll_create1(0);
	struct epoll_event event = { .events = EPOLLIN | EPOLLRDHUP, .data.fd = sv[1] }, got;
	CHECK(epoll_ctl(ep, EPOLL_CTL_ADD, sv[1], &event) == 0 && epoll_wait(ep, &got, 1, 0) == 0, "idle socket");
	CHECK(write(sv[0], "e", 1) == 1 && epoll_wait(ep, &got, 1, 0) == 1 && got.events == EPOLLIN, "EPOLLIN");
	CHECK(read(sv[1], buffer, 1) == 1 && shutdown(sv[0], SHUT_WR) == 0, "shutdown for writing");
	CHECK(epoll_wait(ep, &got, 1, 0) == 1 && (got.events & EPOLLRDHUP) && read(sv[1], buffer, 1) == 0, "EOF after shutdown");
	close(ep);
	CHECK(close(sv[1]) == 0, "close one end");
	errno = 0;
	CHECK(write(sv[0], "z", 1) == -1 && errno == EPIPE, "EPIPE after the peer closes");
	close(sv[0]);

	/* seqpacket and datagram keep boundaries and truncate. */
	CHECK(socketpair(AF_UNIX, SOCK_SEQPACKET, 0, sv) == 0, "seqpacket pair");
	CHECK(send(sv[0], "0123456789", 10, 0) == 10 && send(sv[0], "twenty bytes message", 20, 0) == 20, "two messages");
	CHECK(recv(sv[1], buffer, sizeof buffer, 0) == 10 && recv(sv[1], buffer, sizeof buffer, 0) == 20, "boundaries kept");
	CHECK(send(sv[0], "a fifty byte message, longer than the reader wants", 50, 0) == 50 && write(sv[0], "next", 4) == 4, "long then short");
	struct iovec small = { buffer, 10 };
	struct msghdr header = { .msg_iov = &small, .msg_iovlen = 1 };
	CHECK(recvmsg(sv[1], &header, 0) == 10 && (header.msg_flags & MSG_TRUNC), "MSG_TRUNC");
	CHECK(recv(sv[1], buffer, sizeof buffer, 0) == 4 && memcmp(buffer, "next", 4) == 0, "rest discarded");
	close(sv[0]);
	close(sv[1]);
	CHECK(socketpair(AF_UNIX, SOCK_DGRAM, 0, sv) == 0 && send(sv[1], "dg", 2, 0) == 2 && recv(sv[0], buffer, 1, 0) == 1, "datagram");
	close(sv[0]);
	close(sv[1]);
	errno = 0;
	CHECK(socketpair(AF_INET, SOCK_STREAM, 0, sv) == -1 && errno == EAFNOSUPPORT, "only AF_UNIX pairs");

	/* A Mojo-like exchange: each message carries a new descriptor. */
	CHECK(socketpair(AF_UNIX, SOCK_STREAM, 0, exchange) == 0, "exchange pair");
	pthread_t thread;
	CHECK(pthread_create(&thread, NULL, peer, NULL) == 0, "peer thread");
	for (int i = 0; i < ROUNDS; i++) {
		CHECK(pipe(p) == 0 && send_fds(exchange[0], "m", 1, &p[1], 1) == 1 && close(p[1]) == 0, "send round");
		int value = -1;
		CHECK(read(p[0], &value, sizeof value) == sizeof value && value == i && read(p[0], &value, 1) == 0, "round trip through a passed pipe");
		close(p[0]);
	}
	void *result;
	CHECK(pthread_join(thread, &result) == 0 && result == NULL, "peer done");

	/* Descriptors still in flight close with the pair. */
	CHECK(pipe(p) == 0 && send_fds(exchange[0], "!", 1, &p[1], 1) == 1 && close(p[1]) == 0, "leave one in flight");
	CHECK(close(exchange[0]) == 0 && close(exchange[1]) == 0 && read(p[0], buffer, 1) == 0, "in-flight descriptor released");
	close(p[0]);
	int probe = open("/etc/motd", O_RDONLY);
	CHECK(probe == 3, "no descriptor leaked");
	close(probe);

	printf("unix-probe: PASS stream, seqpacket, datagram, SCM_RIGHTS (pipes, shared offsets, CTRUNC, CLOEXEC), "
	       "EOF/EPIPE/shutdown, 256 KiB, epoll and %d descriptor-passing rounds\n",
	       ROUNDS);
	return 0;
}
