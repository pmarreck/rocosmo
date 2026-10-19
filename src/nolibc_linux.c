/* nolibc_linux.c: the few C library functions rocosmo-runtime and decode-only
 * zstd use, implemented directly on Linux system calls (x86_64, aarch64), so
 * the Linux runtimes link without a C library. Prototypes and constants come
 * from musl's headers; nothing from musl is linked. memcpy/memset/memmove come
 * from Zig's compiler_rt. Single-threaded by design: errno is a plain global.
 *
 * Allocation maps each block separately (mmap/munmap). The runtime makes a
 * handful of large allocations, for which this is as good as any heap. */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>

#if !defined(__x86_64__) && !defined(__aarch64__)
#error "nolibc_linux.c supports x86_64 and aarch64"
#endif

int main(int, char **);
char **environ;
static int errno_value;
int *__errno_location(void) { return &errno_value; }

/* Raw system call with up to six arguments; returns -errno on failure. */
static long sys6(long n, long a, long b, long c, long d, long e, long f) {
#if defined(__x86_64__)
	long ret;
	register long r10 __asm__("r10") = d;
	register long r8 __asm__("r8") = e;
	register long r9 __asm__("r9") = f;
	__asm__ volatile("syscall" : "=a"(ret) : "a"(n), "D"(a), "S"(b), "d"(c), "r"(r10), "r"(r8), "r"(r9) : "rcx", "r11", "memory");
	return ret;
#else
	register long x8 __asm__("x8") = n;
	register long x0 __asm__("x0") = a;
	register long x1 __asm__("x1") = b;
	register long x2 __asm__("x2") = c;
	register long x3 __asm__("x3") = d;
	register long x4 __asm__("x4") = e;
	register long x5 __asm__("x5") = f;
	__asm__ volatile("svc 0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2), "r"(x3), "r"(x4), "r"(x5) : "memory");
	return x0;
#endif
}
#define SYS(n, a, b, c, d, e, f) sys6((n), (long)(a), (long)(b), (long)(c), (long)(d), (long)(e), (long)(f))

/* Map a raw result to the libc convention: -1 with errno set. */
static long ret(long r) {
	if (r < 0 && r > -4096) {
		errno_value = (int)-r;
		return -1;
	}
	return r;
}

_Noreturn static void exit_group(int code) {
	for (;;) SYS(SYS_exit_group, code, 0, 0, 0, 0, 0);
}
_Noreturn void _exit(int code) { exit_group(code); }
void *mmap(void *addr, size_t n, int prot, int flags, int fd, off_t off) {
	long p = ret(SYS(SYS_mmap, addr, n, prot, flags, fd, off));
	return p == -1 ? MAP_FAILED : (void *)p;
}

/* Entry from _start with the initial stack: argc, argv..., NULL, envp..., NULL. */
_Noreturn void rocosmo_start(long *sp) {
	int argc = (int)sp[0];
	char **argv = (char **)(sp + 1);
	environ = argv + argc + 1;
	exit_group(main(argc, argv));
}

#if defined(__x86_64__)
__asm__(".text\n.global _start\n_start:\n"
	"\txor %rbp, %rbp\n\tmov %rsp, %rdi\n\tand $-16, %rsp\n\tcall rocosmo_start\n\thlt\n");
#else
__asm__(".text\n.global _start\n_start:\n"
	"\tmov x29, #0\n\tmov x30, #0\n\tmov x0, sp\n\tand sp, x0, #-16\n\tbl rocosmo_start\n\tbrk #0\n");
#endif

int open(const char *path, int flags, ...) {
	unsigned mode = 0;
	if (flags & O_CREAT) {
		va_list ap;
		va_start(ap, flags);
		mode = va_arg(ap, unsigned);
		va_end(ap);
	}
	return (int)ret(SYS(SYS_openat, AT_FDCWD, path, flags, mode, 0, 0));
}

int fcntl(int fd, int cmd, ...) {
	va_list ap;
	va_start(ap, cmd);
	long arg = va_arg(ap, long);
	va_end(ap);
	return (int)ret(SYS(SYS_fcntl, fd, cmd, arg, 0, 0, 0));
}

int close(int fd) { return (int)ret(SYS(SYS_close, fd, 0, 0, 0, 0, 0)); }
ssize_t write(int fd, const void *b, size_t n) { return ret(SYS(SYS_write, fd, b, n, 0, 0, 0)); }
ssize_t pread(int fd, void *b, size_t n, off_t off) { return ret(SYS(SYS_pread64, fd, b, n, off, 0, 0)); }
off_t lseek(int fd, off_t off, int whence) { return ret(SYS(SYS_lseek, fd, off, whence, 0, 0, 0)); }
int unlink(const char *path) { return (int)ret(SYS(SYS_unlinkat, AT_FDCWD, path, 0, 0, 0, 0)); }
int memfd_create(const char *name, unsigned flags) { return (int)ret(SYS(SYS_memfd_create, name, flags, 0, 0, 0, 0)); }
int execve(const char *path, char *const argv[], char *const envp[]) { return (int)ret(SYS(SYS_execve, path, argv, envp, 0, 0, 0)); }
int fexecve(int fd, char *const argv[], char *const envp[]) { return (int)ret(SYS(SYS_execveat, fd, "", argv, envp, AT_EMPTY_PATH, 0)); }
int mkdir(const char *path, mode_t mode) { return (int)ret(SYS(SYS_mkdirat, AT_FDCWD, path, mode, 0, 0, 0)); }
/* renameat2 with flags 0: aarch64 has no renameat or rename system call. */
int rename(const char *from, const char *to) { return (int)ret(SYS(SYS_renameat2, AT_FDCWD, from, AT_FDCWD, to, 0, 0)); }
long syscall(long n, ...) {
	va_list ap;
	va_start(ap, n);
	long a = va_arg(ap, long), b = va_arg(ap, long), c = va_arg(ap, long), d = va_arg(ap, long), e = va_arg(ap, long), f = va_arg(ap, long);
	va_end(ap);
	return ret(sys6(n, a, b, c, d, e, f));
}

/* Each block is its own mapping with a 16-byte header holding the mapping
 * size. The zstd decoder allocates and frees a few small tables per 128 KB
 * block, so freed mappings up to SPARE_MAX are kept in SPARES slots and
 * reused: rebuilding a 250 MB payload otherwise makes 61k mmap/munmap pairs. */
#define HEADER 16
#define SPARES 8
#define SPARE_MAX ((size_t)1 << 20)
static char *spare[SPARES];

/* A block of at least n bytes; *fresh says whether it is a new (zeroed) mapping. */
static void *alloc(size_t n, int *fresh) {
	if (n > SIZE_MAX - HEADER) { errno_value = ENOMEM; return NULL; }
	size_t total = n + HEADER;
	int best = -1;
	for (int i = 0; i < SPARES; i++)
		if (spare[i] && *(size_t *)spare[i] >= total && (best < 0 || *(size_t *)spare[i] < *(size_t *)spare[best])) best = i;
	if (best >= 0) {
		char *p = spare[best];
		spare[best] = NULL;
		*fresh = 0;
		return p + HEADER;
	}
	long p = ret(SYS(SYS_mmap, 0, total, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0));
	if (p == -1) return NULL;
	*(size_t *)p = total;
	*fresh = 1;
	return (char *)p + HEADER;
}
void *malloc(size_t n) {
	int fresh;
	return alloc(n, &fresh);
}
void *calloc(size_t count, size_t size) {
	if (size && count > SIZE_MAX / size) { errno_value = ENOMEM; return NULL; }
	int fresh;
	void *p = alloc(count * size, &fresh);
	if (p && !fresh) memset(p, 0, count * size); /* new mappings are already zero */
	return p;
}
void free(void *p) {
	if (!p) return;
	char *base = (char *)p - HEADER;
	size_t total = *(size_t *)base;
	if (total <= SPARE_MAX)
		for (int i = 0; i < SPARES; i++)
			if (!spare[i]) { spare[i] = base; return; }
	SYS(SYS_munmap, base, total, 0, 0, 0, 0);
}

size_t strlen(const char *s) {
	const char *p = s;
	while (*p) p++;
	return (size_t)(p - s);
}
int strncmp(const char *a, const char *b, size_t n) {
	for (; n && *a && *a == *b; n--, a++, b++) {}
	return n ? (unsigned char)*a - (unsigned char)*b : 0;
}
int strcmp(const char *a, const char *b) { return strncmp(a, b, SIZE_MAX); }

/* Messages for the errors the runtime can plausibly meet, as glibc and musl
 * word them; anything else is reported by number. */
char *strerror(int e) {
	switch (e) {
	case ENOENT: return "No such file or directory";
	case EACCES: return "Permission denied";
	case EEXIST: return "File exists";
	case ENOTDIR: return "Not a directory";
	case EISDIR: return "Is a directory";
	case ENOMEM: return "Out of memory";
	case ENOSPC: return "No space left on device";
	case EROFS: return "Read-only file system";
	case EIO: return "I/O error";
	case EMFILE: return "No file descriptors available";
	case ENAMETOOLONG: return "Filename too long";
	case ELOOP: return "Symbolic link loop";
	case EPERM: return "Operation not permitted";
	case EINVAL: return "Invalid argument";
	case ENOSYS: return "Function not implemented";
	case ENOEXEC: return "Exec format error";
	case EDQUOT: return "Quota exceeded";
	}
	static char buf[] = "error 0000";
	for (int i = 9; i >= 6; i--, e /= 10) buf[i] = (char)('0' + (e < 0 ? 0 : e % 10));
	return buf;
}
