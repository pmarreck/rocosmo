# Repository documents that publishing depends on.
echo "Docs: license and links"
if head -1 "$ROOT/LICENSE" 2>/dev/null | grep -qx 'MIT License' \
	&& grep -q '^Copyright (c) 2026 ' "$ROOT/LICENSE" \
	&& grep -q 'THE SOFTWARE IS PROVIDED "AS IS"' "$ROOT/LICENSE"; then
	pass "LICENSE holds the MIT text"
else
	fail "LICENSE holds the MIT text" "missing or not MIT"
fi
if grep -q '](LICENSE)' "$ROOT/README.md"; then pass "README links LICENSE"; else fail "README links LICENSE"; fi
if grep -q '^Copyright (c) Meta Platforms, Inc. and affiliates. All rights reserved.$' "$ROOT/THIRD_PARTY_NOTICES.md" 2>/dev/null \
	&& grep -q 'Redistributions in binary form must reproduce' "$ROOT/THIRD_PARTY_NOTICES.md"; then
	pass "THIRD_PARTY_NOTICES.md carries Zstandard's BSD license"
else
	fail "THIRD_PARTY_NOTICES.md carries Zstandard's BSD license" "missing"
fi
if grep -q '](THIRD_PARTY_NOTICES.md)' "$ROOT/README.md"; then pass "README links THIRD_PARTY_NOTICES.md"; else fail "README links THIRD_PARTY_NOTICES.md"; fi
if grep -q '](TECHNIQUE.md)' "$ROOT/README.md"; then pass "README links TECHNIQUE.md"; else fail "README links TECHNIQUE.md"; fi
# The technique write-up quotes the trampoline lines the packer emits; keep them in step.
for line in 'MZ=;eval "$(dd if="$0" bs=64 skip=1 count=' 'eval "$(dd if="$0" bs=64 skip=2 count=' '# Contains Zstandard (BSD license): https://github.com/facebook/zstd/blob/dev/LICENSE'; do
	if grep -qF -- "$line" "$ROOT/TECHNIQUE.md" 2>/dev/null && grep -qF -- "${line//\"/\\\"}" "$ROOT/src/pack.zig"; then pass "TECHNIQUE.md and the packer agree on: ${line:0:40}"; else fail "TECHNIQUE.md quotes the packer's line" "$line"; fi
done
