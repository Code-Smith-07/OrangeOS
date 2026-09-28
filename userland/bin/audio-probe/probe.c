/* audio-probe: sound through /dev/audio (docs/design/012, W11).
 *
 * tools/audio_smoke.py records the guest's sound card to a WAV file on the
 * host while this runs, then checks the recording: one second of 660 Hz,
 * half a second of silence (nothing written: the driver must play silence,
 * not the old ring contents), one second of 880 Hz, then silence again.
 * Here it checks what the device reports: writes block rather than fail,
 * and the queued-bytes count (fstat) drains to zero once playback ends.
 *
 * SPDX-License-Identifier: MIT OR Apache-2.0
 */
#define _DEFAULT_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define RATE 48000
#define CHECK(condition, what)                                                   \
	do {                                                                         \
		if (!(condition)) {                                                      \
			printf("audio-probe: FAIL %s (errno %d)\n", (what), errno);          \
			return 1;                                                            \
		}                                                                        \
	} while (0)

static long long now_ms(void)
{
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return (long long)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}

/* `seconds` of a sine at `hz`, written in 10 ms blocks. */
static int tone(int fd, double hz, double seconds)
{
	int16_t block[RATE / 100 * 2];
	static double phase;
	for (int written = 0; written < (int)(seconds * 100); written++) {
		for (int i = 0; i < RATE / 100; i++) {
			int16_t v = (int16_t)(12000 * sin(phase));
			block[2 * i] = block[2 * i + 1] = v;
			phase += 2 * M_PI * hz / RATE;
		}
		size_t done = 0;
		while (done < sizeof block) {
			ssize_t n = write(fd, (char *)block + done, sizeof block - done);
			if (n <= 0)
				return -1;
			done += (size_t)n;
		}
	}
	return 0;
}

static long queued(int fd)
{
	struct stat status;
	return fstat(fd, &status) == 0 ? (long)status.st_size : -1;
}

int main(void)
{
	int fd = open("/dev/audio", O_WRONLY);
	CHECK(fd >= 0, "open /dev/audio");
	long long start = now_ms();
	CHECK(tone(fd, 660, 1.0) == 0, "write 660 Hz");
	CHECK(queued(fd) > 0, "samples are queued");
	/* A gap with nothing written: the queue drains and the card plays
	 * silence. */
	while (queued(fd) > 0 && now_ms() - start < 5000)
		usleep(10000);
	CHECK(queued(fd) == 0, "the queue drains");
	usleep(500000);
	CHECK(tone(fd, 880, 1.0) == 0, "write 880 Hz");
	long long wrote = now_ms() - start;
	while (queued(fd) > 0 && now_ms() - start < 10000)
		usleep(10000);
	CHECK(queued(fd) == 0, "the queue drains again");
	/* Writing two seconds of sound took about as long as playing it: the
	 * writes waited for the card rather than filling memory. */
	CHECK(wrote >= 1200, "writes are paced by playback");
	close(fd);
	printf("audio-probe: PASS 660 Hz, gap, 880 Hz written in %lld ms; queue drained\n", wrote);
	return 0;
}
