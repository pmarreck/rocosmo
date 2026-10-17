/* rocosmo container packer C API. All buffers are pointer + byte length. */
#ifndef ROCOSMO_H
#define ROCOSMO_H
#include <stddef.h>
#include <stdint.h>

typedef struct {
	const uint8_t *pattern; /* shell case alternatives, e.g. "Linux-x86_64|Linux-amd64" */
	size_t pattern_len;
	const uint8_t *bytes;   /* native executable; may be NULL when bytes_len is 0 */
	size_t bytes_len;
} rocosmo_payload;

/* Returns 0 on success and stores a library-owned buffer in *out.
 * pe = NULL, pe_len = 0: POSIX-only format, a #!/bin/sh script with no PE. */
/* app_id: cache namespace (see rocosmo_resolve_app_id). */
int rocosmo_pack(const uint8_t *pe, size_t pe_len, const rocosmo_payload *payloads, size_t count,
	const uint8_t *app_id, size_t app_id_len, uint8_t **out, size_t *out_len);
void rocosmo_free(uint8_t *ptr, size_t len);
const char *rocosmo_status_message(int status);

typedef struct {
	const uint8_t *name;    /* known target name, e.g. "linux-x86_64" */
	size_t name_len;
	const uint8_t *bytes;   /* native executable; may be NULL when bytes_len is 0 */
	size_t bytes_len;
} rocosmo_target;

/* Static shell case pattern for a known target name; 10 if unknown. */
int rocosmo_target_pattern(const uint8_t *name, size_t name_len, const uint8_t **pattern, size_t *pattern_len);
/* zstd layout: whole frames or deltas plus each target's embedded runtime.
 * level is the zstd level, 1-22. Output as for rocosmo_pack. */
int rocosmo_pack_zstd(const uint8_t *pe, size_t pe_len, const rocosmo_target *targets, size_t count, int level,
	const uint8_t *app_id, size_t app_id_len, uint8_t **out, size_t *out_len);
/* Like rocosmo_pack_zstd, but front the container with the embedded Windows
 * launcher (opt-in): the app's own Windows PE (win_pe) is stored as a
 * compressed entry the launcher rebuilds and runs on first use, instead of
 * sitting uncompressed at the front. `targets`/`count` are the other (POSIX)
 * targets, as for rocosmo_pack_zstd. win_pe must be a PE32+ image. */
int rocosmo_pack_zstd_launcher(const uint8_t *win_pe, size_t win_pe_len, const rocosmo_target *targets, size_t count, int level,
	const uint8_t *app_id, size_t app_id_len, uint8_t **out, size_t *out_len);

typedef struct { const uint8_t *ptr; size_t len; } rocosmo_buffer;
enum { ROCOSMO_APP_ID_OPTION = 0, ROCOSMO_APP_ID_EMBEDDED = 1, ROCOSMO_APP_ID_DEFAULT = 2 };
/* Resolve the app id: option (NULL for none) > the ROCOSMO_APP_ID=<id>; every
 * declaring payload agrees on > local.<exe_name>. *out is freed with
 * rocosmo_free; *source is one of ROCOSMO_APP_ID_*. */
int rocosmo_resolve_app_id(const uint8_t *option, size_t option_len, const rocosmo_buffer *payloads, size_t count,
	const uint8_t *exe_name, size_t exe_len, uint8_t **out, size_t *out_len, int *source);
#endif
