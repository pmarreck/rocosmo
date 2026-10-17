# A minimum zstd decoder for the rocosmo runtimes

Status: specification only (2026-10-17). Nothing here is built. The runtimes currently decode with Meta's educational decoder (RESEARCH.md §15). This document says what a replacement written for both size and speed would have to do, so it can be built and tested against a fixed target later.

The format authority is [RFC 8878](https://www.rfc-editor.org/rfc/rfc8878) (Zstandard Compression and the `application/zstd` Media Type). Section numbers without a prefix are RFC 8878's. Where this document is stricter than the RFC, the stricter rule is deliberate: the runtime only ever reads frames that `rocosmo-pack` wrote, so anything the packer never writes can be rejected.

## 1. Inputs and output

One call decodes one frame:

```
decode(frame: bytes, reference: bytes or none, out: writable bytes of exactly the content size) -> ok | error
```

- `frame` is one complete zstd frame, read from the container (memory-mapped, read-only).
- `reference` is the optional data source the frame was encoded against (§6). It is either a raw stretch of the container (the Windows PE body) or the decoded output of another entry. It is read-only and may live in a different mapping from `out`.
- `out` is the final destination: the memfd on Linux and the BSDs, or the cache temp file mapping elsewhere. Its length is the frame's content size, known before decoding starts.

The decoder writes only inside `out`, reads only inside `frame`, `reference` and its own tables, and allocates nothing whose size depends on the window. Its fixed working memory is the entropy tables in §4 (a few KB), which can live in static storage.

## 2. What the packer writes, and what may therefore be rejected

`src/zstd_encode.zig` calls libzstd with the content size pledged, the checksum flag on, a window log of 10-31 chosen to cover reference plus source, and long-distance matching when the window log exceeds 27. Levels 1-22 are allowed (`--level`).

Measured on a `--patch-from` delta and on a whole frame (zstd 1.5.7, level 19, 2026-10-17), both start `28 b5 2f fd a4`: Frame_Header_Descriptor `0xa4` means a 4-byte content size, Single_Segment set, checksum present, no dictionary ID. The delta copied from a 3,000,000-byte reference while its own window was its content size (3,000,000 bytes); §6 explains why that is valid. The packer's own frames look the same: all four in the level-19 Roc compiler container start with `0xa4`.

| Feature | RFC | Packer | Decoder requirement |
| --- | --- | --- | --- |
| Frame magic `0xFD2FB528` | 3.1.1 | always | required |
| Skippable frames (`0x184D2A5?`) | 3.1.2 | never | reject |
| More than one frame in `frame` | 3.1 | never | reject trailing bytes |
| Frame_Content_Size present | 3.1.1.1 | always | required; must equal `out` length |
| Dictionary_ID present, nonzero | 3.1.1.1 | never | reject |
| Unused bit (4) | 3.1.1.1 | 0 | ignore |
| Reserved bit (3) | 3.1.1.1 | 0 | reject if set |
| Content_Checksum | 3.1.1 | always | required and verified (§5) |
| Window_Descriptor (when Single_Segment is 0) | 3.1.1.1 | when the window is smaller than the content | parse; window log up to 31 |
| Raw, RLE and Compressed blocks | 3.1.1.2 | all three | required |
| Block_Type 3 (reserved) | 3.1.1.2 | never | reject |
| Formatted dictionaries (entropy tables in a dictionary) | 5 | never | not supported |
| Legacy formats (v0.1-v0.7) | none | never | not supported |
| Streaming output into a ring buffer | none | not needed | not supported; output is one flat buffer |

Inside compressed blocks the packer has no control: libzstd chooses literal and sequence encodings per block at every level. The decoder must therefore implement every mode of §3.1.1.3, listed in §3 and §4. Restricting the encoder (for example "never use treeless literals") is not offered by libzstd's API, so it is not a size lever.

## 3. Frame and block layer

1. **Frame header** (3.1.1.1). Read the descriptor byte: bits 7-6 Frame_Content_Size_Flag, bit 5 Single_Segment_Flag, bit 2 Content_Checksum_Flag, bits 1-0 Dictionary_ID_Flag. Then the window descriptor if Single_Segment is 0: `windowLog = 10 + (byte >> 3)`, `Window_Size = (1 << windowLog) + ((1 << windowLog) / 8) * (byte & 7)`. Then the content size field: 1 byte (flag 0 with Single_Segment), 2 bytes plus 256 (flag 1), 4 bytes (flag 2) or 8 bytes (flag 3), little-endian. With Single_Segment set, Window_Size equals the content size.
2. **Blocks** (3.1.1.2). A 3-byte little-endian header: bit 0 Last_Block, bits 2-1 Block_Type, bits 23-3 Block_Size.
   - Raw: copy Block_Size bytes.
   - RLE: one byte repeated Block_Size times.
   - Compressed: Block_Size bytes of literals section plus sequences section (§4). Reject a block whose compressed size, or whose decoded size, exceeds `Block_Maximum_Size = min(Window_Size, 128 KiB)`.
   - Every block must fit in the remaining `out`; the frame must end with a Last_Block and then exactly 4 checksum bytes and nothing else.
3. **State carried between blocks of one frame** (3.1.1.3, 3.1.1.5):
   - the last Huffman table (for Treeless literals);
   - the last literal-length, offset and match-length decoding tables (for Repeat_Mode);
   - the three repeat offsets, initialized to 1, 4 and 8 at frame start.

   Using Treeless or Repeat_Mode before any table exists is corruption.

## 4. Compressed block contents

### 4.1 Literals section (RFC 3.1.1.3)

- **Header.** Literals_Block_Type (bits 1-0 of the first byte: Raw 0, RLE 1, Compressed 2, Treeless 3) and Size_Format (bits 3-2).
  - Raw and RLE: Regenerated_Size in 5, 12 or 20 bits (1-, 2- or 3-byte header).
  - Compressed and Treeless: 3-, 4- or 5-byte header with Regenerated_Size and Compressed_Size of 10, 10, 14 or 18 bits each. Size_Format 0 means one stream; 1-3 mean four streams.
- **Huffman tree description** (RFC 4.2.1), for Compressed literals.
  - A header byte below 128 means the weights are FSE-compressed in that many bytes. Use an FSE table with accuracy log at most 6 and two interleaved states.
  - 128 or more means `header - 127` weights packed as 4-bit nibbles.
  - The last weight is implied: it is the value that makes the weight sum a power of two.
  - Maximum code length is 11 bits; `bits = maxBits + 1 - weight`, and weight 0 means the symbol is absent.
- **Streams** (RFC 4.2.2).
  - One stream, or four streams behind a 6-byte jump table of three little-endian 16-bit sizes. Streams 1-3 each regenerate `(Regenerated_Size + 3) / 4` bytes and stream 4 the rest.
  - Each stream is a backward bitstream: it is read from its last byte, whose highest set bit is a padding marker. A last byte of 0 is corruption.
  - A stream must end with all its bits consumed.

### 4.2 Sequences section (RFC 3.1.1.3)

- **Number_of_Sequences.** Byte 0 is 0 (no sequences: the literals are the whole block); below 128 it is the count; 128-254 means `((b0 - 128) << 8) + b1`; 255 means `b1 + (b2 << 8) + 0x7F00`.
- **Symbol_Compression_Modes byte.** Two bits each for literal lengths (7-6), offsets (5-4) and match lengths (3-2); bits 1-0 are reserved and must be 0.
  - Predefined_Mode: the fixed distributions of RFC Appendix A, at accuracy 6, 5 and 6.
  - RLE_Mode: one symbol byte.
  - FSE_Compressed_Mode: an FSE table description (RFC 4.1.1), at accuracy up to 9 for literal and match lengths and 8 for offsets.
  - Repeat_Mode: reuse the previous table.
- **FSE table construction** (RFC 4.1.1). Normalized counts are read with the variable-width scheme, including "less than 1" probabilities (−1) placed at the table's end and the repeat-zero flags. Symbols are spread with the step `(tableSize >> 1) + (tableSize >> 3) + 3`. Each state gets its `nbBits` and baseline.
- **Bitstream** (3.1.1.3).
  - One backward bitstream holds all sequences. Its initial states are read in the order literal length, offset, match length.
  - For each sequence: read the offset extra bits, then the match-length extra bits, then the literal-length extra bits. Baselines and extra-bit counts are the code tables of RFC 3.1.1.3: literal-length codes 0-35, match-length codes 0-52 with minimum match 3, offset code N meaning `(1 << N) + N extra bits`.
  - Then update the states in the order literal length, match length, offset, except after the last sequence. The stream must be exactly consumed.
- **Offsets and repeat offsets** (3.1.1.5).
  - Offset_Value above 3 means `offset = Offset_Value - 3`, and the repeat offsets shift.
  - Values 1-3 select repeat offsets 1-3. When Literals_Length is 0 they shift by one: 1 selects repeat offset 2, 2 selects repeat offset 3, and 3 selects `repeat offset 1 - 1`.
  - The update rules for the three-slot history follow the RFC exactly. An offset of 0 is corruption.
  - Offset codes up to 31 must be supported; the packer's window log reaches 31.
- **Execution** (3.1.1.4). For each sequence, copy Literals_Length literals, then copy Match_Length bytes from `offset` bytes back. The source may overlap the destination (offset smaller than length means a repeating pattern), and may lie in the reference (§6). After the last sequence, copy the remaining literals. The literals used must equal Regenerated_Size exactly.

## 5. Integrity

- **Content checksum.** It is the low 32 bits of XXH64 with seed 0 over the whole decoded output, stored little-endian after the last block. `src/xxh64.zig` already implements it compactly. A mismatch fails the decode, and the runtime then leaves nothing in the cache.
- **Bounds.** Every read from `frame` (headers, jump tables, bitstreams) and every write or match source must be checked. A malformed frame may fail or produce wrong bytes, which the checksum then rejects, but it must never read or write outside the buffers in §1 and never loop without consuming input. The decoder returns an error and does not call `exit`. The runtime chooses the exit status, as `rocosmo_zdec_fail()` does now.
- **A wrong reference.** A frame decoded against the wrong reference produces wrong bytes and fails the checksum, so 32 bits of checksum are the only guard against a mislabeled reference. The container index names each delta's reference, and the packer verifies every frame when it writes it (`src/pack.zig` tests), so a mismatch at run time means corruption. The chance of a corrupted frame passing the checksum is about 1 in 4.3 billion. If a stronger guarantee is wanted, the index could carry each entry's content hash; the shell already names cache files by one.

## 6. Decoding against another data source (the "diff" idea)

zstd's `--patch-from` and libzstd's `ZSTD_CCtx_refPrefix` encode a target as a frame whose matches may also copy from a reference that both sides already have. RFC 8878 §5 calls such a reference a "raw content" dictionary, which must be at least 8 bytes long. It carries no entropy tables and no ID: the frame header's Dictionary_ID is absent, and which reference to use is agreed out of band. In rocosmo, the container index records it.

### 6.1 The decoding rule

Treat the reference as if it had been decoded just before the frame's first byte. For a match at output position `pos` (bytes of `out` already written) with offset `o`:

- `o <= pos`: copy from `out[pos - o ...]`, as usual.
- `pos < o <= pos + reference_len`: the source starts in the reference at `reference_len - (o - pos)`. If the match is longer than what remains of the reference, it continues at `out[0]`. A copy can therefore cross from one buffer into the other, and the two buffers are not adjacent in memory.
- `o > pos + reference_len`: corruption.

The window limits this only once the output exceeds Window_Size (RFC 8878 §5, "Content", and the educational decoder, `zstd_decompress.c:1339-1360`). While `pos <= Window_Size`, any offset up to `pos + reference_len` is valid. After that, offsets must be at most Window_Size, and the reference is out of reach. Measured frames set Single_Segment, so Window_Size is the content size and the whole reference stays reachable for the whole frame, even though the reference makes the effective history longer than Window_Size (§2). A decoder that applies only the window check therefore rejects every valid delta.

The repeat offsets still start at 1, 4 and 8. A raw-content dictionary provides no initial repeat offsets or tables.

### 6.2 What the reference can be

The format accepts any byte string the encoder and decoder agree on. rocosmo uses two kinds today (`src/pack.zig` `packZstd`):

- **A raw stretch of the container itself:** the Windows x64 PE body, stored uncompressed in universal containers. Decoding it costs nothing and needs only a mapping.
- **The decoded output of another entry** (a "root") on the same CPU. Delta depth is limited to one: a reference is always a root, never another delta. Memory peaks at the reference's size plus the output's (RESEARCH.md §15: about 485 MB for the Roc compiler's linux-aarch64 entry).

Further sources the same rule supports, none built:

- **A previous version of the same app**, already in the user's cache. An update could then ship as a delta against the version the user has. This needs a way to name that version: the cache already names payloads by content hash.
- **A shared base across apps**, for example a common runtime or standard library image. This only pays when the bytes really match. Calling convention and CPU dominate (RESEARCH.md §10).

### 6.3 Encoder obligations, for completeness

To make the rule in §6.1 hold, the encoder must:

- choose a window log covering reference plus target (as `zstd_encode.zig` does, capped at 31);
- enable long-distance matching for windows above 2^27;
- pledge the target size, so the frame records its content size.

A reference larger than 2 GiB minus the target cannot be fully reached at the window cap.

## 7. Design latitude for size and speed

These choices do not change the format, so they are left to the implementation and measured against the current decoder (RESEARCH.md §15: 9.8-11.2 KB gzipped per runtime, about 6.7 ms per MB on x86_64).

- **Flat output.** The output buffer is the window, so there is no ring buffer, no history copy and no window allocation. The educational decoder already works this way; it is the main reason it is small.
- **Bit reading.** A 64-bit container refilled from the stream end, in place of byte-at-a-time reads, is where most of the speed difference comes from. `perf` puts 45% of current samples in sequence decoding and 26% in Huffman stream decoding (§15).
- **Huffman decoding.**
  - One-symbol-per-lookup tables (libzstd's X1, 2^11 entries) are the small choice.
  - Two-symbol tables (X2) are faster and larger.
  - Interleaving the four streams in one loop helps either.
- **Match copy.** Copy 8 or 16 bytes at a time, with a byte loop or pattern expansion for offsets below 8. Over-writing past the end of a copy needs slack at the end of `out`. The runtime can map `out` slightly larger and then truncate the file, but writes must never pass the mapping. The reference is read-only and may end at a page boundary, so a copy out of it must not read past its end.
- **Table memory.**
  - Literal-length and match-length tables: 512 entries each.
  - Offset table: 256 entries.
  - Huffman table: 2,048 entries.
  - Huffman weights' FSE table: 64 entries.

  This is tens of KB at most, and static.
- **Language.** C (as now, built with Zig's clang) or Zig. The runtime's C API is `src/rocosmo_rt.h`, and `src/zstd_small.zig` wraps the decoder. A Zig decoder would need no `exit` redirect.

## 8. How a decoder would be accepted

These controls are independent of the decoder's author.

1. **Differential against libzstd.** Use frames encoded by the packer's own encoder (`src/zstd_encode.zig`) at levels 1, 3, 9, 19 and 22, whole and as deltas, with and without long-distance matching. Inputs are the real payloads in the tests (P2 probe app, synthetic Roc app, z7z, ripgrep, the Roc compiler). The output must be byte-identical to the input and the checksum must verify.
2. **zstd's `decodecorpus`** (`tests/decodecorpus.c` in the zstd repository). It generates random valid frames with known output and exercises encodings libzstd rarely chooses: RLE and treeless literals, every sequence mode and offset edge cases. Run it with a fixed seed range in `./test` and a long range in `./fuzz`. Its frames include features §2 rejects (no checksum, dictionary IDs), so the harness must filter them, or the decoder needs a test-only mode that accepts them. That choice belongs to the implementation step.
3. **Reference boundary cases.** These need dedicated deltas:
   - a match that starts in the reference and continues into `out`;
   - an offset of exactly `pos + reference_len`;
   - an offset one past that, which must be rejected;
   - a reference ending at a page boundary followed by an unmapped page, which must not fault.
4. **Corruption.** Flip each bit of a set of small frames and truncate them at every length. Each case must either fail or produce output that fails the checksum. Run under a bounds checker (Zig safety checks or `-fsanitize=address`). Pair this with the specificity corpus from items 1 and 2, all of which must pass.
5. **Gates.** P7's per-runtime gzipped size gate, and a decode-time measurement for the 250 MB Roc payload, recorded with machine and commit, following the `performance-profiling` contract. Whether a speed gain is worth more bytes is BDFN's decision (RESEARCH.md §15 and PLAN.md).
