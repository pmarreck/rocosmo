/* rocosmo-runtime: rebuild one target's executable from a zstd-layout
 * container. The container's shell dispatcher unpacks this program (gzipped,
 * per OS/CPU) once per machine and calls it on a cache miss:
 *   rocosmo-runtime CONTAINER INDEX_OFFSET INDEX_LEN TARGET OUT
 *     writes the payload to OUT (created exclusively, mode 0700); the shell
 *     then marks it executable and renames it into the cache.
 *   rocosmo-runtime --exec CONTAINER INDEX_OFFSET INDEX_LEN TARGET ARGV0 [ARG]...
 *     (Linux) rebuilds the payload into a sealed memfd and replaces itself
 *     with it, so nothing but this runtime is ever cached. If the payload is
 *     over the memory limit or the kernel refuses (no memfd, memfd_noexec,
 *     an LSM), it re-runs the container with ROCOSMO_NO_MEMFD=1 and the
 *     dispatcher takes the cache path instead.
 * All I/O lives here; validation, planning and decoding happen in the core
 * behind rocosmo_rt.h. It uses only a few system calls and string functions
 * (no stdio), so the Linux build can link without a C library (nolibc_linux.c). */
#ifdef __linux__
#define _GNU_SOURCE /* memfd_create, sealing */
#endif
#include "rocosmo_rt.h"
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#ifdef __linux__
#include <sys/mman.h>
#ifndef MFD_EXEC
#define MFD_EXEC 0x0010U
#endif
#endif

#ifndef ROCOSMO_VERSION
#define ROCOSMO_VERSION "0.0.0"
#endif
#ifndef ROCOSMO_PLATFORM
#define ROCOSMO_PLATFORM "unknown"
#endif

/* Larger payloads are cached on disk: page cache is shared between runs,
 * a memfd copy is private anonymous memory rebuilt on every start. */
#define MEMORY_LIMIT ((uint64_t)64 << 20)
#define NO_MEMFD "ROCOSMO_NO_MEMFD"

extern char **environ;

/* Write NULL-terminated string pieces to fd (best effort). */
static void say(int fd, const char *const *parts) {
	for (; *parts; parts++) {
		size_t len = strlen(*parts);
		for (const char *p = *parts; len;) {
			ssize_t n = write(fd, p, len);
			if (n < 0 && errno == EINTR) continue;
			if (n <= 0) return;
			p += n;
			len -= (size_t)n;
		}
	}
}
#define SAY(fd, ...) say(fd, (const char *const[]){__VA_ARGS__, NULL})

static int fail(const char *what, const char *why) {
	SAY(2, "rocosmo-runtime: ", what, ": ", why, "\n");
	return 1;
}

/* Exit status when the zstd decoder meets corrupt data: 1 when writing a
 * file, 126 (cannot execute) under --exec, as for the runtime's other errors. */
static int corrupt_status = 1;

/* Called by the small zstd decoder (zdec_small.c), which cannot return an
 * error; nothing has been written to OUT or a memfd yet. */
_Noreturn void rocosmo_zdec_fail(void) {
	SAY(2, "rocosmo-runtime: cannot decode the payload: corrupt data or out of memory\n");
	_exit(corrupt_status);
}

static const char usage_file[] = "rocosmo-runtime CONTAINER INDEX_OFFSET INDEX_LEN TARGET OUT";
static const char usage_exec[] = "rocosmo-runtime --exec CONTAINER INDEX_OFFSET INDEX_LEN TARGET ARGV0 [ARG]...";

static int usage_error(const char *usage) {
	SAY(2, "rocosmo-runtime: usage: ", usage, "\n");
	return 2;
}

/* Read [off, off+len) of fd into a new buffer (at least 1 byte allocated). */
static uint8_t *read_range(int fd, uint64_t off, uint64_t len) {
	if (len > SIZE_MAX) return NULL;
	uint8_t *buf = malloc(len ? (size_t)len : 1);
	if (!buf) return NULL;
	for (size_t got = 0; got < len;) {
		ssize_t n = pread(fd, buf + got, (size_t)len - got, (off_t)(off + got));
		if (n < 0 && errno == EINTR) continue;
		if (n <= 0) { free(buf); return NULL; }
		got += (size_t)n;
	}
	return buf;
}

/* Strict unsigned decimal: digits only, no sign or spaces, no overflow. */
static int parse_u64(const char *s, uint64_t *v) {
	uint64_t x = 0;
	if (!*s) return -1;
	for (; *s; s++) {
		if (*s < '0' || *s > '9') return -1;
		unsigned d = (unsigned)(*s - '0');
		if (x > (UINT64_MAX - d) / 10) return -1;
		x = x * 10 + d;
	}
	*v = x;
	return 0;
}

static int write_all(int fd, const uint8_t *b, size_t len) {
	for (size_t put = 0; put < len;) {
		ssize_t n = write(fd, b + put, len - put);
		if (n < 0 && errno == EINTR) continue;
		if (n <= 0) return -1;
		put += (size_t)n;
	}
	return 0;
}

/* Locate TARGET in the container's index. Leaves fd open on success. */
static int plan(const char *container, const char *idx_off_s, const char *idx_len_s, const char *name, int *fd_out, rocosmo_rt_plan *p) {
	uint64_t idx_off, idx_len;
	if (parse_u64(idx_off_s, &idx_off) || parse_u64(idx_len_s, &idx_len)) {
		SAY(2, "rocosmo-runtime: index offset and length must be decimal integers\n");
		return 2;
	}
	int fd = open(container, O_RDONLY | O_CLOEXEC);
	if (fd < 0) return fail(container, strerror(errno));
	off_t end = lseek(fd, 0, SEEK_END);
	if (end < 0) return fail(container, strerror(errno));
	uint64_t size = (uint64_t)end;
	if (idx_off > size || idx_len > size - idx_off) return fail(container, "index lies outside the container");
	uint8_t *idx = read_range(fd, idx_off, idx_len);
	if (!idx) return fail(container, "cannot read index");
	int s = rocosmo_rt_plan_target(idx, (size_t)idx_len, size, (const uint8_t *)name, strlen(name), p);
	free(idx);
	if (s) return fail(name, rocosmo_rt_status_message(s));
	*fd_out = fd;
	return 0;
}

/* Rebuild the planned payload; returns a malloc'd buffer of p->content_len bytes. */
static int rebuild(int fd, const char *name, const rocosmo_rt_plan *p, uint8_t **out_buf) {
	uint8_t *ref = NULL;
	size_t ref_len = 0;
	int s;
	if (p->ref_kind != ROCOSMO_REF_NONE) {
		uint8_t *stored = read_range(fd, p->ref_offset, p->ref_stored_len);
		if (!stored) return fail(name, "cannot read reference");
		if (p->ref_kind == ROCOSMO_REF_RAW) {
			ref = stored;
		} else {
			ref = malloc(p->ref_content_len ? (size_t)p->ref_content_len : 1);
			if (!ref) return fail(name, "out of memory");
			s = rocosmo_rt_decode(stored, (size_t)p->ref_stored_len, NULL, 0, ref, (size_t)p->ref_content_len);
			free(stored);
			if (s) return fail(name, rocosmo_rt_status_message(s));
		}
		ref_len = (size_t)p->ref_content_len;
	}
	uint8_t *stored = read_range(fd, p->offset, p->stored_len);
	if (!stored) return fail(name, "cannot read payload");
	uint8_t *out = stored;
	if (p->kind != ROCOSMO_RAW) {
		out = malloc(p->content_len ? (size_t)p->content_len : 1);
		if (!out) return fail(name, "out of memory");
		s = rocosmo_rt_decode(stored, (size_t)p->stored_len, ref, ref_len, out, (size_t)p->content_len);
		free(stored);
		if (s) return fail(name, rocosmo_rt_status_message(s));
	}
	free(ref);
	*out_buf = out;
	return 0;
}

static int to_file(int argc, char **argv) {
	if (argc != 6) return usage_error(usage_file);
	int fd;
	rocosmo_rt_plan p;
	int s = plan(argv[1], argv[2], argv[3], argv[4], &fd, &p);
	if (s) return s;
	uint8_t *out;
	if ((s = rebuild(fd, argv[4], &p, &out))) return s;
	close(fd);
	int ofd = open(argv[5], O_WRONLY | O_CREAT | O_EXCL, 0700);
	if (ofd < 0) return fail(argv[5], strerror(errno));
	if (write_all(ofd, out, (size_t)p.content_len) || close(ofd)) { unlink(argv[5]); return fail(argv[5], strerror(errno)); }
	free(out);
	return 0;
}

/* Run the container again through sh on its cache path, with
 * ROCOSMO_NO_MEMFD=1 added to the environment (exec; returns only on error). */
static int fall_back(char *container, char **args) {
	size_t n = 0;
	while (environ[n]) n++;
	char **env = malloc((n + 2) * sizeof *env);
	if (!env) return fail(NO_MEMFD, "out of memory");
	size_t k = 0;
	for (size_t i = 0; i < n; i++)
		if (strncmp(environ[i], NO_MEMFD "=", sizeof NO_MEMFD)) env[k++] = environ[i];
	env[k++] = NO_MEMFD "=1";
	env[k] = NULL;
	args[-1] = container; /* sh's $0, overwriting ARGV0 in argv */
	args[-2] = "sh";
	execve("/bin/sh", args - 2, env);
	return fail("/bin/sh", strerror(errno));
}

/* --exec CONTAINER INDEX_OFFSET INDEX_LEN TARGET ARGV0 [ARG]... */
static int to_memory(int argc, char **argv) {
	if (argc < 7) return usage_error(usage_exec);
	corrupt_status = 126;
	char *container = argv[2], **app_argv = argv + 6;
#ifdef __linux__
	const char *name = argv[5];
	int fd;
	rocosmo_rt_plan p;
	if (plan(container, argv[3], argv[4], name, &fd, &p)) return 126;
	if (p.content_len > MEMORY_LIMIT) { close(fd); return fall_back(container, app_argv + 1); }
	uint8_t *out;
	if (rebuild(fd, name, &p, &out)) return 126;
	close(fd);
	unsigned flags = MFD_CLOEXEC | MFD_ALLOW_SEALING;
	int mfd = memfd_create(name, flags | MFD_EXEC);
	if (mfd < 0 && errno == EINVAL) mfd = memfd_create(name, flags); /* before Linux 6.3 */
	if (mfd >= 0 && !write_all(mfd, out, (size_t)p.content_len)) {
		free(out);
		fcntl(mfd, F_ADD_SEALS, F_SEAL_SEAL | F_SEAL_SHRINK | F_SEAL_GROW | F_SEAL_WRITE);
		fexecve(mfd, app_argv, environ);
	}
	if (mfd >= 0) close(mfd);
#endif
	return fall_back(container, app_argv + 1);
}

int main(int argc, char **argv) {
	if (argc == 2 && (!strcmp(argv[1], "-h") || !strcmp(argv[1], "--help"))) {
		SAY(1, "Usage: ", usage_file, "\n       ", usage_exec, "\n"
			"Rebuild TARGET's executable from a rocosmo zstd-layout CONTAINER into OUT, or\n"
			"(--exec, Linux) run it from memory, falling back to the cache path.\n"
			"Normally run by the container's own dispatcher, not by hand.\n");
		return 0;
	}
	if (argc == 2 && !strcmp(argv[1], "--about")) {
		SAY(1, "rocosmo-runtime " ROCOSMO_VERSION ": rebuilds a target executable from a rocosmo container (" ROCOSMO_PLATFORM ")\n");
		return 0;
	}
	if (argc > 1 && !strcmp(argv[1], "--exec")) return to_memory(argc, argv);
	return to_file(argc, argv);
}
