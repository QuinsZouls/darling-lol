#!/bin/sh
# packaging/testdata/run-build-log-gates.sh -- the three install-log invariants of
# scripts/build-packaging.sh, pinned in-tree, hermetic and ASSERTING.
#
# Run from the repo root:
#
#     bash packaging/testdata/run-build-log-gates.sh      # `sh` works too: this file is POSIX
#
# Why it exists: check_install_log() had been asserted exactly once -- by a reviewer, with a rig
# that lives in the T2 coder's artifacts (t2-build-packaging/verify.sh) and would never run again.
# That left the two predicates that are weaker than their names (review MINOR-1/2) and the
# host-filesystem exemption (MINOR-3) unpinned: a later edit could re-weaken any of them and ship.
# With this file, `bash packaging/testdata/run-gates.sh` covers them (review F10).
#
# The code under test is the DELIVERED function, never a copy: it is extracted from
# scripts/build-packaging.sh BY TEXT (`sed -n` between `^check_install_log() {` and the next `}` at
# column 0) and sourced exactly as extracted, so a copy cannot drift from what ships, and the
# extraction is fatal (not a SKIP) if the markers move. Only fatal()/note() and $pkg_root come from
# the driver -- one line each in the script (the extraction's sha256 is printed for the record).
#
# The 9 cases are the review's table (a-g), each asserting BOTH the exit status (FATAL is 1; the
# correct log is 0) and WHICH invariant fired, by its FATAL text -- so a case cannot pass by firing
# the wrong one. (d), (f) and (g) are the three regression pins of MINOR-3/1/2: all three returned
# rc=0 before the fix. (d)+(d') drive the SAME log, differing only in whether the directory it
# names exists on this host -- MINOR-3 was exactly that the verdict followed the filesystem.
#
# The last section is the negative control: with LOG_GATE_FLIP=<case> one expectation is inverted
# and this file must go red, on that row and nowhere else.
#
# Hermetic: the fixture logs are generated here, inside one private `mktemp -d`, because every one
# of them has to name the staging root this run created -- a shipped copy could not carry the paths
# it asserts on. Nothing outside $WORK is read or written.
set -u

if [ ! -f scripts/build-packaging.sh ] || [ ! -d packaging/testdata ]; then
	echo "run-build-log-gates: run me from the repo root (no scripts/ in $PWD)" >&2
	exit 2
fi

FLIP=${LOG_GATE_FLIP:-}   # negative-control hook: the named case's expected rc becomes 99
src=scripts/build-packaging.sh
WORK=$(mktemp -d "${TMPDIR:-/tmp}/darling-log-gates.XXXXXX")
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
ROOT=$WORK/dist/pkg/root         # the staging root every fixture log names
mkdir -p "$ROOT"

die() {
	echo "run-build-log-gates: FATAL $*" >&2
	exit 2
}

# --- extract check_install_log() from the delivered script, by text ----------------------------
start=$(grep -n '^check_install_log() {' "$src" | cut -d: -f1 | head -1)
[ -n "$start" ] || die "check_install_log() is not defined at column 0 in $src -- update this harness"
end=$(awk -v s="$start" 'NR > s && /^}/{ print NR; exit }' "$src")
[ -n "$end" ] || die "check_install_log() never closes with a '}' at column 0 in $src"
sed -n "${start},${end}p" "$src" > "$WORK/check_install_log.sh"
[ -s "$WORK/check_install_log.sh" ] || die "the extraction came back empty (lines $start..$end)"
grep -q 'host /usr/local paths' "$WORK/check_install_log.sh" || die "the extracted text does not look like check_install_log()"

driver=$WORK/driver.sh
{
	printf 'set -eu\n'
	printf "pkg_root='%s'\n" "$ROOT"
	printf 'fatal() { echo "build-packaging: FATAL $*" >&2; exit 1; }\n'
	printf 'note() { echo "build-packaging: $*"; }\n'
	cat "$WORK/check_install_log.sh"
	printf 'check_install_log "$1"\n'
} > "$driver"

SHOW=$(command -v sh || echo sh)
printf 'run-build-log-gates: check_install_log extracted from %s lines %s..%s (sha256 %s)\n' \
	"$src" "$start" "$end" "$(sha256sum "$WORK/check_install_log.sh" | cut -d' ' -f1)"
printf '  driver: %s %s   root: %s\n' "$SHOW" "$driver" "$ROOT"

# --- the three invariants, as they must appear in the FATAL text -------------------------------
INV1='FATAL the install log names paths outside '
INV2='FATAL the install log names host /usr/local paths:'
INV3='FATAL the install log reports Up-to-date for paths this run never installed:'
NOTE='install log: 5 paths installed, 2 Up-to-date (1 of them covered by a duplicate install rule, 1 implicit parent directories)'

pass=0; fail=0
ok() { pass=$((pass+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
no() { fail=$((fail+1)); printf '  \033[31mFAIL\033[0m %s -- %s\n' "$1" "$2"; }
sec() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# run_case CASE LABEL WANT_RC WANT_REGEX -- runs the driver over $WORK/case.log
run_case() {
	label=$1; want_rc=$3; want_re=$4
	[ "$FLIP" = "$2" ] && want_rc=99
	rc=0; out=$($SHOW "$driver" "$WORK/case.log" 2>&1) || rc=$?
	if [ "$rc" != "$want_rc" ]; then
		no "$label" "rc $rc, want $want_rc ($(printf '%s' "$out" | tail -1))"
		return
	fi
	# -F, not -E: every pattern below is a literal (they contain `(`, `)' and `/`)
	if printf '%s' "$out" | grep -qF "$want_re"; then
		ok "$label (rc $rc: $(printf '%s' "$out" | grep -m1 -F "$want_re" | sed 's/^build-packaging: //'))"
	else
		no "$label" "rc $rc as expected, but nothing matched the invariant text '$want_re': $(printf '%s' "$out" | tail -1)"
	fi
}

# one `printf` per fixture log: a line starting with `--` is data, never an option
log() { printf '%s\n' "$@" > "$WORK/case.log"; }

sec "the 9 cases: each FATAL must name the invariant that fires"

# (a) a claim outside the staging root -> (1). Baseline: the old substring test caught this too.
log "-- Installing: $ROOT/usr/bin/darling" \
	'-- Installing: /usr/bin/elsewhere-helper'
run_case "case a: a path outside the root (invariant 1)" a 1 "$INV1"

# (b) a claim at the HOST /usr/local, absolute -> it is outside the root, so (1) fires, not (2).
# This is also the shape of the published v0.1.0 artefact (every claim /usr/local/...): the stand-in
# for that soundness control, which cannot ship in-tree (4.6 MB, the artefact we must not ship).
log "-- Installing: $ROOT/usr/bin/darling" \
	'-- Installing: /usr/local/libexec/darling/private'
run_case "case b: a host /usr/local path outside the root (invariant 1)" b 1 "$INV1"

# (b') the D1 shape: prefix /usr/local INSIDE the root -> (2). The guest skeleton is elsewhere.
log "-- Installing: $ROOT/usr/bin/darling" \
	"-- Installing: $ROOT/usr/local/bin/darling"
run_case "case b': $ROOT/usr/local/bin/darling, the D1 shape (invariant 2)" b2 1 "$INV2"

# (c) Up-to-date for a file this run never installed -> (3). Baseline.
log "-- Installing: $ROOT/usr/bin/darling" \
	"-- Up-to-date: $ROOT/usr/bin/ghost-file"
run_case "case c: Up-to-date for a never-installed FILE (invariant 3)" c 1 "$INV3"

# (d)/(d') the SAME log, one directory created on this host and one not -> (3) both times.
# MINOR-3: (d) used to pass *because* the directory existed ([ -d ]), so the verdict was host
# state; the exemption is now derived from the log (a deeper Installing), and neither of these
# fixtures has one.
log "-- Installing: $ROOT/usr/bin/darling" \
	"-- Up-to-date: $ROOT/usr/lib/emptydir"
mkdir -p "$ROOT/usr/lib/emptydir"
run_case "case d: Up-to-date for a dir that EXISTS on the host (invariant 3, F3 pin)" d 1 "$INV3"
rm -rf "$ROOT/usr/lib/emptydir"
[ -d "$ROOT/usr/lib/emptydir" ] && die "could not remove $ROOT/usr/lib/emptydir: case d' would not be distinct"
run_case "case d': the same line, dir ABSENT (invariant 3)" d2 1 "$INV3"

# (e) a correct /usr log -> rc 0, and the note's own numbers: no false positive.
log "-- Installing: $ROOT/usr/bin/darling" \
	"-- Installing: $ROOT/usr/libexec/darling/usr/local" \
	"-- Installing: $ROOT/usr/libexec/darling/usr/local/share" \
	"-- Installing: $ROOT/usr/libexec/darling/usr/bin/gzip" \
	"-- Installing: $ROOT/usr/libexec/darling/usr/lib/libdarling.so" \
	"-- Up-to-date: $ROOT/usr/libexec/darling/usr/bin/gzip" \
	"-- Up-to-date: $ROOT/usr/libexec/darling/usr/lib"
run_case "case e: a correct /usr log (payload + duplicate rule + implicit parent)" e 0 "$NOTE"

# (f) the root string later in the path -> (1). MINOR-1: `grep -vF` matched anywhere, so this
# passed while cmake installed outside the tree.
log "-- Installing: $ROOT/usr/bin/darling" \
	"-- Installing: /opt$ROOT/usr/bin/darling"
run_case "case f: /opt\$root/usr/bin/darling, root string later (invariant 1, F1 pin)" f 1 "$INV1"

# (g) a host /usr/local path that also CONTAINS the guest skeleton -> (2). MINOR-2: the greedy
# `sed 's#.*/libexec/darling/usr/local#...#'` masked exactly this shape, so the sweep was blind.
log "-- Installing: $ROOT/usr/bin/darling" \
	"-- Installing: $ROOT/usr/local/x/libexec/darling/usr/local/y"
run_case "case g: /usr/local/x/libexec/darling/usr/local/y (invariant 2, F2 pin)" g 1 "$INV2"

# --- negative control --------------------------------------------------------------------------
# The child's rows are ANSI-stripped before grepping (`PASS`/`FAIL` sit inside colour codes, and an
# anchored match on the raw output would see nothing and pass vacuously).
cpass=0; cfail=0
cok() { cpass=$((cpass+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
# a control failure lands in `cfail` only: the two tallies stay honest (cases vs control) and the
# exit status is driven by their sum -- an inverted run that stays green is the one outcome this
# file must never report
cno() { cfail=$((cfail+1)); printf '  \033[31mFAIL\033[0m %s -- %s\n' "$1" "$2"; }
if [ -z "$FLIP" ]; then
	sec "negative control: one case's expectation inverted MUST turn this file red"
	nrc=0
	LOG_GATE_FLIP=d $SHOW "$0" > "$WORK/ctrl.out" 2>&1 || nrc=$?
	# ANSI off before grepping: the rows carry colour codes *between* the word and the label.
	esc=$(printf '\033')
	sed "s/${esc}\[[0-9;]*m//g" "$WORK/ctrl.out" > "$WORK/ctrl.txt"
	if [ "$nrc" != 0 ]; then cok "the inverted run exits non-zero (rc $nrc)"; else cno "negative control: the inverted run exited 0" "a table that cannot go red is not a table"; fi
	nfail=$(grep -c '^  FAIL case d:' "$WORK/ctrl.txt" || true)
	if [ "$nfail" = 1 ]; then cok "it fails the inverted row (case d), exactly once: $(grep -m1 '^  FAIL case d:' "$WORK/ctrl.txt" | sed 's/^  FAIL //')"; else cno "negative control: the inverted row" "expected 1 'FAIL case d:' line, got $nfail"; fi
	nred=$(grep -c '^  FAIL case ' "$WORK/ctrl.txt" || true)
	if [ "$nred" = 1 ]; then cok "no other row goes red ($nred FAIL row)"; else cno "negative control: the other rows" "expected 1 FAIL row, got $nred"; fi
	npass=$(grep -c '^  PASS case ' "$WORK/ctrl.txt" || true)
	if [ "$npass" = 8 ]; then cok "and the other 8 of 9 still pass"; else cno "negative control: the other rows" "expected 8 PASS rows, got $npass"; fi
fi

sec "SUMMARY"
printf '  cases:   %d passed, %d failed\n' "$pass" "$fail"
printf '  control: %d passed, %d failed\n' "$cpass" "$cfail"
printf '  total:   %d passed, %d failed\n' "$((pass+cpass))" "$((fail+cfail))"
[ "$pass" = 9 ] || { printf '  FATAL the case table must have 9 rows, has %d\n' "$pass"; fail=$((fail+1)); }
[ "$((fail+cfail))" = 0 ] || exit 1
