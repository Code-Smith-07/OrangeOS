/* Pipes, eventfd and descriptor duplication through musl on OrangeOS:
 * blocking and nonblocking pipes, end of file and EPIPE, atomic writes from
 * concurrent writers, a 1 MiB stream between threads, eventfd counter and
 * semaphore modes, dup/dup2/dup3/F_DUPFD sharing offsets and status flags,
 * close-on-exec flags, and the per-program descriptor limit.
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
#include <sys/eventfd.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define CHECK(condition, what)                                                   \
	do {                                                                         \
		if (!(condition)) {                                                      \
			printf("pipe-probe: FAIL %s (errno %d)\n", (what), errno);           \
			return 1;                                                            \
		}                                                                        \
	} while (0)

enum { STREAM_BYTES = 1 << 20, CHUNK = 1000, WRITERS = 4, RECORDS = 2000, RECORD = 64 };

static void pause_ms(long ms)
{
	struct timespec t = { ms / 1000, (ms % 1000) * 1000000L };
	nanosleep(&t, NULL);
}

static int stream_fd;
static void *stream_writer(void *unused)
{
	(void)unused;
	unsigned char chunk[CHUNK];
	for (long sent = 0; sent < STREAM_BYTES;) {
		int n = STREAM_BYTES - sent < CHUNK ? (int)(STREAM_BYTES - sent) : CHUNK;
		for (int i = 0; i < n; i++)
			chunk[i] = (unsigned char)((sent + i) * 31);
		ssize_t w = write(stream_fd, chunk, n);
		if (w <= 0)
			return (void *)1;
		sent += w;
	}
	close(stream_fd);
	return NULL;
}

static int record_fd;
static void *record_writer(void *argument)
{
	long id = (long)argument;
	char record[RECORD];
	for (int i = 0; i < RECORDS; i++) {
		memset(record, 'a' + (int)id, sizeof record);
		snprintf(record, sizeof record, "%ld:%05d:", id, i);
		record[strlen(record)] = 'a' + (int)id; /* no NUL inside the record */
		if (write(record_fd, record, RECORD) != RECORD)
			return (void *)1;
	}
	return NULL;
}

static int delayed_fd;
static void *delayed_writer(void *unused)
{
	(void)unused;
	pause_ms(30);
	uint64_t one = 1;
	return write(delayed_fd, &one, 8) == 8 ? NULL : (void *)1;
}

int main(void)
{
	int p[2];
	char buffer[4096];

	/* Basics: data, file type, no seeking. */
	CHECK(pipe(p) == 0, "pipe");
	struct stat status;
	CHECK(fstat(p[0], &status) == 0 && S_ISFIFO(status.st_mode), "fstat reports a FIFO");
	CHECK(write(p[1], "hello", 5) == 5 && read(p[0], buffer, sizeof buffer) == 5 && memcmp(buffer, "hello", 5) == 0, "round trip");
	errno = 0;
	CHECK(lseek(p[0], 0, SEEK_SET) == -1 && errno == ESPIPE, "lseek on a pipe is ESPIPE");

	/* End of file after the last writer closes; EPIPE after the last reader. */
	CHECK(close(p[1]) == 0 && read(p[0], buffer, sizeof buffer) == 0, "end of file");
	close(p[0]);
	CHECK(pipe(p) == 0 && close(p[0]) == 0, "second pipe");
	errno = 0;
	CHECK(write(p[1], "x", 1) == -1 && errno == EPIPE, "EPIPE with no reader");
	close(p[1]);

	/* Nonblocking: empty read, and filling to capacity. */
	CHECK(pipe2(p, O_NONBLOCK | O_CLOEXEC) == 0, "pipe2");
	CHECK((fcntl(p[0], F_GETFL) & O_NONBLOCK) && (fcntl(p[0], F_GETFD) & FD_CLOEXEC), "pipe2 flags");
	errno = 0;
	CHECK(read(p[0], buffer, 1) == -1 && errno == EAGAIN, "EAGAIN on empty");
	long capacity = 0;
	memset(buffer, 0x5c, sizeof buffer);
	for (;;) {
		ssize_t w = write(p[1], buffer, sizeof buffer);
		if (w < 0)
			break;
		capacity += w;
	}
	CHECK(errno == EAGAIN && capacity == 65536, "a full pipe holds 64 KiB");
	long drained = 0;
	for (ssize_t r; (r = read(p[0], buffer, sizeof buffer)) > 0;)
		drained += r;
	CHECK(drained == capacity, "drain");
	close(p[0]);
	close(p[1]);

	/* A blocking reader woken by a writer thread; 1 MiB intact. */
	CHECK(pipe(p) == 0, "stream pipe");
	stream_fd = p[1];
	pthread_t writer;
	CHECK(pthread_create(&writer, NULL, stream_writer, NULL) == 0, "stream thread");
	long received = 0;
	int intact = 1;
	for (ssize_t r; (r = read(p[0], buffer, sizeof buffer)) > 0; received += r)
		for (ssize_t i = 0; i < r; i++)
			intact &= (unsigned char)buffer[i] == (unsigned char)((received + i) * 31);
	void *result;
	CHECK(pthread_join(writer, &result) == 0 && result == NULL, "stream writer");
	CHECK(intact && received == STREAM_BYTES, "1 MiB stream intact, then end of file");
	close(p[0]);

	/* Writes up to PIPE_BUF from concurrent writers never interleave. */
	CHECK(pipe(p) == 0, "record pipe");
	record_fd = p[1];
	pthread_t writers[WRITERS];
	for (long i = 0; i < WRITERS; i++)
		CHECK(pthread_create(&writers[i], NULL, record_writer, (void *)i) == 0, "record thread");
	int next[WRITERS] = { 0 };
	for (int total = 0; total < WRITERS * RECORDS; total++) {
		char record[RECORD];
		int have = 0;
		while (have < RECORD) {
			ssize_t r = read(p[0], record + have, RECORD - have);
			CHECK(r > 0, "record read");
			have += r;
		}
		long id;
		int number;
		CHECK(sscanf(record, "%ld:%d:", &id, &number) == 2 && id >= 0 && id < WRITERS, "record header");
		CHECK(number == next[id]++, "records in order per writer");
		for (int i = (int)strcspn(record, ":") + 7; i < RECORD; i++)
			CHECK(record[i] == 'a' + id, "record body not interleaved");
	}
	for (int i = 0; i < WRITERS; i++)
		CHECK(pthread_join(writers[i], &result) == 0 && result == NULL, "record writer");
	close(p[0]);
	close(p[1]);

	/* eventfd: counter, semaphore, nonblocking, and a blocking wake. */
	uint64_t value;
	int e = eventfd(3, 0);
	CHECK(e >= 0 && read(e, &value, 8) == 8 && value == 3, "eventfd initial value");
	value = 5;
	CHECK(write(e, &value, 8) == 8, "eventfd add");
	value = 7;
	CHECK(write(e, &value, 8) == 8 && read(e, &value, 8) == 8 && value == 12, "eventfd sums writes");
	CHECK(fcntl(e, F_SETFL, O_NONBLOCK) == 0, "eventfd nonblocking");
	errno = 0;
	CHECK(read(e, &value, 8) == -1 && errno == EAGAIN, "eventfd empty");
	close(e);
	e = eventfd(2, EFD_SEMAPHORE | EFD_NONBLOCK);
	CHECK(read(e, &value, 8) == 8 && value == 1 && read(e, &value, 8) == 8 && value == 1, "semaphore reads");
	errno = 0;
	CHECK(read(e, &value, 8) == -1 && errno == EAGAIN, "semaphore exhausted");
	close(e);
	delayed_fd = eventfd(0, 0);
	CHECK(pthread_create(&writer, NULL, delayed_writer, NULL) == 0, "eventfd thread");
	CHECK(read(delayed_fd, &value, 8) == 8 && value == 1, "blocking eventfd read woken");
	CHECK(pthread_join(writer, &result) == 0 && result == NULL, "eventfd writer");
	close(delayed_fd);

	/* dup family: shared offset and status, private close-on-exec. */
	int file = open("/etc/motd", O_RDONLY);
	int copy = dup(file);
	CHECK(file >= 3 && copy > file, "dup");
	CHECK(read(file, buffer, 5) == 5 && read(copy, buffer, 5) == 5 && memcmp(buffer, "me to", 5) == 0, "dup shares the offset");
	CHECK(dup2(file, 100) == 100 && lseek(100, 0, SEEK_CUR) == 10, "dup2 to a chosen number");
	CHECK(dup2(100, 100) == 100, "dup2 onto itself");
	errno = 0;
	CHECK(dup3(100, 100, 0) == -1 && errno == EINVAL, "dup3 onto itself is EINVAL");
	int high = fcntl(file, F_DUPFD_CLOEXEC, 50);
	CHECK(high == 50 && (fcntl(high, F_GETFD) & FD_CLOEXEC) && !(fcntl(file, F_GETFD) & FD_CLOEXEC), "F_DUPFD_CLOEXEC");
	CHECK(fcntl(file, F_SETFD, FD_CLOEXEC) == 0 && (fcntl(file, F_GETFD) & FD_CLOEXEC) && !(fcntl(copy, F_GETFD) & FD_CLOEXEC), "close-on-exec is per descriptor");
	CHECK(pipe(p) == 0, "status pipe");
	int reader_copy = dup(p[0]);
	CHECK(fcntl(p[0], F_SETFL, O_NONBLOCK) == 0 && (fcntl(reader_copy, F_GETFL) & O_NONBLOCK), "status flags are shared");
	errno = 0;
	CHECK(read(reader_copy, buffer, 1) == -1 && errno == EAGAIN, "shared nonblocking");
	CHECK(close(p[1]) == 0 && close(p[0]) == 0 && read(reader_copy, buffer, 1) == 0, "end of file through a duplicate");
	close(reader_copy);
	errno = 0;
	CHECK(dup(999) == -1 && errno == EBADF && close(999) == -1, "bad descriptors");
	close(high);
	close(100);
	close(copy);
	close(file);

	/* The descriptor limit, and recovery after closing. */
	int opened[300], count = 0;
	while (count < 300 && (opened[count] = open("/etc/motd", O_RDONLY)) >= 0)
		count++;
	CHECK(count > 240 && count < 256 && errno == EMFILE, "EMFILE at the descriptor limit");
	for (int i = 0; i < count; i++)
		close(opened[i]);
	int again = open("/etc/motd", O_RDONLY);
	CHECK(again == 3, "descriptors reused from the lowest");
	close(again);

	printf("pipe-probe: PASS pipes (EOF, EPIPE, nonblocking, 64 KiB, 1 MiB stream, atomic writes from %d threads), "
	       "eventfd, dup family and %d descriptors\n",
	       WRITERS, count);
	return 0;
}
