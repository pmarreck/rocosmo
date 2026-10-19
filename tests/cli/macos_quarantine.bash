# macOS downloads: a browser marks a downloaded file with com.apple.quarantine.
# From a shell, a quarantined universal container still runs (`./app` and
# `sh app`): the shell reads it as a script, so Gatekeeper is never asked, and
# the runtime and payload the dispatcher writes carry no quarantine attribute.
# Gatekeeper's own verdict on the container is "rejected" (it is unsigned),
# which is why opening it from Finder shows Gatekeeper's dialog instead of
# running it (observed 2026-10-18, macOS 26.7.1; RESEARCH.md). That GUI path
# is not automated here because the dialog waits for a click.
echo "CLI: macOS quarantine (a browser-downloaded container)"

mq="$SCRATCH/macos-quarantine"; mkdir -p "$mq"
pack_bin="${pack_bin:-$SCRATCH/p3/tool/bin/rocosmo-pack}"
for t in aarch64-macos x86_64-macos x86_64-windows x86_64-linux-musl; do
	run_capture zig build-exe "$ROOT/examples/hello.zig" -target "$t" -O ReleaseSmall -femit-bin="$mq/$t"
	assert_rc0 "build the exit-145 payload for $t"
done
run_capture "$pack_bin" --layout zstd --level 3 --app-id dev.rocosmo.quarantine --windows-x86_64 "$mq/x86_64-windows" \
	--linux-x86_64 "$mq/x86_64-linux-musl" --macos-arm64 "$mq/aarch64-macos" --macos-x86_64 "$mq/x86_64-macos" -o "$mq/app"
assert_rc0 "pack a universal container with macOS payloads"

host="${ROCOSMO_MACOS_ARM64_HOST-}"
if [ -z "$host" ]; then
	fail "macOS quarantine checks" "ROCOSMO_MACOS_ARM64_HOST not set"
else
	scp -q "${SSH_OPTS[@]}" "$mq/app" "$host:rocosmo-quarantine"
	# Mark it the way Safari marks a download, then run it twice from a shell
	# with fresh caches and report what Gatekeeper and xattr say.
	run_capture ssh "${SSH_OPTS[@]}" "$host" 'f=rocosmo-quarantine; chmod 755 $f
xattr -w com.apple.quarantine "0083;$(printf %x $(date +%s));Safari;$(uuidgen)" $f
echo "quarantined=$(xattr -p com.apple.quarantine $f >/dev/null 2>&1 && echo yes || echo no)"
echo "spctl=$(spctl --assess --type execute $f >/dev/null 2>&1 && echo accepted || echo rejected)"
c1=$(mktemp -d); XDG_CACHE_HOME=$c1 ./$f; echo "dot_slash=$?"
c2=$(mktemp -d); XDG_CACHE_HOME=$c2 sh $f; echo "sh=$?"
q=0; for e in $(find $c1 -type f); do xattr -p com.apple.quarantine "$e" >/dev/null 2>&1 && q=$((q+1)); done
echo "extracted=$(find $c1 -type f | wc -l | tr -d " ") quarantined_extracted=$q"
rm -rf $c1 $c2 $f'
	assert_eq "a quarantined container runs from a shell; Gatekeeper rejects it as unsigned; nothing it extracts is quarantined" \
		"quarantined=yes
spctl=rejected
dot_slash=145
sh=145
extracted=2 quarantined_extracted=0" "$out"
fi
