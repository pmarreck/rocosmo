/* rocosmo-pack: combine per-target native executables into one polyglot file.
 * All I/O lives here; packing happens in the library behind rocosmo.h. */
#include "rocosmo.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#ifdef _WIN32
#include <fcntl.h>
#include <io.h>
#endif

/* Containers are binary: on Windows, stdin and stdout start in text mode,
 * which would translate CR/LF and stop reading at ^Z. */
static FILE *binary_stream(FILE *f) {
#ifdef _WIN32
	_setmode(_fileno(f), _O_BINARY);
#endif
	return f;
}

#ifndef ROCOSMO_VERSION
#define ROCOSMO_VERSION "0.0.0"
#endif
#ifndef ROCOSMO_PLATFORM
#define ROCOSMO_PLATFORM "unknown"
#endif

#define MAX_PAYLOADS 32
#define DEFAULT_LEVEL 19

enum layout { LAYOUT_AUTO, LAYOUT_RAW, LAYOUT_ZSTD };

static void usage(FILE *f) {
	fprintf(f,
		"Usage: rocosmo-pack [--windows-x86_64 FILE] [--TARGET FILE]... [OPTIONS] -o OUT\n"
		"\n"
		"Combine native executables into one file that POSIX shells run as a\n"
		"dispatcher selecting the payload for this OS/CPU. With a Windows image the\n"
		"file is also a PE that Windows loads; without one it is a #!/bin/sh script.\n"
		"\n"
		"  --windows-x86_64 FILE   PE32+ image placed at the front (optional)\n"
		"  --linux-x86_64 FILE     --linux-aarch64 FILE\n"
		"  --macos-x86_64 FILE     --macos-arm64 FILE\n"
		"  --freebsd-x86_64 FILE   --freebsd-aarch64 FILE\n"
		"  --netbsd-x86_64 FILE    --openbsd-x86_64 FILE\n"
		"  --payload PATTERN=FILE  custom `uname -s`-`uname -m` pattern(s), '|'-separated\n"
		"                          (raw layout only)\n"
		"  --layout raw|zstd|auto  raw: payloads stored as-is, extracted with dd;\n"
		"                          zstd: zstd frames and same-CPU deltas, rebuilt by a\n"
		"                          small per-OS/CPU runtime; auto (default): the smaller\n"
		"  --level N               zstd level, 1-22 (default %d)\n"
		"  --app-id ID             cache namespace, lowercase reverse-DNS (org.example.tool);\n"
		"                          default: the id the payloads embed as\n"
		"                          ROCOSMO_APP_ID=<id>; else local.<output name>\n"
		"  -o, /o OUT              output path; '-' or @stdout for standard output\n"
		"  -v, --verbose           report the chosen layout and size on stderr\n"
		"  -h, --help              show this help\n"
		"      --about             one-line description\n"
		"Input FILE may be '-' or @stdin (at most one input).\n",
		DEFAULT_LEVEL);
}

static int read_all(const char *path, uint8_t **buf, size_t *len) {
	int is_stdin = !strcmp(path, "-") || !strcmp(path, "@stdin");
	FILE *f = is_stdin ? binary_stream(stdin) : fopen(path, "rb");
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

static int write_out(const char *path, const uint8_t *data, size_t len) {
	int to_stdout = !strcmp(path, "-") || !strcmp(path, "@stdout");
	FILE *f = to_stdout ? binary_stream(stdout) : fopen(path, "wb");
	if (!f) return -1;
	if (fwrite(data, 1, len, f) != len || (to_stdout ? fflush(f) : fclose(f))) return -1;
	if (!to_stdout) chmod(path, 0755);
	return 0;
}

int main(int argc, char **argv) {
	const char *pe_path = NULL, *out_path = NULL;
	const char *app_id_opt = NULL;
	/* Known targets carry a name (zstd-capable); --payload entries only a pattern. */
	const char *names[MAX_PAYLOADS], *patterns[MAX_PAYLOADS], *paths[MAX_PAYLOADS];
	size_t pattern_lens[MAX_PAYLOADS];
	size_t count = 0;
	int stdin_uses = 0, custom = 0, verbose = 0, level = DEFAULT_LEVEL;
	enum layout layout = LAYOUT_AUTO;

	for (int i = 1; i < argc; i++) {
		const char *a = argv[i];
		if (!strcmp(a, "-h") || !strcmp(a, "--help") || !strcmp(a, "/?")) { usage(stdout); return 0; }
		if (!strcmp(a, "--about")) { printf("rocosmo-pack %s: combine native executables into one multi-OS, multi-arch file (%s)\n", ROCOSMO_VERSION, ROCOSMO_PLATFORM); return 0; }
		if (!strcmp(a, "-v") || !strcmp(a, "--verbose")) { verbose = 1; continue; }
		if (i + 1 >= argc) { fprintf(stderr, "rocosmo-pack: %s needs a value\n", a); return 2; }
		const char *v = argv[++i];
		if (!strcmp(a, "-o") || !strcmp(a, "/o") || !strcmp(a, "--output")) { out_path = v; continue; }
		if (!strcmp(a, "--layout")) {
			if (!strcmp(v, "raw")) layout = LAYOUT_RAW;
			else if (!strcmp(v, "zstd")) layout = LAYOUT_ZSTD;
			else if (!strcmp(v, "auto")) layout = LAYOUT_AUTO;
			else { fprintf(stderr, "rocosmo-pack: --layout must be raw, zstd or auto\n"); return 2; }
			continue;
		}
		if (!strcmp(a, "--app-id")) { app_id_opt = v; continue; }
		if (!strcmp(a, "--level")) {
			char *end;
			long l = strtol(v, &end, 10);
			if (*v == 0 || *end || l < 1 || l > 22) { fprintf(stderr, "rocosmo-pack: --level must be 1-22\n"); return 2; }
			level = (int)l;
			continue;
		}
		if (!strcmp(a, "--windows-x86_64")) { pe_path = v; goto check_stdin; }
		if (!strcmp(a, "--payload")) {
			char *eq = strchr(v, '=');
			if (!eq) { fprintf(stderr, "rocosmo-pack: --payload expects PATTERN=FILE\n"); return 2; }
			if (count == MAX_PAYLOADS) { fprintf(stderr, "rocosmo-pack: too many payloads\n"); return 2; }
			*eq = 0;
			names[count] = NULL;
			patterns[count] = v;
			pattern_lens[count] = strlen(v);
			paths[count++] = eq + 1;
			v = eq + 1;
			custom = 1;
			goto check_stdin;
		}
		if (!strncmp(a, "--", 2)) {
			const uint8_t *pat;
			size_t pat_len;
			const char *name = a + 2;
			if (!rocosmo_target_pattern((const uint8_t *)name, strlen(name), &pat, &pat_len)) {
				/* later arguments override earlier ones for the same target */
				size_t k = 0;
				while (k < count && !(names[k] && !strcmp(names[k], name))) k++;
				if (k == count) { if (count == MAX_PAYLOADS) { fprintf(stderr, "rocosmo-pack: too many payloads\n"); return 2; } count++; }
				names[k] = name;
				patterns[k] = (const char *)pat;
				pattern_lens[k] = pat_len;
				paths[k] = v;
				goto check_stdin;
			}
		}
		fprintf(stderr, "rocosmo-pack: unknown option %s (see --help)\n", a);
		return 2;
	check_stdin:
		if (!strcmp(v, "-") || !strcmp(v, "@stdin")) stdin_uses++;
	}
	if (!out_path || (!pe_path && count == 0)) { usage(stderr); return 2; }
	if (stdin_uses > 1) { fprintf(stderr, "rocosmo-pack: only one input may come from stdin\n"); return 2; }
	if (custom && layout == LAYOUT_ZSTD) { fprintf(stderr, "rocosmo-pack: --payload needs --layout raw (zstd targets need a known OS/CPU)\n"); return 2; }
	if (custom) layout = LAYOUT_RAW;

	uint8_t *pe = NULL;
	size_t pe_len = 0;
	if (pe_path && read_all(pe_path, &pe, &pe_len)) { perror(pe_path); return 1; }
	rocosmo_payload payloads[MAX_PAYLOADS];
	rocosmo_target targets[MAX_PAYLOADS];
	for (size_t k = 0; k < count; k++) {
		uint8_t *b = NULL;
		size_t n = 0;
		if (read_all(paths[k], &b, &n)) { perror(paths[k]); return 1; }
		payloads[k] = (rocosmo_payload){ (const uint8_t *)patterns[k], pattern_lens[k], b, n };
		if (names[k]) targets[k] = (rocosmo_target){ (const uint8_t *)names[k], strlen(names[k]), b, n };
	}

	/* Cache namespace: --app-id, else what the payloads declare, else local.<output name>. */
	rocosmo_buffer bufs[MAX_PAYLOADS + 1];
	bufs[0] = (rocosmo_buffer){ pe, pe_len };
	for (size_t k = 0; k < count; k++) bufs[k + 1] = (rocosmo_buffer){ payloads[k].bytes, payloads[k].bytes_len };
	const char *base = strrchr(out_path, '/');
	base = base ? base + 1 : out_path;
	if (!strcmp(out_path, "-") || !strcmp(out_path, "@stdout")) base = "app";
	uint8_t *id = NULL;
	size_t id_len = 0;
	int id_source = 0;
	int ist = rocosmo_resolve_app_id((const uint8_t *)app_id_opt, app_id_opt ? strlen(app_id_opt) : 0, bufs, count + 1, (const uint8_t *)base, strlen(base), &id, &id_len, &id_source);
	if (ist) {
		fprintf(stderr, "rocosmo-pack: %s%s\n", app_id_opt ? "--app-id must be valid: " : "", rocosmo_status_message(ist));
		return app_id_opt ? 2 : 1;
	}

	uint8_t *raw = NULL, *zst = NULL;
	size_t raw_len = 0, zst_len = 0;
	int st;
	if (layout != LAYOUT_ZSTD && (st = rocosmo_pack(pe, pe_len, payloads, count, id, id_len, &raw, &raw_len))) {
		fprintf(stderr, "rocosmo-pack: %s\n", rocosmo_status_message(st));
		return 1;
	}
	if (layout != LAYOUT_RAW && (st = rocosmo_pack_zstd(pe, pe_len, targets, count, level, id, id_len, &zst, &zst_len))) {
		fprintf(stderr, "rocosmo-pack: %s\n", rocosmo_status_message(st));
		return 1;
	}
	int use_zstd = layout == LAYOUT_ZSTD || (layout == LAYOUT_AUTO && zst_len < raw_len);
	const uint8_t *out = use_zstd ? zst : raw;
	size_t out_len = use_zstd ? zst_len : raw_len;
	if (write_out(out_path, out, out_len)) { perror(out_path); return 1; }
	if (verbose) {
		fprintf(stderr, "rocosmo-pack: layout %s: %zu bytes", use_zstd ? "zstd" : "raw", out_len);
		if (layout == LAYOUT_AUTO) fprintf(stderr, " (%s would be %zu)", use_zstd ? "raw" : "zstd", use_zstd ? raw_len : zst_len);
		fprintf(stderr, "\n");
	}
	if (verbose) {
		static const char *sources[] = { "option", "embedded", "default" };
		fprintf(stderr, "rocosmo-pack: app id %.*s (%s)\n", (int)id_len, (const char *)id, sources[id_source]);
	}
	rocosmo_free(id, id_len);
	if (raw) rocosmo_free(raw, raw_len);
	if (zst) rocosmo_free(zst, zst_len);
	return 0;
}
