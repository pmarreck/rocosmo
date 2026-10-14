/* Forced include (-include) for building pinterm's Linux-oriented host on
 * macOS, which lacks pipe2, F_SETPIPE_SZ and clock_nanosleep. A stopgap for
 * this probe; the proper fix belongs in pinterm's host. */
#include <errno.h>
#include <fcntl.h>
#include <time.h>
#include <unistd.h>

/* pipe2(O_CLOEXEC) without atomicity: fine for a single-threaded host. */
static inline int pipe2(int fds[2], int flags) {
	if (pipe(fds)) return -1;
	if (flags & O_CLOEXEC) {
		fcntl(fds[0], F_SETFD, FD_CLOEXEC);
		fcntl(fds[1], F_SETFD, FD_CLOEXEC);
	}
	return 0;
}

/* Pipe capacity is not adjustable on macOS; F_GETFD makes the call a no-op. */
#define F_SETPIPE_SZ F_GETFD

#ifndef TIMER_ABSTIME
#define TIMER_ABSTIME 1
#endif
/* Absolute monotonic sleep via a relative nanosleep; returns an errno value
 * like the POSIX function (EINTR when a signal interrupts it). */
static inline int clock_nanosleep(clockid_t clock, int flags, const struct timespec *t, struct timespec *rem) {
	struct timespec d = *t;
	if (flags & TIMER_ABSTIME) {
		struct timespec now;
		clock_gettime(clock, &now);
		d.tv_sec -= now.tv_sec;
		d.tv_nsec -= now.tv_nsec;
		if (d.tv_nsec < 0) { d.tv_nsec += 1000000000L; d.tv_sec--; }
		if (d.tv_sec < 0) return 0;
	}
	return nanosleep(&d, rem) ? errno : 0;
}
