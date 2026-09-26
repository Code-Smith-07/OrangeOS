/* Shared memory and file mappings through musl on OrangeOS: memfd_create,
 * MAP_SHARED views that alias each other and the descriptor's read/write,
 * a memfd shared with a spawned child, seals (write, shrink, seal) with
 * EBUSY and EPERM where Linux gives them, MADV_DONTNEED keeping shared
 * contents, shared mappings of an unlinked file, MAP_PRIVATE file mappings,
 * and every page returned to /tmp afterwards.
 *
 * SPDX-License-Identifier: MIT OR Apache-2.0
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <spawn.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <sys/wait.h>
#include <unistd.h>

#define CHECK(condition, what)                                                   \
	do {                                                                         \
		if (!(condition)) {                                                      \
			printf("shm-probe: FAIL %s (errno %d)\n", (what), errno);            \
			return 1;                                                            \
		}                                                                        \
	} while (0)

#define PAGE 4096
#define SIZE (4 * 1024 * 1024)

int main(void)
{
	struct statvfs before, after;
	CHECK(statvfs("/tmp", &before) == 0, "statvfs");

	/* A memfd, two shared views and the descriptor all see one set of pages. */
	int memfd = memfd_create("probe", MFD_CLOEXEC | MFD_ALLOW_SEALING);
	CHECK(memfd >= 0 && ftruncate(memfd, SIZE) == 0, "memfd_create and size");
	struct stat st;
	CHECK(fstat(memfd, &st) == 0 && st.st_size == SIZE && (fcntl(memfd, F_GETFD) & FD_CLOEXEC), "memfd status");
	unsigned char *view = mmap(NULL, SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, memfd, 0);
	unsigned char *other = mmap(NULL, 2 * PAGE, PROT_READ, MAP_SHARED, memfd, 0);
	CHECK(view != MAP_FAILED && other != MAP_FAILED && view != other, "two shared views");
	for (int i = 0; i < PAGE; i++)
		view[i] = (unsigned char)(i * 7);
	CHECK(other[100] == (unsigned char)700 && other[PAGE - 1] == (unsigned char)((PAGE - 1) * 7), "views alias");
	unsigned char read_back[16];
	CHECK(pread(memfd, read_back, 16, 0) == 16 && read_back[3] == 21, "the descriptor reads what the view wrote");
	CHECK(pwrite(memfd, "fd->map", 7, 3 * PAGE) == 7 && memcmp(view + 3 * PAGE, "fd->map", 7) == 0, "the view sees what the descriptor wrote");
	CHECK(view[SIZE - 1] == 0, "untouched shared pages read zero");

	/* A spawned child maps the same memfd and answers through it. */
	posix_spawn_file_actions_t actions;
	posix_spawn_file_actions_init(&actions);
	posix_spawn_file_actions_adddup2(&actions, memfd, 3);
	char *argv[] = { "spawn-child", "shm", NULL };
	pid_t pid;
	int status;
	CHECK(posix_spawn(&pid, "/bin/spawn-child", &actions, NULL, argv, NULL) == 0, "spawn the child");
	posix_spawn_file_actions_destroy(&actions);
	CHECK(waitpid(pid, &status, 0) == pid && WEXITSTATUS(status) == 0, "the child checked the pattern");
	CHECK(memcmp(view + PAGE, "child was here", 15) == 0, "the parent sees the child's write");

	/* Shared contents survive MADV_DONTNEED; a mapped memfd cannot shrink. */
	CHECK(madvise(view, 2 * PAGE, MADV_DONTNEED) == 0 && view[100] == (unsigned char)700, "DONTNEED keeps shared contents");
	errno = 0;
	CHECK(ftruncate(memfd, PAGE) == -1 && errno == EBUSY, "a mapped memfd cannot shrink");
	CHECK(ftruncate(memfd, 2 * SIZE) == 0 && ftruncate(memfd, SIZE) == -1, "it can grow, then not shrink back");

	/* Seals. */
	errno = 0;
	CHECK(fcntl(memfd, F_ADD_SEALS, F_SEAL_WRITE) == -1 && errno == EBUSY, "no write seal while writably mapped");
	CHECK(munmap(view, SIZE) == 0 && fcntl(memfd, F_ADD_SEALS, F_SEAL_WRITE | F_SEAL_GROW) == 0, "write seal once unmapped");
	CHECK(fcntl(memfd, F_GET_SEALS) == (F_SEAL_WRITE | F_SEAL_GROW), "F_GET_SEALS");
	errno = 0;
	CHECK(write(memfd, "x", 1) == -1 && errno == EPERM, "writes refused");
	errno = 0;
	CHECK(mmap(NULL, PAGE, PROT_READ | PROT_WRITE, MAP_SHARED, memfd, 0) == MAP_FAILED && errno == EPERM, "writable mapping refused");
	unsigned char *sealed = mmap(NULL, PAGE, PROT_READ, MAP_SHARED, memfd, 0);
	CHECK(sealed != MAP_FAILED && sealed[100] == (unsigned char)700, "read-only mapping of a sealed memfd");
	errno = 0;
	CHECK(mprotect(sealed, PAGE, PROT_READ | PROT_WRITE) == -1, "cannot make it writable");
	CHECK(fcntl(memfd, F_ADD_SEALS, F_SEAL_SEAL) == 0, "seal the seals");
	errno = 0;
	CHECK(fcntl(memfd, F_ADD_SEALS, F_SEAL_SHRINK) == -1 && errno == EPERM, "no more seals");
	int unsealable = memfd_create("plain", 0);
	errno = 0;
	CHECK(unsealable >= 0 && fcntl(unsealable, F_ADD_SEALS, F_SEAL_WRITE) == -1 && errno == EPERM, "sealing needs MFD_ALLOW_SEALING");
	close(unsealable);
	munmap(sealed, PAGE);
	munmap(other, 2 * PAGE);
	close(memfd);

	/* A shared mapping outlives the file's name. */
	int file = open("/tmp/shm-file", O_RDWR | O_CREAT | O_TRUNC, 0644);
	CHECK(file >= 0 && ftruncate(file, PAGE) == 0, "a /tmp file");
	char *named = mmap(NULL, PAGE, PROT_READ | PROT_WRITE, MAP_SHARED, file, 0);
	CHECK(named != MAP_FAILED && unlink("/tmp/shm-file") == 0 && close(file) == 0, "map, unlink, close");
	strcpy(named, "still here");
	CHECK(strcmp(named, "still here") == 0 && munmap(named, PAGE) == 0, "the mapping keeps the file");

	/* Private file mappings: a copy of the file, writable without changing it. */
	int motd = open("/etc/motd", O_RDONLY);
	char *text = mmap(NULL, PAGE, PROT_READ, MAP_PRIVATE, motd, 0);
	CHECK(text != MAP_FAILED && memcmp(text, "Welcome to Orange OS.\n", 22) == 0 && text[22] == 0, "MAP_PRIVATE of a disk file");
	char *copy = mmap(NULL, PAGE, PROT_READ | PROT_WRITE, MAP_PRIVATE, motd, 0);
	CHECK(copy != MAP_FAILED && (copy[0] = 'w') == 'w' && text[0] == 'W', "private copies are private");
	errno = 0;
	CHECK(mmap(NULL, PAGE, PROT_READ | PROT_WRITE, MAP_SHARED, motd, 0) == MAP_FAILED && errno == EACCES, "no writable sharing on the read-only disk");
	char *shared_ro = mmap(NULL, PAGE, PROT_READ, MAP_SHARED, motd, 0);
	CHECK(shared_ro != MAP_FAILED && shared_ro[1] == 'e', "read-only sharing of a disk file");
	munmap(text, PAGE);
	munmap(copy, PAGE);
	munmap(shared_ro, PAGE);
	close(motd);

	CHECK(statvfs("/tmp", &after) == 0 && after.f_bfree == before.f_bfree, "every shared page returned");
	printf("shm-probe: PASS memfd, aliasing shared views, a child sharing a memfd, seals, DONTNEED, "
	       "unlinked mappings, MAP_PRIVATE files, pages returned\n");
	return 0;
}
