/* A C11 program built against musl, running natively on OrangeOS: startup
 * arguments, stdio and formatting, number parsing, malloc, qsort, clocks and
 * sleeping, file reads and stat, errno for missing files and the read-only
 * filesystem, thread-local storage, and POSIX threads coordinating through a
 * mutex and a condition variable.
 *
 * SPDX-License-Identifier: MIT OR Apache-2.0
 */
#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <pthread.h>
#include <sched.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/utsname.h>
#include <time.h>

#define CHECK(condition, what)                                                   \
	do {                                                                         \
		if (!(condition)) {                                                      \
			printf("musl-probe: FAIL %s (errno %d)\n", (what), errno);           \
			return 1;                                                            \
		}                                                                        \
	} while (0)

enum { THREADS = 4, ROUNDS = 5000 };

static __thread int tls_value = 7;
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t changed = PTHREAD_COND_INITIALIZER;
static long counter;
static int finished;

static void *worker(void *argument)
{
	long id = (long)argument;
	/* Every thread starts from the program's TLS image, not a copy of main's. */
	if (tls_value != 7)
		return (void *)-1L;
	tls_value = (int)id * 100;
	for (int i = 0; i < ROUNDS; i++) {
		pthread_mutex_lock(&lock);
		counter++;
		pthread_mutex_unlock(&lock);
		if (i % 1000 == 0)
			sched_yield();
	}
	pthread_mutex_lock(&lock);
	finished++;
	pthread_cond_broadcast(&changed);
	pthread_mutex_unlock(&lock);
	return (void *)(long)(tls_value + 1);
}

static int compare(const void *a, const void *b)
{
	int x = *(const int *)a, y = *(const int *)b;
	return (x > y) - (x < y);
}

int main(int argc, char **argv)
{
	CHECK(argc == 1 && argv[0] && strcmp(argv[0], "/bin/musl-probe") == 0, "argv");
	struct utsname system;
	CHECK(uname(&system) == 0 && strcmp(system.sysname, "OrangeOS") == 0, "uname");

	char text[96];
	snprintf(text, sizeof text, "%d %5.2f %e %x %s", -42, 3.14159, 1e-10, 0xbeef, "ok");
	CHECK(strcmp(text, "-42  3.14 1.000000e-10 beef ok") == 0, "formatting");
	CHECK(strtod("2.5e3", NULL) == 2500.0 && atoi("123") == 123, "number parsing");

	int values[64];
	for (int i = 0; i < 64; i++)
		values[i] = (i * 37) % 64;
	qsort(values, 64, sizeof values[0], compare);
	for (int i = 0; i < 64; i++)
		CHECK(values[i] == i, "qsort");

	char *small = malloc(24);
	char *large = malloc(3 << 20);
	CHECK(small && large, "malloc");
	memset(large, 0x5a, 3 << 20);
	CHECK(large[(3 << 20) - 1] == 0x5a, "large allocation");
	strcpy(small, "carried");
	char *grown = realloc(small, 4096);
	CHECK(grown && strcmp(grown, "carried") == 0, "realloc");
	free(grown);
	free(large);

	struct timespec before, after, pause = { 0, 20 * 1000 * 1000 };
	CHECK(clock_gettime(CLOCK_MONOTONIC, &before) == 0, "monotonic clock");
	CHECK(nanosleep(&pause, NULL) == 0, "nanosleep");
	CHECK(clock_gettime(CLOCK_MONOTONIC, &after) == 0, "monotonic clock again");
	long elapsed = (after.tv_sec - before.tv_sec) * 1000000000L + (after.tv_nsec - before.tv_nsec);
	CHECK(elapsed >= 20 * 1000 * 1000, "sleep duration");
	CHECK(time(NULL) > 1700000000, "wall clock");

	FILE *motd = fopen("/etc/motd", "r");
	CHECK(motd != NULL, "fopen");
	char line[64];
	CHECK(fgets(line, sizeof line, motd) && strcmp(line, "Welcome to Orange OS.\n") == 0, "fgets");
	fclose(motd);
	struct stat status;
	CHECK(stat("/etc/motd", &status) == 0 && S_ISREG(status.st_mode) && status.st_size == 22, "stat file");
	CHECK(stat("/bin", &status) == 0 && S_ISDIR(status.st_mode), "stat directory");
	errno = 0;
	CHECK(fopen("/etc/missing", "r") == NULL && errno == ENOENT, "missing file");
	errno = 0;
	CHECK(fopen("/etc/motd", "w") == NULL && errno == EROFS, "read-only filesystem");

	pthread_t threads[THREADS];
	for (long i = 0; i < THREADS; i++)
		CHECK(pthread_create(&threads[i], NULL, worker, (void *)(i + 1)) == 0, "pthread_create");
	pthread_mutex_lock(&lock);
	while (finished < THREADS)
		pthread_cond_wait(&changed, &lock);
	pthread_mutex_unlock(&lock);
	for (long i = 0; i < THREADS; i++) {
		void *result;
		CHECK(pthread_join(threads[i], &result) == 0, "pthread_join");
		CHECK((long)result == (i + 1) * 100 + 1, "thread result and TLS");
	}
	CHECK(counter == THREADS * ROUNDS, "mutex-protected counter");
	CHECK(tls_value == 7, "main thread TLS untouched");

	printf("musl-probe: PASS stdio, formatting, malloc, qsort, clocks, files, TLS and %d pthreads\n", THREADS);
	return 0;
}
