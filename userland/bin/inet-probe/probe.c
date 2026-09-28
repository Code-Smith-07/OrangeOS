/* BSD sockets through musl on OrangeOS (docs/design/012, B8).
 *
 * Talks to fixtures on the host, which QEMU's user network presents as
 * 10.0.2.2 (tools/runtime_smoke.py): a TCP server on 38457 that answers
 * "orange-bulk <n>" with n patterned bytes, and a UDP server on 38458 that
 * echoes each datagram reversed. Checks name lookup from /etc/hosts and a
 * DNS query through /etc/resolv.conf; blocking and non-blocking connects
 * with epoll; a 2 MiB transfer; half-close; connection refused both ways;
 * UDP with connect, sendto/recvfrom and poll; socket options; and the
 * honest refusals (IPv6, listen, loopback).
 *
 * SPDX-License-Identifier: MIT OR Apache-2.0
 */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <arpa/nameser.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <resolv.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/epoll.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define CHECK(condition, what)                                                   \
	do {                                                                         \
		if (!(condition)) {                                                      \
			printf("inet-probe: FAIL %s (errno %d)\n", (what), errno);           \
			return 1;                                                            \
		}                                                                        \
	} while (0)

#define HOST "10.0.2.2"
#define TCP_PORT 38457
#define UDP_PORT 38458
#define BULK (2 * 1024 * 1024)

static struct sockaddr_in endpoint(const char *ip, int port)
{
	struct sockaddr_in at;
	memset(&at, 0, sizeof at);
	at.sin_family = AF_INET;
	at.sin_port = htons((unsigned short)port);
	inet_pton(AF_INET, ip, &at.sin_addr);
	return at;
}

static long long now_ms(void)
{
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return (long long)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}

static unsigned char pattern(size_t i)
{
	return (unsigned char)((i * 131 + 7) & 0xFF);
}

static int send_all(int fd, const char *text)
{
	size_t length = strlen(text), sent = 0;
	while (sent < length) {
		ssize_t n = send(fd, text + sent, length - sent, MSG_NOSIGNAL);
		if (n <= 0)
			return -1;
		sent += (size_t)n;
	}
	return 0;
}

/* Read a patterned stream to its end; returns the byte count or -1. */
static long read_pattern(int fd)
{
	static unsigned char buffer[16384];
	long total = 0;
	for (;;) {
		ssize_t n = recv(fd, buffer, sizeof buffer, 0);
		if (n < 0)
			return -1;
		if (n == 0)
			return total;
		for (ssize_t i = 0; i < n; i++)
			if (buffer[i] != pattern((size_t)total + (size_t)i))
				return -1;
		total += n;
	}
}

static int names(void)
{
	struct addrinfo hints = { .ai_family = AF_INET, .ai_socktype = SOCK_STREAM }, *found = NULL;
	CHECK(getaddrinfo("localhost", "80", &hints, &found) == 0 && found, "getaddrinfo localhost (/etc/hosts)");
	struct sockaddr_in *at = (struct sockaddr_in *)found->ai_addr;
	CHECK(at->sin_addr.s_addr == htonl(INADDR_LOOPBACK) && ntohs(at->sin_port) == 80, "localhost is 127.0.0.1");
	freeaddrinfo(found);

	/* A real DNS exchange through musl's resolver: UDP to the server in
	 * /etc/resolv.conf, which QEMU forwards to the host's. What the
	 * upstream answers depends on the host's network, so any well-formed
	 * response to this query (NOERROR or NXDOMAIN) passes. */
	unsigned char query[280], answer[512];
	int query_length = res_mkquery(ns_o_query, "orange-os-probe.invalid", ns_c_in, ns_t_a, NULL, 0, NULL, query, sizeof query);
	CHECK(query_length > 12, "DNS query built");
	int length = res_send(query, query_length, answer, sizeof answer);
	CHECK(length >= 12, "DNS response over UDP");
	CHECK(answer[0] == query[0] && answer[1] == query[1] && (answer[2] & 0x80), "DNS response matches the query");
	ns_msg message;
	CHECK(ns_initparse(answer, length, &message) == 0 && ns_msg_count(message, ns_s_qd) == 1, "DNS response parses");
	return 0;
}

static int blocking_tcp(long *rate)
{
	int fd = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
	CHECK(fd >= 0, "socket");
	int type = 0;
	socklen_t size = sizeof type;
	CHECK(getsockopt(fd, SOL_SOCKET, SO_TYPE, &type, &size) == 0 && type == SOCK_STREAM, "SO_TYPE");
	int one = 1;
	CHECK(setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one) == 0, "TCP_NODELAY");
	CHECK(setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &one, sizeof one) == 0, "SO_KEEPALIVE");
	struct sockaddr_in server = endpoint(HOST, TCP_PORT);
	CHECK(connect(fd, (struct sockaddr *)&server, sizeof server) == 0, "blocking connect");

	struct sockaddr_in local, peer;
	socklen_t local_size = sizeof local, peer_size = sizeof peer;
	CHECK(getsockname(fd, (struct sockaddr *)&local, &local_size) == 0 && local.sin_family == AF_INET && ntohs(local.sin_port) >= 32768, "getsockname");
	CHECK(getpeername(fd, (struct sockaddr *)&peer, &peer_size) == 0 && peer.sin_addr.s_addr == server.sin_addr.s_addr && peer.sin_port == server.sin_port, "getpeername");

	char request[64];
	snprintf(request, sizeof request, "orange-bulk %d\n", BULK);
	CHECK(send_all(fd, request) == 0, "send request");
	/* Half-close: our FIN must not stop the reply. */
	CHECK(shutdown(fd, SHUT_WR) == 0, "shutdown write");
	long long start = now_ms();
	long got = read_pattern(fd);
	long long elapsed = now_ms() - start;
	CHECK(got == BULK, "2 MiB patterned reply");
	*rate = elapsed > 0 ? (long)(got / elapsed) : got;
	char byte;
	CHECK(recv(fd, &byte, 1, 0) == 0, "end of stream stays readable");
	CHECK(close(fd) == 0, "close");
	return 0;
}

static int nonblocking_tcp(void)
{
	int fd = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK, 0);
	CHECK(fd >= 0, "nonblocking socket");
	struct sockaddr_in server = endpoint(HOST, TCP_PORT);
	errno = 0;
	CHECK(connect(fd, (struct sockaddr *)&server, sizeof server) == -1 && errno == EINPROGRESS, "connect in progress");
	errno = 0;
	CHECK(connect(fd, (struct sockaddr *)&server, sizeof server) == -1 && (errno == EALREADY || errno == EISCONN), "second connect");

	int ep = epoll_create1(EPOLL_CLOEXEC);
	struct epoll_event event = { .events = EPOLLOUT, .data.fd = fd }, ready;
	CHECK(epoll_ctl(ep, EPOLL_CTL_ADD, fd, &event) == 0, "epoll add");
	CHECK(epoll_wait(ep, &ready, 1, 5000) == 1 && (ready.events & EPOLLOUT), "writable when connected");
	int failure = -1;
	socklen_t size = sizeof failure;
	CHECK(getsockopt(fd, SOL_SOCKET, SO_ERROR, &failure, &size) == 0 && failure == 0, "SO_ERROR 0");

	/* Nothing is sent before a request: a non-blocking read must not wait. */
	char idle;
	errno = 0;
	CHECK(recv(fd, &idle, 1, 0) == -1 && errno == EAGAIN, "EAGAIN on an idle connection");

	char request[64];
	snprintf(request, sizeof request, "orange-bulk %d\n", 100000);
	CHECK(send(fd, request, strlen(request), 0) == (ssize_t)strlen(request), "nonblocking send");
	event.events = EPOLLIN | EPOLLRDHUP;
	CHECK(epoll_ctl(ep, EPOLL_CTL_MOD, fd, &event) == 0, "epoll mod");
	static unsigned char buffer[8192];
	long total = 0;
	int done = 0;
	while (!done) {
		CHECK(epoll_wait(ep, &ready, 1, 5000) == 1, "readable");
		for (;;) {
			ssize_t n = recv(fd, buffer, sizeof buffer, 0);
			if (n > 0) {
				for (ssize_t i = 0; i < n; i++)
					CHECK(buffer[i] == pattern((size_t)total + (size_t)i), "nonblocking data");
				total += n;
				continue;
			}
			if (n == 0) {
				done = 1;
				break;
			}
			CHECK(errno == EAGAIN, "EAGAIN between arrivals");
			break;
		}
	}
	CHECK(total == 100000, "nonblocking transfer");
	int pending = -1;
	CHECK(ioctl(fd, FIONREAD, &pending) == 0 && pending == 0, "FIONREAD");
	close(ep);
	close(fd);
	return 0;
}

static int refused(void)
{
	/* Nothing listens on port 1 of the host: QEMU answers with a reset. */
	struct sockaddr_in closed = endpoint(HOST, 1);
	int fd = socket(AF_INET, SOCK_STREAM, 0);
	errno = 0;
	CHECK(connect(fd, (struct sockaddr *)&closed, sizeof closed) == -1 && errno == ECONNREFUSED, "blocking connect refused");
	close(fd);

	fd = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK, 0);
	errno = 0;
	CHECK(connect(fd, (struct sockaddr *)&closed, sizeof closed) == -1 && errno == EINPROGRESS, "nonblocking refused starts");
	struct pollfd watch = { .fd = fd, .events = POLLOUT };
	CHECK(poll(&watch, 1, 5000) == 1 && (watch.revents & (POLLERR | POLLHUP)), "poll reports the failure");
	int failure = 0;
	socklen_t size = sizeof failure;
	CHECK(getsockopt(fd, SOL_SOCKET, SO_ERROR, &failure, &size) == 0 && failure == ECONNREFUSED, "SO_ERROR ECONNREFUSED");
	close(fd);
	return 0;
}

static int datagrams(void)
{
	int fd = socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0);
	CHECK(fd >= 0, "UDP socket");
	struct sockaddr_in any = endpoint("0.0.0.0", 0);
	CHECK(bind(fd, (struct sockaddr *)&any, sizeof any) == 0, "bind to an ephemeral port");
	struct sockaddr_in local;
	socklen_t size = sizeof local;
	CHECK(getsockname(fd, (struct sockaddr *)&local, &size) == 0 && ntohs(local.sin_port) != 0, "bound port");

	struct sockaddr_in server = endpoint(HOST, UDP_PORT), from;
	const char *text = "orange datagram";
	CHECK(sendto(fd, text, strlen(text), 0, (struct sockaddr *)&server, sizeof server) == (ssize_t)strlen(text), "sendto");
	struct pollfd watch = { .fd = fd, .events = POLLIN };
	CHECK(poll(&watch, 1, 5000) == 1 && (watch.revents & POLLIN), "reply readable");
	char reply[64];
	size = sizeof from;
	ssize_t n = recvfrom(fd, reply, sizeof reply, 0, (struct sockaddr *)&from, &size);
	CHECK(n == (ssize_t)strlen(text) && memcmp(reply, "margatad egnaro", (size_t)n) == 0, "echoed datagram");
	CHECK(size == sizeof from && from.sin_port == server.sin_port && from.sin_addr.s_addr == server.sin_addr.s_addr, "sender address");

	/* A connected UDP socket: send and recv without addresses, and a
	 * datagram larger than the buffer is cut with MSG_TRUNC. */
	CHECK(connect(fd, (struct sockaddr *)&server, sizeof server) == 0, "UDP connect");
	CHECK(send(fd, "0123456789", 10, 0) == 10, "UDP send");
	CHECK(poll(&watch, 1, 5000) == 1, "second reply");
	struct iovec part = { .iov_base = reply, .iov_len = 4 };
	struct msghdr header = { .msg_iov = &part, .msg_iovlen = 1 };
	CHECK(recvmsg(fd, &header, 0) == 4 && memcmp(reply, "9876", 4) == 0 && (header.msg_flags & MSG_TRUNC), "truncated datagram");
	errno = 0;
	CHECK(recv(fd, reply, sizeof reply, MSG_DONTWAIT) == -1 && errno == EAGAIN, "rest of a datagram is discarded");
	close(fd);
	return 0;
}

static int refusals(void)
{
	errno = 0;
	CHECK(socket(AF_INET6, SOCK_STREAM, 0) == -1 && errno == EAFNOSUPPORT, "IPv6 refused");
	int fd = socket(AF_INET, SOCK_STREAM, 0);
	errno = 0;
	CHECK(listen(fd, 4) == -1 && errno == EOPNOTSUPP, "listen refused");
	struct sockaddr_in loopback = endpoint("127.0.0.1", 80);
	errno = 0;
	CHECK(connect(fd, (struct sockaddr *)&loopback, sizeof loopback) == -1 && errno == ENETUNREACH, "no loopback interface");
	int value = 1;
	errno = 0;
	CHECK(setsockopt(fd, IPPROTO_IP, IP_TOS, &value, sizeof value) == -1 && errno == ENOPROTOOPT, "unknown option");
	struct linger lingering = { .l_onoff = 1, .l_linger = 5 };
	errno = 0;
	CHECK(setsockopt(fd, SOL_SOCKET, SO_LINGER, &lingering, sizeof lingering) == -1 && errno == EOPNOTSUPP, "blocking linger refused");
	char byte;
	errno = 0;
	CHECK(recv(fd, &byte, 1, MSG_DONTWAIT) == -1 && errno == ENOTCONN, "recv before connect");
	close(fd);
	return 0;
}

int main(void)
{
	long rate = 0;
	if (names() || blocking_tcp(&rate) || nonblocking_tcp() || refused() || datagrams() || refusals())
		return 1;
	printf("inet-probe: PASS /etc/hosts and DNS, blocking and nonblocking TCP with epoll, 2 MiB at %ld KiB/s, "
	       "half-close, refused, UDP sendto/recvfrom/connect/MSG_TRUNC, options, refusals\n",
	       rate * 1000 / 1024);
	return 0;
}
