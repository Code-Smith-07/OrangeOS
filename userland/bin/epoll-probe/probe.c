/* Readiness through musl on OrangeOS: epoll level-triggered, edge-triggered
 * and oneshot interests, EPOLLOUT/HUP/ERR, blocking waits woken by other
 * threads, timeouts, removal on close, an eventfd wakeup loop like Chromium's
 * message pump, 64 pipes at once, and poll()/select().
 *
 * SPDX-License-Identifier: MIT OR Apache-2.0
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/epoll.h>
#include <sys/eventfd.h>
#include <sys/select.h>
#include <time.h>
#include <unistd.h>

#define CHECK(condition, what)                                                   \
	do {                                                                         \
		if (!(condition)) {                                                      \
			printf("epoll-probe: FAIL %s (errno %d)\n", (what), errno);          \
			return 1;                                                            \
		}                                                                        \
	} while (0)

enum { PIPES = 64, WAKEUPS = 100 };

static long now_ms(void)
{
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return t.tv_sec * 1000 + t.tv_nsec / 1000000;
}

static void pause_ms(long ms)
{
	struct timespec t = { ms / 1000, (ms % 1000) * 1000000L };
	nanosleep(&t, NULL);
}

static int wait_one(int ep, struct epoll_event *event, int timeout)
{
	return epoll_wait(ep, event, 1, timeout);
}

static int late_fd;
static void *late_writer(void *unused)
{
	(void)unused;
	pause_ms(30);
	return write(late_fd, "!", 1) == 1 ? NULL : (void *)1;
}

static int wake_fd;
static void *waker(void *unused)
{
	(void)unused;
	uint64_t one = 1;
	for (int i = 0; i < WAKEUPS; i++) {
		if (write(wake_fd, &one, 8) != 8)
			return (void *)1;
		if (i % 10 == 0)
			pause_ms(1);
	}
	return NULL;
}

static int pipes[PIPES][2];
static void *pipe_poker(void *unused)
{
	(void)unused;
	for (int i = PIPES - 1; i >= 0; i -= 7) {
		pause_ms(2);
		if (write(pipes[i][1], "x", 1) != 1)
			return (void *)1;
	}
	return NULL;
}

int main(void)
{
	struct epoll_event event, got;
	char byte;
	void *result;
	pthread_t thread;

	int ep = epoll_create1(EPOLL_CLOEXEC);
	CHECK(ep >= 0 && (fcntl(ep, F_GETFD) & FD_CLOEXEC), "epoll_create1");

	/* Level-triggered: reported while data remains. */
	int a[2];
	CHECK(pipe(a) == 0, "pipe");
	event = (struct epoll_event){ .events = EPOLLIN, .data.u64 = 0xabcdef0123ULL };
	CHECK(epoll_ctl(ep, EPOLL_CTL_ADD, a[0], &event) == 0, "add");
	CHECK(wait_one(ep, &got, 0) == 0, "nothing ready yet");
	CHECK(write(a[1], "x", 1) == 1 && wait_one(ep, &got, 0) == 1 && got.events == EPOLLIN && got.data.u64 == 0xabcdef0123ULL, "readable with its data");
	CHECK(wait_one(ep, &got, 0) == 1, "level-triggered repeats");
	CHECK(read(a[0], &byte, 1) == 1 && wait_one(ep, &got, 0) == 0, "drained");

	/* Errors. */
	errno = 0;
	CHECK(epoll_ctl(ep, EPOLL_CTL_ADD, a[0], &event) == -1 && errno == EEXIST, "EEXIST");
	errno = 0;
	CHECK(epoll_ctl(ep, EPOLL_CTL_DEL, a[1], NULL) == -1 && errno == ENOENT, "ENOENT");
	int file = open("/etc/motd", O_RDONLY);
	errno = 0;
	CHECK(epoll_ctl(ep, EPOLL_CTL_ADD, file, &event) == -1 && errno == EPERM, "EPERM for a regular file");
	errno = 0;
	CHECK(epoll_ctl(file, EPOLL_CTL_ADD, a[0], &event) == -1 && errno == EINVAL, "EINVAL for a non-epoll descriptor");
	errno = 0;
	CHECK(epoll_ctl(ep, EPOLL_CTL_ADD, ep, &event) == -1 && errno == EINVAL, "EINVAL for itself");
	close(file);
	CHECK(epoll_ctl(ep, EPOLL_CTL_DEL, a[0], NULL) == 0, "delete");

	/* Edge-triggered: once per new arrival. */
	event = (struct epoll_event){ .events = EPOLLIN | EPOLLET, .data.fd = a[0] };
	CHECK(epoll_ctl(ep, EPOLL_CTL_ADD, a[0], &event) == 0, "add edge-triggered");
	CHECK(write(a[1], "x", 1) == 1 && wait_one(ep, &got, 0) == 1 && got.data.fd == a[0], "edge reported");
	CHECK(wait_one(ep, &got, 0) == 0, "edge not repeated");
	CHECK(write(a[1], "y", 1) == 1 && wait_one(ep, &got, 0) == 1, "new edge reported");
	char two[2];
	CHECK(read(a[0], two, 2) == 2, "drain edge");

	/* Oneshot: disabled after one report until re-armed. */
	event = (struct epoll_event){ .events = EPOLLIN | EPOLLONESHOT, .data.fd = a[0] };
	CHECK(epoll_ctl(ep, EPOLL_CTL_MOD, a[0], &event) == 0, "mod to oneshot");
	CHECK(write(a[1], "z", 1) == 1 && wait_one(ep, &got, 0) == 1 && wait_one(ep, &got, 0) == 0, "oneshot fires once");
	CHECK(epoll_ctl(ep, EPOLL_CTL_MOD, a[0], &event) == 0 && wait_one(ep, &got, 0) == 1, "re-armed");
	CHECK(read(a[0], &byte, 1) == 1 && epoll_ctl(ep, EPOLL_CTL_DEL, a[0], NULL) == 0, "clean up oneshot");

	/* EPOLLOUT follows space; HUP and ERR follow the peer closing. */
	CHECK(fcntl(a[1], F_SETFL, O_NONBLOCK) == 0, "nonblocking writer");
	event = (struct epoll_event){ .events = EPOLLOUT, .data.fd = a[1] };
	CHECK(epoll_ctl(ep, EPOLL_CTL_ADD, a[1], &event) == 0 && wait_one(ep, &got, 0) == 1 && got.events == EPOLLOUT, "writable");
	char block[4096];
	memset(block, 1, sizeof block);
	while (write(a[1], block, sizeof block) > 0) {
	}
	CHECK(wait_one(ep, &got, 0) == 0, "full pipe not writable");
	while (read(a[0], block, sizeof block) == (ssize_t)sizeof block && wait_one(ep, &got, 0) == 0) {
	}
	CHECK(wait_one(ep, &got, 0) == 1, "writable again after draining");
	CHECK(epoll_ctl(ep, EPOLL_CTL_DEL, a[1], NULL) == 0, "delete writer");
	CHECK(fcntl(a[0], F_SETFL, O_NONBLOCK) == 0, "nonblocking drain");
	while (read(a[0], block, sizeof block) > 0) {
	}
	CHECK(errno == EAGAIN && fcntl(a[0], F_SETFL, 0) == 0, "drained");
	int b[2];
	CHECK(pipe(b) == 0, "hangup pipe");
	event = (struct epoll_event){ .events = EPOLLIN, .data.fd = b[0] };
	CHECK(epoll_ctl(ep, EPOLL_CTL_ADD, b[0], &event) == 0 && close(b[1]) == 0, "writer closed");
	CHECK(wait_one(ep, &got, 0) == 1 && (got.events & EPOLLHUP) && (got.events & EPOLLIN), "EPOLLHUP after the last writer");
	CHECK(close(b[0]) == 0, "close hangup reader");
	CHECK(pipe(b) == 0, "error pipe");
	event = (struct epoll_event){ .events = EPOLLOUT, .data.fd = b[1] };
	CHECK(epoll_ctl(ep, EPOLL_CTL_ADD, b[1], &event) == 0 && close(b[0]) == 0, "reader closed");
	CHECK(wait_one(ep, &got, 0) == 1 && (got.events & EPOLLERR), "EPOLLERR after the last reader");
	CHECK(close(b[1]) == 0, "close error writer");

	/* Closing a descriptor removes it: the reused number adds cleanly. */
	CHECK(wait_one(ep, &got, 0) == 0, "closed interests are gone");
	CHECK(pipe(b) == 0, "reuse pipe");
	event = (struct epoll_event){ .events = EPOLLIN, .data.fd = b[0] };
	CHECK(epoll_ctl(ep, EPOLL_CTL_ADD, b[0], &event) == 0, "reused number is a new interest");
	close(b[0]);
	close(b[1]);

	/* A blocking wait woken by another thread, and a timeout. */
	CHECK(fcntl(a[1], F_SETFL, 0) == 0, "blocking writer");
	event = (struct epoll_event){ .events = EPOLLIN, .data.fd = a[0] };
	CHECK(epoll_ctl(ep, EPOLL_CTL_ADD, a[0], &event) == 0, "add for blocking wait");
	late_fd = a[1];
	long start = now_ms();
	CHECK(pthread_create(&thread, NULL, late_writer, NULL) == 0, "late writer");
	CHECK(wait_one(ep, &got, -1) == 1 && now_ms() - start >= 25, "blocking wait woken");
	CHECK(pthread_join(thread, &result) == 0 && result == NULL && read(a[0], &byte, 1) == 1, "late writer done");
	start = now_ms();
	CHECK(wait_one(ep, &got, 50) == 0 && now_ms() - start >= 45, "timeout");
	CHECK(epoll_ctl(ep, EPOLL_CTL_DEL, a[0], NULL) == 0, "delete blocking");

	/* Chromium's pump pattern: an eventfd wakeup, drained on each report. */
	wake_fd = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
	event = (struct epoll_event){ .events = EPOLLIN, .data.fd = wake_fd };
	CHECK(epoll_ctl(ep, EPOLL_CTL_ADD, wake_fd, &event) == 0, "add eventfd");
	CHECK(pthread_create(&thread, NULL, waker, NULL) == 0, "waker");
	uint64_t total = 0, value;
	while (total < WAKEUPS) {
		CHECK(wait_one(ep, &got, 5000) == 1 && got.data.fd == wake_fd, "wakeup reported");
		while (read(wake_fd, &value, 8) == 8)
			total += value;
	}
	CHECK(pthread_join(thread, &result) == 0 && result == NULL && total == WAKEUPS, "all wakeups counted");
	close(wake_fd);

	/* Many descriptors at once. */
	int ep2 = epoll_create(1);
	for (int i = 0; i < PIPES; i++) {
		CHECK(pipe(pipes[i]) == 0, "many pipes");
		event = (struct epoll_event){ .events = EPOLLIN | EPOLLET, .data.u32 = (uint32_t)i };
		CHECK(epoll_ctl(ep2, EPOLL_CTL_ADD, pipes[i][0], &event) == 0, "many adds");
	}
	CHECK(pthread_create(&thread, NULL, pipe_poker, NULL) == 0, "poker");
	int seen = 0, expected = 0;
	for (int i = PIPES - 1; i >= 0; i -= 7)
		expected++;
	struct epoll_event batch[16];
	while (seen < expected) {
		int n = epoll_wait(ep2, batch, 16, 5000);
		CHECK(n > 0, "batch wait");
		for (int k = 0; k < n; k++) {
			int i = (int)batch[k].data.u32;
			CHECK((PIPES - 1 - i) % 7 == 0 && read(pipes[i][0], &byte, 1) == 1, "right pipe reported");
			seen++;
		}
	}
	CHECK(pthread_join(thread, &result) == 0 && result == NULL, "poker done");
	for (int i = 0; i < PIPES; i++) {
		close(pipes[i][0]);
		close(pipes[i][1]);
	}
	close(ep2);

	/* poll(). */
	struct pollfd fds[3] = { { a[0], POLLIN, 0 }, { a[1], POLLOUT, 0 }, { 999, POLLIN, 0 } };
	CHECK(poll(fds, 3, 0) == 2 && fds[0].revents == 0 && fds[1].revents == POLLOUT && fds[2].revents == POLLNVAL, "poll snapshot");
	late_fd = a[1];
	CHECK(pthread_create(&thread, NULL, late_writer, NULL) == 0, "poll writer");
	CHECK(poll(fds, 1, -1) == 1 && fds[0].revents == POLLIN, "blocking poll woken");
	CHECK(pthread_join(thread, &result) == 0 && read(a[0], &byte, 1) == 1, "poll writer done");
	start = now_ms();
	CHECK(poll(NULL, 0, 20) == 0 && now_ms() - start >= 15, "poll as a sleep");

	/* select(). */
	fd_set readable;
	FD_ZERO(&readable);
	FD_SET(a[0], &readable);
	struct timeval none = { 0, 0 };
	CHECK(select(a[0] + 1, &readable, NULL, NULL, &none) == 0 && !FD_ISSET(a[0], &readable), "select nothing");
	CHECK(write(a[1], "s", 1) == 1, "select data");
	FD_SET(a[0], &readable);
	struct timeval second = { 1, 0 };
	CHECK(select(a[0] + 1, &readable, NULL, NULL, &second) == 1 && FD_ISSET(a[0], &readable), "select readable");
	CHECK(read(a[0], &byte, 1) == 1 && close(a[1]) == 0, "select cleanup");
	fds[0].revents = 0;
	CHECK(poll(fds, 1, 0) == 1 && (fds[0].revents & POLLHUP), "POLLHUP after the writer closes");
	close(a[0]);
	close(ep);

	printf("epoll-probe: PASS level/edge/oneshot, OUT/HUP/ERR, blocking and timed waits, removal on close, "
	       "eventfd pump, %d pipes, poll and select\n",
	       PIPES);
	return 0;
}
