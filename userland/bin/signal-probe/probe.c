/* POSIX signals through musl on OrangeOS: handlers with siginfo, blocking
 * and pending signals, SA_RESETHAND, SIG_IGN, an alternate stack, a SIGSEGV
 * handler that repairs the fault and resumes, a SIGILL handler that edits
 * the saved registers to skip an instruction, siglongjmp out of SIGFPE,
 * EINTR from a blocked read and from nanosleep, kill() of children
 * (default action, SIGKILL, and a child's own handler), abort(), and the
 * permission and existence checks of kill().
 *
 * SPDX-License-Identifier: MIT OR Apache-2.0
 */
#define _GNU_SOURCE
#include <errno.h>
#include <pthread.h>
#include <setjmp.h>
#include <signal.h>
#include <spawn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <time.h>
#include <ucontext.h>
#include <unistd.h>

#define CHECK(condition, what)                                                   \
	do {                                                                         \
		if (!(condition)) {                                                      \
			printf("signal-probe: FAIL %s (errno %d)\n", (what), errno);         \
			return 1;                                                            \
		}                                                                        \
	} while (0)

static volatile int usr1_count, usr1_code = -1, usr1_signo;
static void on_usr1(int sig, siginfo_t *info, void *context)
{
	(void)context;
	usr1_count++;
	usr1_signo = info->si_signo;
	usr1_code = sig;
}

static char alt_stack_memory[64 * 1024];
static volatile uintptr_t handler_stack;
static void on_usr2(int sig)
{
	volatile char here = 0;
	(void)sig;
	handler_stack = (uintptr_t)&here;
}

static char *guarded;
static volatile uintptr_t fault_address;
static void on_segv(int sig, siginfo_t *info, void *context)
{
	(void)sig;
	(void)context;
	fault_address = (uintptr_t)info->si_addr;
	/* Repair: make the page writable; the store is retried and succeeds. */
	mprotect(guarded, 4096, PROT_READ | PROT_WRITE);
}

static volatile int ill_count;
static void on_ill(int sig, siginfo_t *info, void *context)
{
	(void)sig;
	(void)info;
	ucontext_t *uc = context;
	ill_count++;
	uc->uc_mcontext.gregs[REG_RIP] += 2; /* skip the 2-byte ud2 */
}

static sigjmp_buf escape;
static void on_fpe(int sig)
{
	siglongjmp(escape, sig);
}

static void on_interrupt(int sig)
{
	(void)sig;
}

static int blocking_pipe[2];
static volatile pid_t reader_tid;
static void *blocked_reader(void *unused)
{
	(void)unused;
	reader_tid = gettid();
	char byte;
	errno = 0;
	ssize_t r = read(blocking_pipe[0], &byte, 1);
	return (void *)(long)(r == -1 && errno == EINTR ? 0 : 1);
}

static pthread_t main_thread;
static void *wake_main(void *unused)
{
	(void)unused;
	struct timespec pause = { 0, 50 * 1000 * 1000 };
	nanosleep(&pause, NULL);
	pthread_kill(main_thread, SIGUSR2);
	return NULL;
}

static pid_t spawn_child(char *const argv[], int stdout_fd)
{
	posix_spawn_file_actions_t actions;
	posix_spawn_file_actions_init(&actions);
	if (stdout_fd >= 0)
		posix_spawn_file_actions_adddup2(&actions, stdout_fd, 1);
	pid_t pid;
	int error = posix_spawn(&pid, "/bin/spawn-child", &actions, NULL, argv, NULL);
	posix_spawn_file_actions_destroy(&actions);
	return error == 0 ? pid : -1;
}

static long now_ms(void)
{
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return t.tv_sec * 1000 + t.tv_nsec / 1000000;
}

int main(void)
{
	/* A handler with siginfo, via raise(). */
	struct sigaction action = { .sa_sigaction = on_usr1, .sa_flags = SA_SIGINFO };
	sigemptyset(&action.sa_mask);
	CHECK(sigaction(SIGUSR1, &action, NULL) == 0, "sigaction");
	CHECK(raise(SIGUSR1) == 0 && usr1_count == 1 && usr1_signo == SIGUSR1 && usr1_code == SIGUSR1, "handler runs with siginfo");
	struct sigaction read_back;
	CHECK(sigaction(SIGUSR1, NULL, &read_back) == 0 && read_back.sa_sigaction == on_usr1, "sigaction reads back");

	/* Blocked: pending until unblocked, then delivered at once. */
	sigset_t set, pending;
	sigemptyset(&set);
	sigaddset(&set, SIGUSR1);
	CHECK(sigprocmask(SIG_BLOCK, &set, NULL) == 0 && raise(SIGUSR1) == 0 && usr1_count == 1, "blocked stays pending");
	CHECK(sigpending(&pending) == 0 && sigismember(&pending, SIGUSR1), "sigpending");
	CHECK(sigprocmask(SIG_UNBLOCK, &set, NULL) == 0 && usr1_count == 2, "delivered on unblock");

	/* SIG_IGN, and SA_RESETHAND back to the default. */
	signal(SIGUSR1, SIG_IGN);
	CHECK(raise(SIGUSR1) == 0 && usr1_count == 2, "SIG_IGN");
	action.sa_flags = SA_SIGINFO | SA_RESETHAND;
	CHECK(sigaction(SIGUSR1, &action, NULL) == 0 && raise(SIGUSR1) == 0 && usr1_count == 3, "SA_RESETHAND handler");
	CHECK(sigaction(SIGUSR1, NULL, &read_back) == 0 && read_back.sa_handler == SIG_DFL, "reset to SIG_DFL");
	errno = 0;
	CHECK(sigaction(SIGKILL, &action, NULL) == -1 && errno == EINVAL, "SIGKILL cannot be caught");

	/* An alternate signal stack. */
	stack_t alt = { .ss_sp = alt_stack_memory, .ss_size = sizeof alt_stack_memory };
	CHECK(sigaltstack(&alt, NULL) == 0, "sigaltstack");
	struct sigaction on_stack = { .sa_handler = on_usr2, .sa_flags = SA_ONSTACK };
	sigemptyset(&on_stack.sa_mask);
	CHECK(sigaction(SIGUSR2, &on_stack, NULL) == 0 && raise(SIGUSR2) == 0, "SA_ONSTACK handler");
	CHECK(handler_stack >= (uintptr_t)alt_stack_memory && handler_stack < (uintptr_t)alt_stack_memory + sizeof alt_stack_memory, "ran on the alternate stack");

	/* SIGSEGV: the handler repairs the page and the store is retried. */
	guarded = mmap(NULL, 4096, PROT_READ, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	struct sigaction segv = { .sa_sigaction = on_segv, .sa_flags = SA_SIGINFO | SA_ONSTACK };
	sigemptyset(&segv.sa_mask);
	CHECK(guarded != MAP_FAILED && sigaction(SIGSEGV, &segv, NULL) == 0, "SIGSEGV handler");
	((volatile char *)guarded)[123] = 42;
	CHECK(fault_address == (uintptr_t)guarded + 123 && guarded[123] == 42, "fault address, repair and retry");
	munmap(guarded, 4096);

	/* SIGILL: the handler edits the saved rip to step over ud2. */
	struct sigaction ill = { .sa_sigaction = on_ill, .sa_flags = SA_SIGINFO };
	sigemptyset(&ill.sa_mask);
	CHECK(sigaction(SIGILL, &ill, NULL) == 0, "SIGILL handler");
	__asm__ volatile("ud2");
	CHECK(ill_count == 1, "execution resumed after the edited rip");

	/* SIGFPE: leave the handler with siglongjmp. */
	signal(SIGFPE, on_fpe);
	/* Both operands unknown to the compiler, so it must emit idiv (it turns
	 * 1 / x into a comparison). */
	volatile int zero = 0, seven = 7, result = 0;
	if (sigsetjmp(escape, 1) == 0) {
		result = seven / zero;
		CHECK(0, "division by zero did not trap");
	}
	(void)result;
	sigemptyset(&set);
	CHECK(sigprocmask(SIG_BLOCK, NULL, &set) == 0 && !sigismember(&set, SIGFPE), "siglongjmp restored the mask");

	/* EINTR: a thread blocked in read(), interrupted by pthread_kill. */
	struct sigaction interrupt = { .sa_handler = on_interrupt };
	sigemptyset(&interrupt.sa_mask);
	CHECK(sigaction(SIGUSR2, &interrupt, NULL) == 0 && pipe(blocking_pipe) == 0, "EINTR setup");
	pthread_t reader;
	CHECK(pthread_create(&reader, NULL, blocked_reader, NULL) == 0, "reader thread");
	struct timespec brief = { 0, 50 * 1000 * 1000 };
	nanosleep(&brief, NULL);
	void *outcome;
	CHECK(pthread_kill(reader, SIGUSR2) == 0 && pthread_join(reader, &outcome) == 0 && outcome == NULL, "read() returned EINTR");

	/* nanosleep interrupted: EINTR with the time left. */
	pthread_t waker;
	main_thread = pthread_self();
	struct timespec two = { 2, 0 }, left = { 0, 0 };
	long start = now_ms();
	CHECK(pthread_create(&waker, NULL, wake_main, NULL) == 0, "waker thread");
	errno = 0;
	CHECK(nanosleep(&two, &left) == -1 && errno == EINTR, "nanosleep returns EINTR");
	CHECK(now_ms() - start < 1500 && left.tv_sec >= 1, "early, with the time left");
	pthread_join(waker, NULL);

	/* kill(): a child ended by SIGTERM's default action, one by SIGKILL. */
	char *sleeper[] = { "spawn-child", "sleep", "900", NULL };
	pid_t pid = spawn_child(sleeper, -1);
	int status;
	CHECK(pid > 0 && kill(pid, SIGTERM) == 0 && waitpid(pid, &status, 0) == pid && WEXITSTATUS(status) == 128 + SIGTERM, "SIGTERM ends a child");
	pid = spawn_child(sleeper, -1);
	CHECK(pid > 0 && kill(pid, SIGKILL) == 0 && waitpid(pid, &status, 0) == pid && WEXITSTATUS(status) == 128 + SIGKILL, "SIGKILL ends a child");

	/* A child with its own SIGTERM handler finishes cleanly. */
	int out[2];
	CHECK(pipe(out) == 0, "child pipe");
	char *trap[] = { "spawn-child", "trap-term", NULL };
	pid = spawn_child(trap, out[1]);
	close(out[1]);
	char said[32] = { 0 };
	CHECK(pid > 0 && read(out[0], said, 6) == 6 && strcmp(said, "ready\n") == 0, "child ready");
	CHECK(kill(pid, SIGTERM) == 0 && read(out[0], said, 5) == 5 && memcmp(said, "term\n", 5) == 0, "child's handler ran");
	CHECK(waitpid(pid, &status, 0) == pid && WEXITSTATUS(status) == 0, "child exited normally");
	close(out[0]);

	/* abort() ends the program with SIGABRT. */
	char *aborter[] = { "spawn-child", "abort", NULL };
	pid = spawn_child(aborter, -1);
	CHECK(pid > 0 && waitpid(pid, &status, 0) == pid && WEXITSTATUS(status) == 128 + SIGABRT, "abort()");

	/* kill() checks. */
	errno = 0;
	/* The parent (the runtime test's init) started this program, not the
	 * other way round. */
	CHECK(getppid() > 1 && kill(getppid(), SIGTERM) == -1 && errno == EPERM, "cannot signal a program it did not start");
	errno = 0;
	CHECK(kill(999999, 0) == -1 && errno == ESRCH, "ESRCH for no such program");
	CHECK(kill(getpid(), 0) == 0, "signal 0 to itself");

	printf("signal-probe: PASS handlers with siginfo, masks and pending, SIG_IGN, SA_RESETHAND, sigaltstack, "
	       "SIGSEGV repair, SIGILL rip edit, SIGFPE siglongjmp, EINTR, kill of children, abort\n");
	return 0;
}
