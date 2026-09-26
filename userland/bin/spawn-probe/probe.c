/* Launching programs through musl on OrangeOS: posix_spawn and posix_spawnp
 * with arguments, environment, file actions (dup2, close, open, chdir) and
 * descriptor inheritance by close-on-exec; stdio redirection through pipes;
 * a socket handed to a child and a descriptor passed to it across processes;
 * waitpid with WNOHANG; and the working directory with chdir, fchdir and
 * *at() calls relative to directory descriptors.
 *
 * SPDX-License-Identifier: MIT OR Apache-2.0
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#define CHECK(condition, what)                                                   \
	do {                                                                         \
		if (!(condition)) {                                                      \
			printf("spawn-probe: FAIL %s (errno %d)\n", (what), errno);          \
			return 1;                                                            \
		}                                                                        \
	} while (0)

#define CHILD "/bin/spawn-child"

/* Read everything from `fd` into `out` until end of file. */
static ssize_t slurp(int fd, char *out, size_t size)
{
	size_t used = 0;
	ssize_t n;
	while (used + 1 < size && (n = read(fd, out + used, size - 1 - used)) > 0)
		used += n;
	out[used] = 0;
	return n < 0 ? -1 : (ssize_t)used;
}

/* Start CHILD with `argv`, stdout to a pipe; return its output and status. */
static int run(char *const argv[], char *const envp[], posix_spawn_file_actions_t *extra, char *out, size_t size, int *status)
{
	int p[2];
	if (pipe2(p, O_CLOEXEC) != 0)
		return -1;
	posix_spawn_file_actions_t local, *actions = extra;
	if (!actions) {
		posix_spawn_file_actions_init(&local);
		actions = &local;
	}
	posix_spawn_file_actions_adddup2(actions, p[1], 1);
	pid_t pid;
	int error = posix_spawn(&pid, CHILD, actions, NULL, argv, envp);
	if (!extra)
		posix_spawn_file_actions_destroy(&local);
	close(p[1]);
	if (error != 0) {
		close(p[0]);
		errno = error;
		return -1;
	}
	ssize_t n = slurp(p[0], out, size);
	close(p[0]);
	if (n < 0 || waitpid(pid, status, 0) != pid)
		return -1;
	return 0;
}

extern char **environ;

int main(void)
{
	char out[1024], cwd[256];
	int status;

	/* The console is a real description: dup(1) works. */
	int saved = dup(1);
	struct stat st;
	CHECK(saved >= 3 && fstat(saved, &st) == 0 && S_ISCHR(st.st_mode), "dup of stdout");
	close(saved);

	/* Working directory, chdir/fchdir, and *at() relative to a directory. */
	CHECK(getcwd(cwd, sizeof cwd) && strcmp(cwd, "/") == 0, "starts at /");
	CHECK(mkdir("/tmp/spawn", 0755) == 0 && chdir("/tmp/spawn") == 0, "chdir");
	CHECK(getcwd(cwd, sizeof cwd) && strcmp(cwd, "/tmp/spawn") == 0, "getcwd after chdir");
	int file = open("relative.txt", O_WRONLY | O_CREAT, 0644);
	CHECK(file >= 0 && write(file, "rel", 3) == 3 && close(file) == 0, "create relative to the working directory");
	CHECK(stat("/tmp/spawn/relative.txt", &st) == 0 && st.st_size == 3, "relative path landed in the directory");
	CHECK(mkdir("sub", 0755) == 0, "relative mkdir");
	int dir = open("sub", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
	CHECK(dir >= 0, "open a directory");
	int through = openat(dir, "../relative.txt", O_RDONLY);
	CHECK(through >= 0 && read(through, out, 3) == 3 && memcmp(out, "rel", 3) == 0, "openat relative to a directory descriptor");
	close(through);
	CHECK(fstatat(dir, "..", &st, 0) == 0 && S_ISDIR(st.st_mode), "fstatat relative to a directory descriptor");
	CHECK(mkdirat(dir, "deeper", 0755) == 0 && stat("/tmp/spawn/sub/deeper", &st) == 0, "mkdirat");
	CHECK(fchdir(dir) == 0 && getcwd(cwd, sizeof cwd) && strcmp(cwd, "/tmp/spawn/sub") == 0, "fchdir");
	errno = 0;
	CHECK(chdir("/missing") == -1 && errno == ENOENT, "chdir to nothing");
	errno = 0;
	CHECK(chdir("/etc/motd") == -1 && errno == ENOTDIR, "chdir to a file");
	CHECK(chdir("..") == 0 && getcwd(cwd, sizeof cwd) && strcmp(cwd, "/tmp/spawn") == 0, "chdir ..");

	/* Arguments and environment. */
	char *echo[] = { "spawn-child", "echo", "two words", "", "last", NULL };
	char *env[] = { "FOO=bar baz", "EMPTY=", NULL };
	CHECK(run(echo, env, NULL, out, sizeof out, &status) == 0 && WIFEXITED(status) && WEXITSTATUS(status) == 0, "spawn echo");
	CHECK(strcmp(out, "argc=5\n[spawn-child]\n[echo]\n[two words]\n[]\n[last]\nFOO=bar baz EMPTY= MISSING=(unset)\n") == 0, "argv and environment arrive intact");

	/* Inheritance follows close-on-exec; the child's descriptors are exact. */
	int keep[2], drop[2];
	CHECK(pipe(keep) == 0 && pipe2(drop, O_CLOEXEC) == 0, "pipes for inheritance");
	char *fds[] = { "spawn-child", "fds", NULL };
	CHECK(run(fds, NULL, NULL, out, sizeof out, &status) == 0 && WEXITSTATUS(status) == 0, "spawn fds");
	char expected[64];
	snprintf(expected, sizeof expected, "open: 0 1 2 %d %d\n", keep[0], keep[1]);
	CHECK(strcmp(out, expected) == 0, "inherits exactly the descriptors without close-on-exec");
	close(keep[0]);
	close(keep[1]);
	close(drop[0]);
	close(drop[1]);

	/* File actions: open at a chosen number, chdir, close. */
	posix_spawn_file_actions_t actions;
	posix_spawn_file_actions_init(&actions);
	/* A number clear of the pipe run() adds: actions act on the child's
	 * table in order, so opening onto a descriptor later dup2'd from would
	 * change what the dup2 copies. */
	posix_spawn_file_actions_addopen(&actions, 20, "/etc/motd", O_RDONLY, 0);
	char *motd[] = { "spawn-child", "motd20", NULL };
	CHECK(run(motd, NULL, &actions, out, sizeof out, &status) == 0 && strcmp(out, "Welcome to Orange OS.\n") == 0, "addopen");
	posix_spawn_file_actions_destroy(&actions);
	posix_spawn_file_actions_init(&actions);
	posix_spawn_file_actions_addchdir_np(&actions, "/etc");
	char *where[] = { "spawn-child", "cwd", NULL };
	CHECK(run(where, NULL, &actions, out, sizeof out, &status) == 0 && strcmp(out, "/etc\n") == 0, "addchdir");
	posix_spawn_file_actions_destroy(&actions);
	CHECK(run(where, NULL, NULL, out, sizeof out, &status) == 0 && strcmp(out, "/tmp/spawn\n") == 0, "the working directory is inherited");
	posix_spawn_file_actions_init(&actions);
	posix_spawn_file_actions_addclose(&actions, 1);
	pid_t pid;
	char *closed[] = { "spawn-child", "stdout-closed", NULL };
	CHECK(posix_spawn(&pid, CHILD, &actions, NULL, closed, NULL) == 0 && waitpid(pid, &status, 0) == pid, "spawn with stdout closed");
	CHECK(WEXITSTATUS(status) == EBADF, "a closed descriptor stays closed");
	posix_spawn_file_actions_destroy(&actions);

	/* Both ends of stdio redirected. */
	int in[2], output[2];
	CHECK(pipe2(in, O_CLOEXEC) == 0 && pipe2(output, O_CLOEXEC) == 0, "stdio pipes");
	posix_spawn_file_actions_init(&actions);
	posix_spawn_file_actions_adddup2(&actions, in[0], 0);
	posix_spawn_file_actions_adddup2(&actions, output[1], 1);
	char *upper[] = { "spawn-child", "upper", NULL };
	CHECK(posix_spawn(&pid, CHILD, &actions, NULL, upper, NULL) == 0, "spawn upper");
	posix_spawn_file_actions_destroy(&actions);
	close(in[0]);
	close(output[1]);
	CHECK(write(in[1], "hello spawn", 11) == 11 && close(in[1]) == 0, "feed stdin");
	CHECK(slurp(output[0], out, sizeof out) == 11 && strcmp(out, "HELLO SPAWN") == 0, "stdin to stdout through a child");
	CHECK(waitpid(pid, &status, 0) == pid && WEXITSTATUS(status) == 0, "upper exits");
	close(output[0]);

	/* A socket handed to a child, then a descriptor passed across processes. */
	int sv[2], p[2];
	CHECK(socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, sv) == 0 && pipe(p) == 0, "socket and pipe");
	posix_spawn_file_actions_init(&actions);
	posix_spawn_file_actions_adddup2(&actions, sv[1], 3);
	posix_spawn_file_actions_addclose(&actions, p[0]);
	posix_spawn_file_actions_addclose(&actions, p[1]);
	char *sock[] = { "spawn-child", "socket", NULL };
	CHECK(posix_spawn(&pid, CHILD, &actions, NULL, sock, NULL) == 0, "spawn socket child");
	posix_spawn_file_actions_destroy(&actions);
	close(sv[1]);
	char control[CMSG_SPACE(sizeof(int))], byte = 'd';
	struct iovec vector = { &byte, 1 };
	struct msghdr message = { .msg_iov = &vector, .msg_iovlen = 1, .msg_control = control, .msg_controllen = sizeof control };
	struct cmsghdr *header = CMSG_FIRSTHDR(&message);
	header->cmsg_level = SOL_SOCKET;
	header->cmsg_type = SCM_RIGHTS;
	header->cmsg_len = CMSG_LEN(sizeof(int));
	memcpy(CMSG_DATA(header), &p[1], sizeof(int));
	CHECK(sendmsg(sv[0], &message, 0) == 1 && close(p[1]) == 0, "pass the pipe's write end to the child");
	CHECK(slurp(p[0], out, sizeof out) == 11 && strcmp(out, "from child\n") == 0, "the child wrote through it; EOF when it exited");
	CHECK(waitpid(pid, &status, 0) == pid && WEXITSTATUS(status) == 0, "socket child exits");
	close(p[0]);
	close(sv[0]);

	/* waitpid: exit codes, WNOHANG, and a child already collected. */
	char *seven[] = { "spawn-child", "exit", "7", NULL };
	CHECK(posix_spawn(&pid, CHILD, NULL, NULL, seven, NULL) == 0, "spawn exit 7");
	CHECK(waitpid(pid, &status, 0) == pid && WIFEXITED(status) && WEXITSTATUS(status) == 7, "exit status");
	errno = 0;
	CHECK(waitpid(pid, &status, 0) == -1 && errno == ECHILD, "already collected");
	char *sleepy[] = { "spawn-child", "sleep", "100", NULL };
	CHECK(posix_spawn(&pid, CHILD, NULL, NULL, sleepy, NULL) == 0, "spawn sleeper");
	CHECK(waitpid(pid, &status, WNOHANG) == 0, "WNOHANG while running");
	CHECK(waitpid(pid, &status, 0) == pid && WEXITSTATUS(status) == 3, "then its status");

	/* posix_spawnp searches PATH; a missing program is ENOENT. */
	CHECK(posix_spawnp(&pid, "spawn-child", NULL, NULL, seven, environ) == 0 && waitpid(pid, &status, 0) == pid && WEXITSTATUS(status) == 7, "posix_spawnp");
	CHECK(posix_spawn(&pid, "/bin/no-such-program", NULL, NULL, seven, NULL) == ENOENT, "ENOENT for a missing program");
	CHECK(posix_spawnp(&pid, "no-such-program", NULL, NULL, seven, NULL) == ENOENT, "ENOENT from the PATH search");

	/* fork and exec are not offered, and say so. */
	errno = 0;
	CHECK(fork() == -1 && errno == ENOSYS, "fork is ENOSYS");

	CHECK(chdir("/") == 0 && unlink("/tmp/spawn/relative.txt") == 0 && rmdir("/tmp/spawn/sub/deeper") == 0 &&
	          rmdir("/tmp/spawn/sub") == 0 && rmdir("/tmp/spawn") == 0,
	      "clean up");
	close(dir);
	printf("spawn-probe: PASS posix_spawn(p) with argv, env, dup2/close/open/chdir actions and close-on-exec; "
	       "stdio pipes; cross-process descriptor passing; waitpid; chdir/fchdir/*at\n");
	return 0;
}
