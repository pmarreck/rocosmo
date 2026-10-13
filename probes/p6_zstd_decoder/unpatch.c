/* Rebuild a payload from a zstd frame, optionally a --patch-from delta whose
 * reference is a raw-content prefix (ZSTD_DCtx_refPrefix). Measures what a
 * container runtime's decoder costs per target.
 * Usage: unpatch REF|- FRAME OUT
 * Built with -DNO_ZSTD it only copies FRAME to OUT: the same I/O without the
 * decoder, so the size difference is the decoder's cost. */
#include <stdio.h>
#include <stdlib.h>
#ifndef NO_ZSTD
#define ZSTD_STATIC_LINKING_ONLY
#include "zstd.h"
#endif

static int die(const char *msg) { fprintf(stderr, "unpatch: %s\n", msg); return 1; }

/* Read a whole file into a heap buffer; NULL on failure. */
static unsigned char *slurp(const char *path, size_t *len) {
	FILE *f = fopen(path, "rb");
	if (!f) return NULL;
	size_t cap = 1 << 16, n = 0;
	unsigned char *buf = malloc(cap);
	for (size_t got; buf && (got = fread(buf + n, 1, cap - n, f)) > 0;) {
		n += got;
		if (n == cap) { unsigned char *b = realloc(buf, cap *= 2); if (!b) { free(buf); buf = NULL; } else buf = b; }
	}
	fclose(f);
	*len = n;
	return buf;
}

int main(int argc, char **argv) {
	if (argc != 4) return die("usage: unpatch REF|- FRAME OUT");
	size_t frame_len, out_len;
	unsigned char *frame = slurp(argv[2], &frame_len), *out;
	if (!frame) return die("cannot read frame");
#ifdef NO_ZSTD
	out = frame; out_len = frame_len;
#else
	size_t ref_len = 0;
	unsigned char *ref = NULL;
	if (argv[1][0] != '-' || argv[1][1]) { ref = slurp(argv[1], &ref_len); if (!ref) return die("cannot read reference"); }
	unsigned long long size = ZSTD_getFrameContentSize(frame, frame_len);
	if (size == ZSTD_CONTENTSIZE_UNKNOWN || size == ZSTD_CONTENTSIZE_ERROR) return die("frame has no content size");
	out = malloc(size ? size : 1);
	ZSTD_DCtx *d = ZSTD_createDCtx();
	if (!out || !d) return die("out of memory");
	ZSTD_DCtx_setParameter(d, ZSTD_d_windowLogMax, 31);
	if (ref && ZSTD_isError(ZSTD_DCtx_refPrefix(d, ref, ref_len))) return die("bad reference");
	out_len = ZSTD_decompressDCtx(d, out, size, frame, frame_len);
	if (ZSTD_isError(out_len)) { fprintf(stderr, "unpatch: decode failed (zstd error %d)\n", (int)ZSTD_getErrorCode(out_len)); return 1; }
	if (out_len != size) return die("decoded size mismatch");
#endif
	FILE *f = fopen(argv[3], "wb");
	if (!f || fwrite(out, 1, out_len, f) != out_len || fclose(f)) return die("cannot write output");
	return 0;
}
