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
