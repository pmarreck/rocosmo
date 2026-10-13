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

/* Returns 0 on success and stores a library-owned buffer in *out. */
int rocosmo_pack(const uint8_t *pe, size_t pe_len, const rocosmo_payload *payloads, size_t count, uint8_t **out, size_t *out_len);
void rocosmo_free(uint8_t *ptr, size_t len);
const char *rocosmo_status_message(int status);
#endif
