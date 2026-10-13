// C host for the P1 probe, compiled by cosmocc against Cosmopolitan libc.
// Implements the Roc symbol-ABI runtime functions and the hosted function.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

extern int64_t roc_main(int64_t n);

// Roc passes alignment but not length to dealloc, so keep a header with the
// original pointer in front of each over-aligned block.
void *roc_alloc(size_t length, size_t alignment) {
	if (alignment < sizeof(void *)) alignment = sizeof(void *);
	void *p = NULL;
	if (posix_memalign(&p, alignment, length ? length : 1) != 0) abort();
	return p;
}
void roc_dealloc(void *ptr, size_t alignment) { (void)alignment; free(ptr); }
void *roc_realloc(void *ptr, size_t new_length, size_t alignment) {
	(void)alignment;
	void *p = realloc(ptr, new_length);
	if (!p) abort();
	return p;
}
void roc_dbg(const char *bytes, size_t len) { fprintf(stderr, "ROC DBG: %.*s\n", (int)len, bytes); }
void roc_expect_failed(const char *bytes, size_t len) { fprintf(stderr, "Expect failed: %.*s\n", (int)len, bytes); }
void roc_crashed(const char *bytes, size_t len) { fprintf(stderr, "Roc crashed: %.*s\n", (int)len, bytes); exit(1); }

int64_t roc_host_double(int64_t n) { return n * 2; }

int main(int argc, char **argv) {
	int64_t n = argc > 1 ? strtoll(argv[1], NULL, 10) : 20;
	printf("%lld\n", (long long)roc_main(n));
	return 0;
}
