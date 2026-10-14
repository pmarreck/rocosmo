# Shared assertions for rocosmo probe tests. Sourced, not executed.
# Counters are global so ./test can aggregate failures across suites.

PASS_COUNT=${PASS_COUNT:-0}
FAIL_COUNT=${FAIL_COUNT:-0}

FAILED_LABELS=${FAILED_LABELS:-}

pass() { PASS_COUNT=$((PASS_COUNT + 1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
fail() {
	FAIL_COUNT=$((FAIL_COUNT + 1))
	FAILED_LABELS="$FAILED_LABELS\n  ✗ $1: ${2-}"
	printf '  \033[31m✗\033[0m %s\n' "$1"
	[ -n "${2-}" ] && printf '      %s\n' "$2"
	return 0
}

# Run a command, capturing stdout into $out, stderr into $err and status into $rc.
run_capture() {
	local errfile="$SCRATCH/.stderr.$$"
	out="$("$@" 2>"$errfile")"
	rc=$?
	err="$(cat "$errfile")"
	rm -f -- "$errfile"
}

assert_eq() { # label expected actual
	if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected [$2] got [$3]"; fi
}

assert_rc0() { # label (uses $rc, $err)
	if [ "$rc" -eq 0 ]; then pass "$1"; else fail "$1" "exit $rc: $(printf '%s' "$err" | tail -5)"; fi
}

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=60 -o LogLevel=ERROR)

# Copy an artifact to a real remote host and run it there. Host aliases come from
# the ignored local/hosts.env; an unconfigured host is reported as a failure so
# the suite never goes green without native evidence.
remote_run() { # var_name remote_name local_file args...
	local var="$1" rname="$2" file="$3"; shift 3
	local host="${!var-}"
	if [ -z "$host" ]; then rc=99; out=""; err="$var not set (see local/hosts.env)"; return; fi
	run_capture scp -q "${SSH_OPTS[@]}" "$file" "$host:$rname"
	[ "$rc" -eq 0 ] || return
	local prefix="./"; case "$rname" in *.exe) prefix="";; esac
	run_capture ssh "${SSH_OPTS[@]}" "$host" "$prefix$rname $*"
}

# Build a PATH directory holding only the named tools, to prove an artifact's
# launcher needs nothing else.
minimal_path() { # dir tool...
	local dir="$1" t; shift; mkdir -p "$dir"
	for t in "$@"; do ln -sf "$(command -v "$t")" "$dir/$t"; done
	printf '%s' "$dir"
}

# Run a container inside WSL2 both ways. WSL registers binfmt_misc
# "WSLInterop" for magic "MZ" at offset 0, so direct ./ execution hands the
# file to Windows (the PE runs, no Linux cache is touched); `sh ./file` takes
# the Linux dispatcher path. The cache-entry count tells the two apart.
wsl_both_ways() { # label local_file remote_name cached_entries
	local host="${ROCOSMO_WSL_X64_HOST-}" label="$1" file="$2" name="$3" entries="$4"
	if [ -z "$host" ]; then fail "WSL2 runs ($label)" "ROCOSMO_WSL_X64_HOST not set"; return; fi
	scp -q "${SSH_OPTS[@]}" "$file" "$host:$name"
	run_capture ssh "${SSH_OPTS[@]}" "$host" "c=/tmp/rocosmo-wsl-\$\$; XDG_CACHE_HOME=\$c sh ./$name 20; echo entries=\$(find \$c -type f 2>/dev/null | wc -l)"
	assert_eq "WSL2 linux x86_64 via sh ($label): Linux path, $entries cache file(s)" "121 entries=$entries" "$(printf '%s' "$out" | tr '\n' ' ' | sed 's/ $//')"
	run_capture ssh "${SSH_OPTS[@]}" "$host" "c=/tmp/rocosmo-wsl-\$\$; XDG_CACHE_HOME=\$c ./$name 20; echo entries=\$(find \$c -type f 2>/dev/null | wc -l)"
	assert_eq "WSL2 direct ./ exec ($label): WSLInterop runs the Windows PE, no Linux cache" "121 entries=0" "$(printf '%s' "$out" | tr -d '\r' | tr '\n' ' ' | sed 's/ $//')"
}
