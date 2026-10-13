/* rocosmo runtime core C API: plan and decode one target of a zstd-layout
 * container. Pure computation; the caller reads and writes all bytes.
 * Buffers are pointer + byte length; no NUL terminators are assumed. */
#ifndef ROCOSMO_RT_H
#define ROCOSMO_RT_H
#include <stddef.h>
#include <stdint.h>

enum { ROCOSMO_RAW = 0, ROCOSMO_FRAME = 1, ROCOSMO_DELTA = 2 };
enum { ROCOSMO_REF_NONE = 0, ROCOSMO_REF_RAW = 1, ROCOSMO_REF_FRAME = 2 };

typedef struct {
	uint64_t offset, stored_len, content_len; /* target bytes in the container */
	uint32_t kind;                            /* ROCOSMO_RAW / _FRAME / _DELTA */
	uint32_t ref_kind;                        /* ROCOSMO_REF_* */
	uint64_t ref_offset, ref_stored_len, ref_content_len;
} rocosmo_rt_plan;

/* Validate the index (against the container's size) and locate `name`. */
int rocosmo_rt_plan_target(const uint8_t *index, size_t index_len, uint64_t container_len,
	const uint8_t *name, size_t name_len, rocosmo_rt_plan *out);
/* Decode one zstd frame into out (exactly its content size). ref may be NULL. */
int rocosmo_rt_decode(const uint8_t *frame, size_t frame_len, const uint8_t *ref, size_t ref_len,
	uint8_t *out, size_t out_len);
const char *rocosmo_rt_status_message(int status);
#endif
