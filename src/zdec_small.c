/* zdec_small.c: the runtimes' zstd decoder, a thin wrapper compiled as one
 * translation unit with Meta's educational decoder (zstd's
 * doc/educational_decoder/zstd_decompress.c, BSD license), chosen because it
 * is about a third the size of libzstd's space-optimized decoder.
 *
 * Its public names are prefixed so it can share a binary with libzstd (the
 * unit tests link both). It reports corruption by calling exit(1); that call
 * is redirected to rocosmo_zdec_fail(), which the embedding program defines
 * (report, then exit). zstd_small.zig adds the content checksum check. */
#define ZDEC_NO_MESSAGE
#define exit(status) rocosmo_zdec_fail()
#define ZSTD_decompress zdec_decompress
#define ZSTD_decompress_with_dict zdec_decompress_with_dict
#define ZSTD_get_decompressed_size zdec_get_decompressed_size
#define create_dictionary zdec_create_dictionary
#define parse_dictionary zdec_parse_dictionary
#define free_dictionary zdec_free_dictionary
#include <stdlib.h> /* declares the real exit() before the macro can rename it */
_Noreturn void rocosmo_zdec_fail(void);
#include "zstd_decompress.c"

/* Decode exactly one frame filling src_len bytes. A reference is a
 * raw-content prefix (zstd --patch-from), used in place without a copy.
 * Returns bytes written, or (size_t)-1 if bytes follow the frame. */
size_t rocosmo_zdec(void *dst, size_t dst_len, const void *src, size_t src_len, const void *ref, size_t ref_len) {
	istream_t in = IO_make_istream(src, src_len);
	ostream_t out = IO_make_ostream(dst, dst_len);
	dictionary_t dict;
	memset(&dict, 0, sizeof dict);
	dict.content = (u8 *)ref;
	dict.content_size = ref_len;
	decode_frame(&out, &in, ref ? &dict : NULL);
	if (IO_istream_len(&in)) return (size_t)-1;
	return (size_t)(out.ptr - (u8 *)dst);
}

/* Frame content size, or UINT64_MAX when absent or not a zstd frame. */
unsigned long long rocosmo_zdec_content_size(const void *src, size_t src_len) {
	if (src_len < 4 || read_bits_LE(src, 32, 0) != ZSTD_MAGIC_NUMBER) return (unsigned long long)-1;
	size_t s = ZSTD_get_decompressed_size(src, src_len);
	return s == (size_t)-1 ? (unsigned long long)-1 : (unsigned long long)s;
}
