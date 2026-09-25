/* OrangeOS replacement for musl's arch/x86_64/syscall_arch.h.
 *
 * musl issues Linux-numbered system calls through these inline functions.
 * OrangeOS has its own system-call ABI, so instead of executing `syscall`
 * they call the translation layer in userland/libs/musl-orange/orange.zig,
 * which maps each request onto native OrangeOS calls or returns -ENOSYS.
 * No Linux-numbered request ever reaches the kernel.
 *
 * SPDX-License-Identifier: MIT OR Apache-2.0
 */

long __orange_syscall(long, long, long, long, long, long, long);

#define __SYSCALL_LL_E(x) (x)
#define __SYSCALL_LL_O(x) (x)

static __inline long __syscall0(long n)
{
	return __orange_syscall(n, 0, 0, 0, 0, 0, 0);
}

static __inline long __syscall1(long n, long a1)
{
	return __orange_syscall(n, a1, 0, 0, 0, 0, 0);
}

static __inline long __syscall2(long n, long a1, long a2)
{
	return __orange_syscall(n, a1, a2, 0, 0, 0, 0);
}

static __inline long __syscall3(long n, long a1, long a2, long a3)
{
	return __orange_syscall(n, a1, a2, a3, 0, 0, 0);
}

static __inline long __syscall4(long n, long a1, long a2, long a3, long a4)
{
	return __orange_syscall(n, a1, a2, a3, a4, 0, 0);
}

static __inline long __syscall5(long n, long a1, long a2, long a3, long a4, long a5)
{
	return __orange_syscall(n, a1, a2, a3, a4, a5, 0);
}

static __inline long __syscall6(long n, long a1, long a2, long a3, long a4, long a5, long a6)
{
	return __orange_syscall(n, a1, a2, a3, a4, a5, a6);
}

/* No vDSO: time goes through the translated clock_gettime. */

#define IPC_64 0
