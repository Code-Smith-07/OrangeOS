/* Thread capacity of one program: POSIX threads, each with its own mapped
 * stack, are created until the per-program limit refuses one with EAGAIN.
 * All of them are then released, joined and checked, and a second wave shows
 * the capacity comes back.
 *
 * SPDX-License-Identifier: MIT OR Apache-2.0
 */
#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <pthread.h>
#include <stdio.h>
#include <time.h>

/* The kernel's per-program limit is 512 live threads, main included. */
enum { EXPECTED = 511, ATTEMPTS = 600 };

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t arrived = PTHREAD_COND_INITIALIZER;
static pthread_cond_t release = PTHREAD_COND_INITIALIZER;
static int started, released;
static pthread_t threads[ATTEMPTS];

static void *parked(void *argument)
{
	pthread_mutex_lock(&lock);
	started++;
	pthread_cond_signal(&arrived);
	while (!released)
		pthread_cond_wait(&release, &lock);
	pthread_mutex_unlock(&lock);
	return argument;
}

/* One wave: the number of threads created, or -1 on a wrong result. */
static int wave(void)
{
	pthread_attr_t attributes;
	pthread_attr_init(&attributes);
	pthread_attr_setstacksize(&attributes, 16 * 1024);
	started = 0;
	released = 0;
	int count = 0, error = 0;
	while (count < ATTEMPTS && (error = pthread_create(&threads[count], &attributes, parked, (void *)(long)count)) == 0)
		count++;
	pthread_attr_destroy(&attributes);
	if (count == ATTEMPTS || error != EAGAIN) {
		printf("thread-capacity: FAIL %d threads, then error %d instead of EAGAIN\n", count, error);
		return -1;
	}
	pthread_mutex_lock(&lock);
	while (started < count)
		pthread_cond_wait(&arrived, &lock);
	released = 1;
	pthread_cond_broadcast(&release);
	pthread_mutex_unlock(&lock);
	for (int i = 0; i < count; i++) {
		void *result;
		if (pthread_join(threads[i], &result) != 0 || (long)result != i) {
			printf("thread-capacity: FAIL join %d\n", i);
			return -1;
		}
	}
	return count;
}

int main(void)
{
	int first = wave();
	/* Exited threads leave records until the kernel's reaper collects them. */
	struct timespec pause = { 0, 300 * 1000 * 1000 };
	nanosleep(&pause, NULL);
	int second = wave();
	if (first != EXPECTED || second != EXPECTED) {
		printf("thread-capacity: FAIL waves of %d and %d threads, expected %d\n", first, second, EXPECTED);
		return 1;
	}
	printf("thread-capacity: PASS 2 waves of %d concurrent threads, EAGAIN beyond, all joined\n", EXPECTED);
	return 0;
}
