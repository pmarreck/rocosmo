/* rocosmo-pack: combine per-target Roc executables into one polyglot file.
 * All I/O lives here; packing happens in the library behind rocosmo.h. */
#include "rocosmo.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#ifndef ROCOSMO_VERSION
#define ROCOSMO_VERSION "0.0.0"
#endif
#ifndef ROCOSMO_PLATFORM
#define ROCOSMO_PLATFORM "unknown"
#endif

static const struct { const char *flag; const char *pattern; } k_targets[] = {
	{ "--linux-x86_64", "Linux-x86_64|Linux-amd64" },
	{ "--linux-aarch64", "Linux-aarch64|Linux-arm64" },
	{ "--macos-x86_64", "Darwin-x86_64" },
	{ "--macos-arm64", "Darwin-arm64|Darwin-aarch64" },
};
#define N_TARGETS (sizeof k_targets / sizeof k_targets[0])
#define MAX_PAYLOADS 32

static void usage(FILE *f) {
	fprintf(f,
		"Usage: rocosmo-pack --windows-x86_64 FILE [TARGET FILE]... [--payload PATTERN=FILE]... -o OUT\n"
		"\n"
		"Combine native executables into one file that Windows loads as a PE image\n"
		"and POSIX shells run as a dispatcher selecting the payload for this OS/CPU.\n"
		"\n"
		"  --windows-x86_64 FILE   PE32+ image placed at the front (required)\n"
		"  --linux-x86_64 FILE     --linux-aarch64 FILE\n"
		"  --macos-x86_64 FILE     --macos-arm64 FILE\n"
		"  --payload PATTERN=FILE  custom `uname -s`-`uname -m` pattern(s), '|'-separated\n"
		"  -o, /o OUT              output path; '-' or @stdout for standard output\n"
		"  -h, --help              show this help\n"
		"      --about             one-line description\n"
		"Input FILE may be '-' or @stdin (at most one input).\n");
}

static int read_all(const char *path, uint8_t **buf, size_t *len) {
	int is_stdin = !strcmp(path, "-") || !strcmp(path, "@stdin");
	FILE *f = is_stdin ? stdin : fopen(path, "rb");
	if (!f) return -1;
	size_t cap = 1 << 16, n = 0;
	uint8_t *b = malloc(cap);
	if (!b) { if (!is_stdin) fclose(f); return -1; }
	for (;;) {
		if (n == cap) {
			uint8_t *nb = realloc(b, cap *= 2);
			if (!nb) { free(b); if (!is_stdin) fclose(f); return -1; }
			b = nb;
		}
		size_t got = fread(b + n, 1, cap - n, f);
		n += got;
		if (got == 0) break;
	}
	int err = ferror(f);
	if (!is_stdin) fclose(f);
	if (err) { free(b); return -1; }
	*buf = b;
	*len = n;
	return 0;
}

int main(int argc, char **argv) {
	const char *pe_path = NULL, *out_path = NULL;
	const char *patterns[MAX_PAYLOADS], *paths[MAX_PAYLOADS];
	size_t count = 0;
	int stdin_uses = 0;

	for (int i = 1; i < argc; i++) {
		const char *a = argv[i];
		if (!strcmp(a, "-h") || !strcmp(a, "--help") || !strcmp(a, "/?")) { usage(stdout); return 0; }
		if (!strcmp(a, "--about")) { printf("rocosmo-pack %s: combine Roc executables into one multi-OS, multi-arch file (%s)\n", ROCOSMO_VERSION, ROCOSMO_PLATFORM); return 0; }
		if (i + 1 >= argc) { fprintf(stderr, "rocosmo-pack: %s needs a value\n", a); return 2; }
		const char *v = argv[++i];
		if (!strcmp(a, "-o") || !strcmp(a, "/o") || !strcmp(a, "--output")) { out_path = v; continue; }
		if (!strcmp(a, "--windows-x86_64")) { pe_path = v; goto check_stdin; }
		int matched = 0;
		for (size_t t = 0; t < N_TARGETS; t++) {
			if (!strcmp(a, k_targets[t].flag)) {
				/* later arguments override earlier ones for the same target */
				size_t k = 0;
				while (k < count && strcmp(patterns[k], k_targets[t].pattern)) k++;
				if (k == count) { if (count == MAX_PAYLOADS) { fprintf(stderr, "rocosmo-pack: too many payloads\n"); return 2; } count++; }
				patterns[k] = k_targets[t].pattern;
				paths[k] = v;
				matched = 1;
			}
		}
		if (!matched && !strcmp(a, "--payload")) {
			char *eq = strchr(v, '=');
			if (!eq) { fprintf(stderr, "rocosmo-pack: --payload expects PATTERN=FILE\n"); return 2; }
			if (count == MAX_PAYLOADS) { fprintf(stderr, "rocosmo-pack: too many payloads\n"); return 2; }
			*eq = 0;
			patterns[count] = v;
			paths[count++] = eq + 1;
			v = eq + 1;
			matched = 1;
		}
		if (!matched) { fprintf(stderr, "rocosmo-pack: unknown option %s (see --help)\n", a); return 2; }
	check_stdin:
		if (!strcmp(v, "-") || !strcmp(v, "@stdin")) stdin_uses++;
	}
	if (!pe_path || !out_path) { usage(stderr); return 2; }
	if (stdin_uses > 1) { fprintf(stderr, "rocosmo-pack: only one input may come from stdin\n"); return 2; }

	uint8_t *pe = NULL;
	size_t pe_len = 0;
	if (read_all(pe_path, &pe, &pe_len)) { perror(pe_path); return 1; }
	rocosmo_payload payloads[MAX_PAYLOADS];
	for (size_t k = 0; k < count; k++) {
		uint8_t *b = NULL;
		size_t n = 0;
		if (read_all(paths[k], &b, &n)) { perror(paths[k]); return 1; }
		payloads[k] = (rocosmo_payload){ (const uint8_t *)patterns[k], strlen(patterns[k]), b, n };
	}

	uint8_t *out = NULL;
	size_t out_len = 0;
	int st = rocosmo_pack(pe, pe_len, payloads, count, &out, &out_len);
	if (st) { fprintf(stderr, "rocosmo-pack: %s\n", rocosmo_status_message(st)); return 1; }

	int to_stdout = !strcmp(out_path, "-") || !strcmp(out_path, "@stdout");
	FILE *f = to_stdout ? stdout : fopen(out_path, "wb");
	if (!f) { perror(out_path); return 1; }
	if (fwrite(out, 1, out_len, f) != out_len || (to_stdout ? fflush(f) : fclose(f))) { perror(out_path); return 1; }
	if (!to_stdout) chmod(out_path, 0755);
	rocosmo_free(out, out_len);
	return 0;
}
