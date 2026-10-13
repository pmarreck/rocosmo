# Optimal depth-1 delta layout for a multi-target container.
# Input lines: "alone NAME BYTES" (whole zstd frame), "patch REF TARGET BYTES"
# (zstd --patch-from delta), "free NAME" (stored raw anyway, usable as a reference).
# Exhaustive search over which payloads are stored whole ("roots"); every other
# payload becomes a delta against a root or a free payload, never against
# another delta, so rebuilding needs at most one reference. 2^N subsets is fine
# for the handful of OS/CPU targets a container carries.
# Output: "total BYTES", then "root NAME" and "patch REF TARGET" lines.
$1 == "alone" { if (!($2 in alone)) names[n++] = $2; alone[$2] = $3 }
$1 == "patch" { patch[$2 SUBSEP $3] = $4 }
$1 == "free" { free[$2] = 1 }
END {
	sort_names()
	best = -1
	for (mask = 0; mask < 2 ^ n; mask++) {
		cost = 0
		for (i = 0; i < n; i++) if (bit(mask, i)) cost += alone[names[i]]
		ok = 1
		for (i = 0; i < n && ok; i++) {
			if (bit(mask, i)) continue
			if (cheapest_ref(mask, names[i]) == "") ok = 0
			else cost += ref_cost
		}
		if (ok && (best < 0 || cost < best)) { best = cost; best_mask = mask }
	}
	if (best < 0) { print "layout: no feasible plan" > "/dev/stderr"; exit 1 }
	print "total " best
	for (i = 0; i < n; i++) if (bit(best_mask, i)) print "root " names[i]
	for (i = 0; i < n; i++) if (!bit(best_mask, i)) print "patch " cheapest_ref(best_mask, names[i]) " " names[i]
}
function bit(m, i) { return int(m / 2 ^ i) % 2 }
# Cheapest stored reference for target t; sets ref_cost. Ties go to the
# alphabetically first reference so the plan is deterministic.
function cheapest_ref(mask, t,    j, r, c, best_r) {
	best_r = ""
	for (j = 0; j < n; j++) if (bit(mask, j)) best_r = pick(names[j], t, best_r)
	for (r in free) best_r = pick(r, t, best_r)
	return best_r
}
function pick(r, t, best_r,    c) {
	if (!((r SUBSEP t) in patch)) return best_r
	c = patch[r SUBSEP t]
	if (best_r == "" || c < ref_cost || (c == ref_cost && r < best_r)) { ref_cost = c; return r }
	return best_r
}
function sort_names(    i, j, tmp) {
	for (i = 1; i < n; i++) for (j = i; j > 0 && names[j - 1] > names[j]; j--) {
		tmp = names[j]; names[j] = names[j - 1]; names[j - 1] = tmp
	}
}
