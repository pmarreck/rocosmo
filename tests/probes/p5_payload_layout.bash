# P5: choose which payloads to store whole and which as zstd deltas
# (--patch-from) against a stored one, minimizing total container bytes.

echo "P5 payload layout (zstd whole vs delta)"
layout="$ROOT/probes/p5_payload_layout/layout.awk"

# Cost tables: "alone NAME BYTES", "patch REF TARGET BYTES", "free NAME".
# A free payload is stored raw anyway (the Windows x64 PE), so it can serve as
# a reference at no cost. Deltas reference only stored payloads (depth 1).
plan() { printf '%s\n' "$@" | awk -f "$layout" | tr '\n' ';'; }

out="$(plan 'alone a 120' 'alone b 100' 'alone c 100' \
	'patch a b 10' 'patch a c 10' 'patch b c 50' 'patch c b 50' 'patch b a 60' 'patch c a 60')"
assert_eq "optimum stores the best reference, not the smallest payload" \
	"total 140;root a;patch a b;patch a c;" "$out"

out="$(plan 'free w' 'alone x 50' 'patch w x 5')"
assert_eq "a free raw payload serves as a zero-cost reference" "total 5;patch w x;" "$out"

out="$(plan 'alone p 10' 'alone q 10' 'patch p q 20' 'patch q p 20')"
assert_eq "deltas larger than whole frames are not used" "total 20;root p;root q;" "$out"

out="$(plan 'alone a 100' 'alone b 100' 'alone c 100' 'patch a b 1' 'patch b c 1' 'patch a c 90' \
	'patch b a 100' 'patch c a 100' 'patch c b 100')"
assert_eq "deltas never chain through another delta (depth 1)" "total 191;root a;patch a b;patch a c;" "$out"

# End to end on P2's real payloads: every chosen delta must rebuild the exact bytes.
p2_out="${p2_out:-$SCRATCH/p2}"
[ -f "$p2_out/app-x64win.exe" ] || "$ROOT/probes/p2_native_targets/build" "$p2_out" >/dev/null 2>&1
p5="$SCRATCH/p5/in"; mkdir -p "$p5"
for f in app-x64musl app-arm64musl app-x64mac app-arm64mac app-x64win.exe app-arm64win.exe; do cp "$p2_out/$f" "$p5/"; done
mkdir -p "$p5/not-a-payload"  # directories in IN_DIR are ignored
run_capture "$ROOT/probes/p5_payload_layout/measure" --free app-x64win.exe "$p5" "$SCRATCH/p5/work"
assert_rc0 "measure runs on the P2 payloads"
case "$out" in *"verified 5/5"*) pass "every stored frame and delta rebuilds byte-identical payloads";; *) fail "round-trip verification" "$out";; esac

# Reruns reuse cached frames: nothing is recompressed when inputs are unchanged.
stamp() { find "$SCRATCH/p5/work/alone" "$SCRATCH/p5/work/patch" -name "*.zst" -printf "%P %C@\n" | sort; }
before="$(stamp)"
run_capture "$ROOT/probes/p5_payload_layout/measure" --free app-x64win.exe "$p5" "$SCRATCH/p5/work"
assert_eq "rerun reuses every cached frame" "$before" "$(stamp)"

# The verification must bite: corrupt one encoded frame of the chosen plan
# (cached, so measure reuses it) and expect a failed rebuild.
victim="$(printf '%s\n' "$out" | awk '$1 == "root" { print "alone/" $2 ".zst"; exit } $1 == "patch" { print "patch/" $2 "--" $3 ".zst"; exit }')"
vf="$SCRATCH/p5/work/$victim"
printf '\377\377\377\377' | dd of="$vf" bs=1 seek=$(( $(wc -c < "$vf") / 2 )) conv=notrunc 2>/dev/null
touch "$vf"
run_capture "$ROOT/probes/p5_payload_layout/measure" --free app-x64win.exe "$p5" "$SCRATCH/p5/work"
case "$rc:$out" in [1-9]*"verified 4/5"*) pass "a corrupted frame fails verification";; *) fail "corruption detection" "rc=$rc $(printf '%s' "$out" | tail -1)";; esac

# Branch-address filter (BCJ, as in xz): rewrites relative CALL/JMP (x86-64) and
# BL/ADRP (arm64) targets as absolute file positions so repeated calls to one
# function share bytes. It must be exactly invertible on any input.
bcj="$SCRATCH/p5/bcj"
run_capture zig cc -O2 -o "$bcj" "$ROOT/probes/p5_payload_layout/bcj.c"
assert_rc0 "bcj builds"
# Seeded LCG bytes: deterministic pseudo-random input with many E8/E9/BL-like patterns.
LC_ALL=C awk 'BEGIN { s = 20261013; for (i = 0; i < 262144; i++) { s = (s * 1103515245 + 12345) % 2147483648; printf "%c", int(s / 65536) % 256 } }' > "$SCRATCH/p5/random"
for arch in x86_64 aarch64; do
	for f in "$SCRATCH/p5/random" "$p5/app-x64musl" "$p5/app-arm64mac" "$p5/app-x64win.exe"; do
		"$bcj" encode "$arch" < "$f" > "$SCRATCH/p5/enc" && "$bcj" decode "$arch" < "$SCRATCH/p5/enc" > "$SCRATCH/p5/dec"
		run_capture cmp "$SCRATCH/p5/dec" "$f"
		assert_rc0 "bcj $arch decode(encode(x)) == x for $(basename "$f")"
		"$bcj" decode "$arch" < "$f" > "$SCRATCH/p5/dec" && "$bcj" encode "$arch" < "$SCRATCH/p5/dec" > "$SCRATCH/p5/enc"
		run_capture cmp "$SCRATCH/p5/enc" "$f"
		assert_rc0 "bcj $arch encode(decode(y)) == y for $(basename "$f")"
	done
done
"$bcj" encode x86_64 < "$p5/app-x64musl" > "$SCRATCH/p5/enc"
run_capture cmp -s "$SCRATCH/p5/enc" "$p5/app-x64musl"
[ "$rc" -eq 1 ] && [ "$(wc -c < "$SCRATCH/p5/enc")" -eq "$(wc -c < "$p5/app-x64musl")" ] && pass "bcj x86_64 rewrites a real x86-64 binary" || fail "bcj x86_64 changes bytes" "rc=$rc"
"$bcj" encode aarch64 < "$p5/app-arm64musl" > "$SCRATCH/p5/enc"
run_capture cmp -s "$SCRATCH/p5/enc" "$p5/app-arm64musl"
[ "$rc" -eq 1 ] && [ "$(wc -c < "$SCRATCH/p5/enc")" -eq "$(wc -c < "$p5/app-arm64musl")" ] && pass "bcj aarch64 rewrites a real arm64 binary" || fail "bcj aarch64 changes bytes" "rc=$rc"
