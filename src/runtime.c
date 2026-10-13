/* rocosmo-runtime: rebuild one target's executable from a zstd-layout
 * container. The container's shell dispatcher unpacks this program (gzipped,
 * per OS/CPU) once per machine and calls it on a cache miss:
 *   rocosmo-runtime CONTAINER INDEX_OFFSET INDEX_LEN TARGET OUT
 * It writes the payload to OUT (created exclusively, mode 0700); the shell
 * then marks it executable and renames it into the cache. All I/O lives here;
 * validation, planning and decoding happen in the core behind rocosmo_rt.h. */
#include "rocosmo_rt.h"
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#ifndef ROCOSMO_VERSION
#define ROCOSMO_VERSION "0.0.0"
#endif
#ifndef ROCOSMO_PLATFORM
#define ROCOSMO_PLATFORM "unknown"
#endif

static int fail(const char *what, const char *why) {
	fprintf(stderr, "rocosmo-runtime: %s: %s\n", what, why);
	return 1;
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

static int parse_u64(const char *s, uint64_t *v) {
	char *end;
	errno = 0;
	unsigned long long x = strtoull(s, &end, 10);
	if (errno || end == s || *end || *s == '-') return -1;
	*v = x;
	return 0;
}

int main(int argc, char **argv) {
	if (argc == 2 && (!strcmp(argv[1], "-h") || !strcmp(argv[1], "--help"))) {
		printf("Usage: rocosmo-runtime CONTAINER INDEX_OFFSET INDEX_LEN TARGET OUT\n"
			"Rebuild TARGET's executable from a rocosmo zstd-layout CONTAINER into OUT.\n"
			"Normally run by the container's own dispatcher, not by hand.\n");
		return 0;
	}
	if (argc == 2 && !strcmp(argv[1], "--about")) {
		printf("rocosmo-runtime %s: rebuilds a target executable from a rocosmo container (%s)\n", ROCOSMO_VERSION, ROCOSMO_PLATFORM);
		return 0;
	}
	if (argc != 6) return fprintf(stderr, "rocosmo-runtime: usage: rocosmo-runtime CONTAINER INDEX_OFFSET INDEX_LEN TARGET OUT\n"), 2;
	uint64_t idx_off, idx_len;
	if (parse_u64(argv[2], &idx_off) || parse_u64(argv[3], &idx_len)) return fprintf(stderr, "rocosmo-runtime: index offset and length must be decimal integers\n"), 2;

	int fd = open(argv[1], O_RDONLY);
	if (fd < 0) return fail(argv[1], strerror(errno));
	struct stat st;
	if (fstat(fd, &st)) return fail(argv[1], strerror(errno));
	uint64_t size = (uint64_t)st.st_size;
	if (idx_off > size || idx_len > size - idx_off) return fail(argv[1], "index lies outside the container");

	uint8_t *idx = read_range(fd, idx_off, idx_len);
	if (!idx) return fail(argv[1], "cannot read index");
	rocosmo_rt_plan p;
	const char *name = argv[4];
	int s = rocosmo_rt_plan_target(idx, (size_t)idx_len, size, (const uint8_t *)name, strlen(name), &p);
	free(idx);
	if (s) return fail(name, rocosmo_rt_status_message(s));

	uint8_t *ref = NULL;
	size_t ref_len = 0;
	if (p.ref_kind != ROCOSMO_REF_NONE) {
		uint8_t *stored = read_range(fd, p.ref_offset, p.ref_stored_len);
		if (!stored) return fail(name, "cannot read reference");
		if (p.ref_kind == ROCOSMO_REF_RAW) {
			ref = stored;
		} else {
			ref = malloc(p.ref_content_len ? (size_t)p.ref_content_len : 1);
			if (!ref) return fail(name, "out of memory");
			s = rocosmo_rt_decode(stored, (size_t)p.ref_stored_len, NULL, 0, ref, (size_t)p.ref_content_len);
			free(stored);
			if (s) return fail(name, rocosmo_rt_status_message(s));
		}
		ref_len = (size_t)p.ref_content_len;
	}

	uint8_t *stored = read_range(fd, p.offset, p.stored_len);
	if (!stored) return fail(name, "cannot read payload");
	close(fd);
	uint8_t *out = stored;
	if (p.kind != ROCOSMO_RAW) {
		out = malloc(p.content_len ? (size_t)p.content_len : 1);
		if (!out) return fail(name, "out of memory");
		s = rocosmo_rt_decode(stored, (size_t)p.stored_len, ref, ref_len, out, (size_t)p.content_len);
		free(stored);
		if (s) return fail(name, rocosmo_rt_status_message(s));
	}
	free(ref);

	int ofd = open(argv[5], O_WRONLY | O_CREAT | O_EXCL, 0700);
	if (ofd < 0) return fail(argv[5], strerror(errno));
	for (size_t put = 0; put < p.content_len;) {
		ssize_t n = write(ofd, out + put, (size_t)p.content_len - put);
		if (n < 0 && errno == EINTR) continue;
		if (n <= 0) { unlink(argv[5]); return fail(argv[5], strerror(errno)); }
		put += (size_t)n;
	}
	if (close(ofd)) { unlink(argv[5]); return fail(argv[5], strerror(errno)); }
	free(out);
	return 0;
}
