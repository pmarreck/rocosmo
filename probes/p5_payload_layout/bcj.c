/* Branch/call/jump filter (BCJ, after xz's x86 and ARM64 filters): converts
 * PC-relative branch targets into absolute file positions before compression,
 * so every call to one function carries the same bytes. Exactly invertible on
 * any input: each rewrite adds or subtracts the position modulo the field
 * width and leaves the opcode bits, which select rewritten sites, untouched.
 *   x86_64:  E8/E9 rel32 whose value fits in 25 signed bits (xz's heuristic).
 *   aarch64: BL imm26 (in words) and ADRP imm21 (in 4 KiB pages), 4-byte aligned.
 * Usage: bcj encode|decode x86_64|aarch64 < in > out */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint32_t get32(const uint8_t *p) { return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24; }
static void put32(uint8_t *p, uint32_t v) { p[0] = v; p[1] = v >> 8; p[2] = v >> 16; p[3] = v >> 24; }

static void x86(uint8_t *b, size_t n, int enc) {
	for (size_t i = 0; i + 5 <= n;) {
		if (b[i] == 0xE8 || b[i] == 0xE9) {
			int32_t v = (int32_t)get32(b + i + 1);
			if (v >= -(1 << 24) && v < (1 << 24)) {
				uint32_t pos = (uint32_t)(i + 5);
				uint32_t r = (enc ? (uint32_t)v + pos : (uint32_t)v - pos) & 0x1FFFFFF;
				put32(b + i + 1, (r & 0x1000000) ? r | 0xFE000000 : r); /* sign-extend 25 bits */
				i += 5;
				continue;
			}
		}
		i++;
	}
}

static void arm64(uint8_t *b, size_t n, int enc) {
	for (size_t i = 0; i + 4 <= n; i += 4) {
		uint32_t insn = get32(b + i);
		if ((insn & 0xFC000000) == 0x94000000) { /* BL */
			uint32_t pc = (uint32_t)(i >> 2), imm = insn & 0x3FFFFFF;
			imm = (enc ? imm + pc : imm - pc) & 0x3FFFFFF;
			put32(b + i, (insn & 0xFC000000) | imm);
		} else if ((insn & 0x9F000000) == 0x90000000) { /* ADRP */
			uint32_t page = (uint32_t)(i >> 12);
			uint32_t imm = ((insn >> 29) & 3) | (((insn >> 5) & 0x7FFFF) << 2);
			imm = (enc ? imm + page : imm - page) & 0x1FFFFF;
			put32(b + i, (insn & ~0x60FFFFE0u) | (imm & 3) << 29 | (imm >> 2) << 5);
		}
	}
}

int main(int argc, char **argv) {
	if (argc != 3 || (strcmp(argv[1], "encode") && strcmp(argv[1], "decode")) ||
		(strcmp(argv[2], "x86_64") && strcmp(argv[2], "aarch64"))) {
		fputs("usage: bcj encode|decode x86_64|aarch64 < in > out\n", stderr);
		return 2;
	}
	size_t cap = 1 << 20, n = 0, got;
	uint8_t *b = malloc(cap);
	while (b && (got = fread(b + n, 1, cap - n, stdin)) > 0)
		if ((n += got) == cap) b = realloc(b, cap *= 2);
	if (!b) { fputs("bcj: out of memory\n", stderr); return 1; }
	(argv[2][0] == 'x' ? x86 : arm64)(b, n, argv[1][0] == 'e');
	return fwrite(b, 1, n, stdout) == n ? 0 : 1;
}
