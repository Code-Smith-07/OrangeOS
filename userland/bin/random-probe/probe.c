/* Randomness and device files through musl on OrangeOS: getrandom (blocking
 * and GRND_NONBLOCK), getentropy and its 256-byte limit, 1 MiB of
 * /dev/urandom passing byte-frequency and bit-balance checks, successive
 * outputs differing, /dev/random, /dev/null, /dev/zero (read and mapped),
 * character-device status, the /dev listing, and /dev refusing changes.
 *
 * SPDX-License-Identifier: MIT OR Apache-2.0
 */
#define _DEFAULT_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/random.h>
#include <sys/stat.h>
#include <unistd.h>

#define CHECK(condition, what)                                                   \
	do {                                                                         \
		if (!(condition)) {                                                      \
			printf("random-probe: FAIL %s (errno %d)\n", (what), errno);         \
			return 1;                                                            \
		}                                                                        \
	} while (0)

enum { SAMPLE = 1024 * 1024 };
static unsigned char sample[SAMPLE];

int main(void)
{
	unsigned char a[64], b[64], zero[64] = { 0 };
	CHECK(getrandom(a, sizeof a, 0) == (ssize_t)sizeof a, "getrandom");
	CHECK(getrandom(b, sizeof b, GRND_NONBLOCK) == (ssize_t)sizeof b, "getrandom GRND_NONBLOCK once seeded");
	CHECK(memcmp(a, b, sizeof a) != 0 && memcmp(a, zero, sizeof a) != 0, "outputs differ and are not zero");
	CHECK(getentropy(sample, 256) == 0, "getentropy 256");
	errno = 0;
	CHECK(getentropy(sample, 257) == -1 && errno == EIO, "getentropy refuses more than 256");

	/* 1 MiB from /dev/urandom: every byte value near 4096 times, bits balanced. */
	int urandom = open("/dev/urandom", O_RDONLY | O_CLOEXEC);
	CHECK(urandom >= 0, "open /dev/urandom");
	for (size_t got = 0; got < SAMPLE;) {
		ssize_t n = read(urandom, sample + got, SAMPLE - got);
		CHECK(n > 0, "read /dev/urandom");
		got += n;
	}
	close(urandom);
	long counts[256] = { 0 }, ones = 0;
	for (size_t i = 0; i < SAMPLE; i++) {
		counts[sample[i]]++;
		ones += __builtin_popcount(sample[i]);
	}
	double chi = 0;
	for (int v = 0; v < 256; v++) {
		double d = counts[v] - SAMPLE / 256.0;
		chi += d * d / (SAMPLE / 256.0);
	}
	/* 255 degrees of freedom: 99.99% of truly random samples fall below 360. */
	CHECK(chi > 150 && chi < 360, "byte frequencies look uniform");
	long expected = SAMPLE * 4L;
	CHECK(ones > expected - 8000 && ones < expected + 8000, "bits balanced");

	int random_device = open("/dev/random", O_RDONLY);
	CHECK(random_device >= 0 && read(random_device, a, 32) == 32, "/dev/random once seeded");
	close(random_device);

	/* /dev/null and /dev/zero. */
	int null = open("/dev/null", O_RDWR | O_TRUNC);
	CHECK(null >= 0 && write(null, "gone", 4) == 4 && read(null, a, sizeof a) == 0, "/dev/null");
	struct stat st;
	CHECK(fstat(null, &st) == 0 && S_ISCHR(st.st_mode) && stat("/dev/urandom", &st) == 0 && S_ISCHR(st.st_mode), "character devices");
	close(null);
	int zero_device = open("/dev/zero", O_RDONLY);
	memset(a, 0xff, sizeof a);
	CHECK(zero_device >= 0 && read(zero_device, a, sizeof a) == (ssize_t)sizeof a && memcmp(a, zero, sizeof a) == 0, "/dev/zero reads");
	unsigned char *zeros = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_PRIVATE, zero_device, 0);
	CHECK(zeros != MAP_FAILED && zeros[4095] == 0 && (zeros[0] = 1) == 1, "a private mapping of /dev/zero");
	munmap(zeros, 4096);
	close(zero_device);

	/* The listing, and no changes under /dev. */
	DIR *dir = opendir("/dev");
	CHECK(dir != NULL, "opendir /dev");
	int found = 0;
	struct dirent *entry;
	while ((entry = readdir(dir)))
		if (entry->d_type == DT_CHR && (strcmp(entry->d_name, "null") == 0 || strcmp(entry->d_name, "zero") == 0 ||
		                                strcmp(entry->d_name, "random") == 0 || strcmp(entry->d_name, "urandom") == 0))
			found++;
	closedir(dir);
	CHECK(found == 4, "the four devices are listed");
	errno = 0;
	CHECK(open("/dev/new", O_WRONLY | O_CREAT, 0644) == -1 && errno == EROFS, "no new files in /dev");
	errno = 0;
	CHECK(unlink("/dev/null") == -1 && errno == EROFS, "no removal in /dev");

	printf("random-probe: PASS getrandom, getentropy, 1 MiB urandom (chi-square %.0f), /dev/random, /dev/null, /dev/zero, /dev listing\n", chi);
	return 0;
}
