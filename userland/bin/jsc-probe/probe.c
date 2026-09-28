/* Runs JavaScriptCore's shell on a test script (probe.js) and relays its
 * verdict (docs/design/012-wpe-webkit-browser.md, W4).
 *
 * The script runs twice: on the interpreter (LLInt) alone, then with the
 * JIT, whose code pages are read/execute and written through a second
 * mapping (patch 0008, §4.5). jit.js then checks that hot code reaches the
 * baseline, DFG and FTL tiers and computes the same results there.
 *
 * SPDX-License-Identifier: MIT OR Apache-2.0
 */
#include <spawn.h>
#include <stdio.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

/* Run jsc with `argv` (and `extra_env` prepended to the environment);
 * returns its wait status and leaves its output in `text`. */
static int run_jsc(char **argv, const char *extra_env, char *text, size_t size)
{
	int output[2];
	if (pipe(output) != 0)
		return -1;
	posix_spawn_file_actions_t actions;
	posix_spawn_file_actions_init(&actions);
	posix_spawn_file_actions_adddup2(&actions, output[1], 1);
	posix_spawn_file_actions_adddup2(&actions, output[1], 2);
	posix_spawn_file_actions_addclose(&actions, output[0]);
	char *env[64];
	size_t n_env = 0;
	if (extra_env)
		env[n_env++] = (char *)extra_env;
	for (char **e = environ; *e && n_env < 63; e++)
		env[n_env++] = *e;
	env[n_env] = NULL;
	pid_t pid;
	if (posix_spawn(&pid, "/bin/jsc", &actions, NULL, argv, env) != 0) {
		close(output[0]);
		close(output[1]);
		return -1;
	}
	close(output[1]);
	/* Keep the last `size` bytes: a failure's cause is at the end. */
	size_t length = 0;
	ssize_t n;
	char chunk[1024];
	while ((n = read(output[0], chunk, sizeof chunk)) > 0) {
		if (length + (size_t)n > size - 1) {
			size_t drop = length + (size_t)n - (size - 1);
			memmove(text, text + drop, length - drop);
			length -= drop;
		}
		memcpy(text + length, chunk, (size_t)n);
		length += (size_t)n;
	}
	text[length] = '\0';
	close(output[0]);
	int status = -1;
	waitpid(pid, &status, 0);
	return status;
}

int main(void)
{
	/* A one-line script first: if the engine cannot start, say how, and
	 * whether bmalloc's own heap is involved (Malloc=1 uses the system's). */
	char text[4096];
	char *hello[] = { "jsc", "--useJIT=false", "-e", "print('jsc says ' + (6 * 7))", NULL };
	int status = run_jsc(hello, NULL, text, sizeof text);
	if (status != 0 || !strstr(text, "jsc says 42")) {
		printf("jsc-probe: one-line script: status %d, output \"%s\"\n", status, text);
		status = run_jsc(hello, "Malloc=1", text, sizeof text);
		printf("jsc-probe: with Malloc=1: status %d, output \"%s\"\n", status, text);
		/* The last calls it made, for the log. */
		status = run_jsc(hello, "ORANGE_SYSCALL_TRACE=1", text, sizeof text);
		const char *tail = strlen(text) > 3000 ? text + strlen(text) - 3000 : text;
		printf("jsc-probe: traced run: status %d, last calls:\n%s\n", status, tail);
		printf("jsc-probe: FAIL engine start\n");
		return 1;
	}

	char *argv[] = { "jsc", "--useJIT=false", "/share/wpe-tests/jsc-probe.js", NULL };
	status = run_jsc(argv, NULL, text, sizeof text);
	fputs(text, stdout);
	if (status != 0 || !strstr(text, "jsc-probe: PASS")) {
		printf("jsc-probe: FAIL jsc status %d\n", status);
		return 1;
	}

	/* The same checks with the JIT; its verdict line is relabelled. */
	char *jit_argv[] = { "jsc", "/share/wpe-tests/jsc-probe.js", NULL };
	status = run_jsc(jit_argv, NULL, text, sizeof text);
	const char *verdict = strstr(text, "jsc-probe: PASS");
	if (status != 0 || !verdict) {
		printf("%s\njsc-probe: FAIL with the JIT, status %d\n", text, status);
		return 1;
	}
	printf("jsc-probe: with JIT %s", verdict + strlen("jsc-probe: "));

	char *tiers_argv[] = { "jsc", "--useDollarVM=true", "/share/wpe-tests/jsc-jit.js", NULL };
	status = run_jsc(tiers_argv, NULL, text, sizeof text);
	fputs(text, stdout);
	if (status != 0 || !strstr(text, "jsc-jit: PASS")) {
		printf("jsc-probe: FAIL JIT tiers, status %d\n", status);
		return 1;
	}
	return 0;
}
