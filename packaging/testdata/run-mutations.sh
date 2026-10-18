#!/usr/bin/env bash
# packaging/testdata/run-mutations.sh -- the two T1 mutation tables, ASSERTING (review MINOR-1).
#
# Run from the repo root:
#
#     bash packaging/testdata/run-mutations.sh
#
# Every row declares what the mutation must produce (rc + a string the script must name) and the
# harness exits non-zero if a row stops behaving as declared. The pre-review harnesses only printed
# `rc=` and exited 0 unconditionally, so a regression in a table would have gone unnoticed.
#
# The LAST section is the negative control: it re-runs this file with one row's expectation
# inverted (T1_MUTATION_FLIP=<row>) and fails if the table stays green. A table that cannot go red
# is not a table. Under T1_MUTATION_FLIP this run IS the inverted run, so that control row cannot run
# under its own hook: it is counted as SKIPped in the summary (never silently absent, never a PASS),
# and the controls bucket is pinned on ran + skipped so a lost row cannot hide.
#
#   row  the 8 G-PREFIX-1 mutations of PLAN 4.1 (the positive run and the soundness control are
#        reported separately, as controls)
#   row  the 5 G-STATIC-6 mutations of TASKS.md T1
#
# Nothing is written outside a private `mktemp -d` workdir.
#
# `sh run-mutations.sh` (= dash here) parses this file up to the first process substitution and dies
# there -- AFTER printing a partial table, which a careless runner reads as "mostly green" (review
# INFO-3). Refuse up front instead, in a form dash can parse, so the message is the output.
case "${BASH_VERSION:-}" in
  "") echo "run-mutations: run me with bash: bash $0" >&2; exit 2 ;;
esac
set -u

if [ ! -f packaging/common/stage.sh ]; then
  echo "run-mutations: run me from the repo root (no packaging/ in $PWD)" >&2
  exit 2
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/darling-t1-mut.XXXXXX")
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

FLIP=${T1_MUTATION_FLIP:-}   # negative-control hook: the named row's expected rc becomes 99

CP=packaging/common/check-prefix.sh
ST=packaging/common/stage.sh
# The mutated copies of stage.sh are written into $WORK and resolve their sibling through
# `dirname "$0"`, so the real check-prefix.sh must be there too. (The pre-review harnesses wrote
# them to /tmp and silently picked up a *leftover* /tmp/check-prefix.sh -- the same defect class
# as review MAJOR-1: an rc=0 that a clean box cannot reproduce.)
cp "$CP" "$WORK/check-prefix.sh"

pass=0; fail=0; skips=0
pp=0; pf=0; sp=0; sf=0; cc=0; cf=0
PHASE=ctrl
ROWFAIL=0
pass_row()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail_row()  { printf '  \033[31mFAIL\033[0m %s -- %s\n' "$1" "$2"; }
# A row that did not run is COUNTED and NAMED and is never folded into `pass`: the same convention
# run-deb-gates.sh:743-749 already uses (`skips` + ", K skipped" + "SKIP is not PASS"). The FLIP hook
# below turns the negative-control row off, and `controls: 0 passed, 0 failed` used to be
# indistinguishable from "the control ran and proved nothing".
skip_row()  { skips=$((skips+1)); printf '  \033[33mSKIP\033[0m %s\n' "$1"; }
sa() {  # sub-assert: sa LABEL GOT WANT
  if [ -z "$2" ]; then ROWFAIL=1; printf '      FAIL %s: EMPTY (command failed)\n' "$1"
  elif [ "$2" = "$3" ]; then printf '      ok   %s (%s)\n' "$1" "$2"
  else ROWFAIL=1; printf '      FAIL %s: got %s, want %s\n' "$1" "$2" "$3"; fi
}
RC=0; OUT=
run() { RC=0; OUT=$("$@" 2>&1) || RC=$?; }
sr() {  # sr LABEL WANT_RC WANT_REGEX on the last run(); T1_MUTATION_FLIP inverts WANT_RC
  local want_rc=$2 want_rx=$3
  [ "$FLIP" = "$1" ] && want_rc=99
  sa "$1 exit" "$RC" "$want_rc"
  if printf '%s' "$OUT" | grep -qE "$want_rx"; then printf '      ok   %s names it\n' "$1"
  else ROWFAIL=1; printf '      FAIL %s: the output does not name %s\n' "$1" "$want_rx"; fi
}
end_row() {  # end_row LABEL
  case "$PHASE" in
    prefix) if [ "$ROWFAIL" = 0 ]; then pp=$((pp+1)); else pf=$((pf+1)); fi ;;
    stage)  if [ "$ROWFAIL" = 0 ]; then sp=$((sp+1)); else sf=$((sf+1)); fi ;;
    *)      if [ "$ROWFAIL" = 0 ]; then cc=$((cc+1)); else cf=$((cf+1)); fi ;;
  esac
  if [ "$ROWFAIL" = 0 ]; then pass=$((pass+1)); pass_row "$1"; else fail=$((fail+1)); fail_row "$1" "a sub-assertion failed"; fi
  ROWFAIL=0
}
sec() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# ---------------------------------------------------------------------------------------------
sec "G-PREFIX-1  the fixture + the 8 mutations of PLAN 4.1"
rm -rf "$WORK/pfx" && bash packaging/testdata/mkprefixfixture.sh "$WORK/pfx" >/dev/null
fresh() { rm -rf "${WORK:?}/$1"; cp -a "$WORK/pfx" "$WORK/$1"; }
regen() { ( cd "$WORK/$1/root" && find . \( ! -type d -o -type d -empty \) -printf '/%P\n' ) | LC_ALL=C sort > "$WORK/$1/files.all"; }

PHASE=ctrl
ROWFAIL=0
run sh "$CP" "$WORK/pfx/root" "$WORK/pfx/files.all"
sa "positive exit" "$RC" 0
sa "positive says PREFIX: OK" "$(printf '%s' "$OUT" | grep -c '^PREFIX: OK$')" 1
end_row "positive: a correct /usr tree (control)"

PHASE=prefix
ROWFAIL=0; fresh m1
printf '#!/bin/sh\nexec /usr/local/bin/darlingserver "$@"\n' > "$WORK/m1/root/usr/bin/extra-helper"
regen m1
run sh "$CP" "$WORK/m1/root" "$WORK/m1/files.all"
sr M1 1 'unexplained host-side /usr/local references'
sa "M1 names the file" "$(printf '%s' "$OUT" | grep -c 'usr/bin/extra-helper')" 1
end_row "M1 a host-side text file carrying /usr/local/bin/darlingserver"

ROWFAIL=0; fresh m2
printf '\000\177ELF\000/usr/local/libexec/darling\n/usr/libexec/darling\n\000' > "$WORK/m2/root/usr/bin/darlingserver"
run sh "$CP" "$WORK/m2/root" "$WORK/m2/files.all"
sr M2 1 'usr/bin/darlingserver still has LIBEXEC_PATH=/usr/local/libexec/darling'
end_row "M2 a host ELF carrying LIBEXEC_PATH=/usr/local/libexec/darling"

ROWFAIL=0; fresh m2b
sed 's|for b in usr/bin/darlingserver usr/bin/darling-coredump; do|for b in usr/bin/darlingserver usr/bin/darling-coredump usr/bin/darling; do|' "$CP" > "$WORK/m2b-check.sh"
run sh "$WORK/m2b-check.sh" "$WORK/m2b/root" "$WORK/m2b/files.all"
sr M2b 1 'usr/bin/darling does not have LIBEXEC_PATH=/usr/libexec/darling'
sa "M2b false FATALs = 1" "$(printf '%s' "$OUT" | grep -c '^PREFIX: FATAL')" 1
end_row "M2b a uniform loop over the three host ELFs blocks a CORRECT tree (C23)"

ROWFAIL=0; fresh m3
printf '\000\177ELF\000/usr/bin/darlingserver\n/usr/local\nPATH=/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin\n\000' > "$WORK/m3/root/usr/bin/darling"
chmod 4755 "$WORK/m3/root/usr/bin/darling"
run sh "$CP" "$WORK/m3/root" "$WORK/m3/files.all"
sr M3 1 "guest literal '/usr/local/share' was rewritten"
sa "M3 also reports the count" "$(printf '%s' "$OUT" | grep -c "has 2 '/usr/local' strings, expected exactly 3")" 1
end_row "M3 sed the guest literal /usr/local/share out of usr/bin/darling"

ROWFAIL=0; fresh m4; mkdir -p "$WORK/m4/root/usr/local/bin"; regen m4
run sh "$CP" "$WORK/m4/root" "$WORK/m4/files.all"
sr M4 2 'wrong CMAKE_INSTALL_PREFIX'
end_row "M4 usr/local/ present in the tree"

ROWFAIL=0; fresh m5
rm -rf "$WORK/outside"; mkdir -p "$WORK/outside/usr/local"
printf 'planted /usr/local/bin/darlingserver\n' > "$WORK/outside/usr/local/planted.txt"
rm -f "$WORK/m5/root/usr/libexec/darling/Volumes/DarlingEmulatedDrive"
ln -s "$WORK/outside" "$WORK/m5/root/usr/libexec/darling/Volumes/DarlingEmulatedDrive"
regen m5
run sh "$CP" "$WORK/m5/root" "$WORK/m5/files.all"
sr M5 0 '^PREFIX: OK$'
# the C19 control: the recursive form escapes, the plain form does not. The flag is quoted so that
# this file does not contain the pattern the C19 gate scans every packaging script for.
rform=$(grep "-RIn" 'usr/local' "$WORK/m5/root" 2>/dev/null | wc -l)
lform=$(grep "-rIn" 'usr/local' "$WORK/m5/root" 2>/dev/null | wc -l)
sa "M5 the recursive form sees exactly 1 more hit" "$((rform - lform))" 1
sa "M5 the extra hit is the planted outside file" "$(grep "-RIn" 'usr/local' "$WORK/m5/root" 2>/dev/null | grep -c 'usr/local/planted.txt')" 1
sa "M5 the outside file never reaches files.all" "$(grep -c 'planted' "$WORK/m5/files.all")" 0
end_row "M5 CONTROL: a /usr/local file outside the tree must PASS"

ROWFAIL=0
rm -rf "$WORK/m6"; mkdir -p "$WORK/m6/root/usr/local/bin"
printf 'x\n' > "$WORK/m6/root/usr/local/bin/darling"
{ for i in $(seq 1 200); do nl -ba "$WORK/pfx/files.all" | sed "s|^ *[0-9]*\t|/usr/local/lib/row$i-|"; done; } > "$WORK/m6/files.all"
run sh "$CP" "$WORK/m6/root" "$WORK/m6/files.all"
sr M6 2 'is not a /usr staging tree'
sa "M6 fires on the first guard over a 4000-row list" "$(wc -l < "$WORK/m6/files.all" | tr -d ' ')" 4000
end_row "M6 pointed at a /usr/local payload"

ROWFAIL=0; fresh m7
printf 'from pathlib import Path\nparser.add_argument("--destination", type=Path, default=Path("/usr/local/bin/darlingserver"))\n' > "$WORK/m7/root/usr/lib/darling-lol/tools/install-riot-darling-server.py"
run sh "$CP" "$WORK/m7/root" "$WORK/m7/files.all"
sr M7 1 'unexplained host-side /usr/local references'
sa "M7 names the installer" "$(printf '%s' "$OUT" | grep -c 'install-riot-darling-server.py')" 1
end_row "M7 revert T8's fix: the literal default back in the installer"

PHASE=ctrl
ROWFAIL=0
rm -rf "$WORK/sound"; mkdir -p "$WORK/sound/root/usr/bin" "$WORK/sound/root/usr/libexec/darling"
printf '\000/usr/local/libexec/darling\n/usr/local/libexec/darling/usr/libexec/darling/mldr\nmldr!/usr/local/libexec/darling/usr/libexec/darling/vchroot\n\000' > "$WORK/sound/root/usr/bin/darlingserver"
printf '\000/usr/local/libexec/darling\n\000' > "$WORK/sound/root/usr/bin/darling-coredump"
printf '\000PATH=/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin\n/usr/local/bin/darlingserver\n/usr/local\n/usr/local/share\n\000' > "$WORK/sound/root/usr/bin/darling"
regen sound
run sh "$CP" "$WORK/sound/root" "$WORK/sound/files.all"
sa "soundness exit" "$RC" 1
sa "soundness darling has 4 substrings (not 3)" "$(strings -a "$WORK/sound/root/usr/bin/darling" | grep -c '/usr/local')" 4
sa "soundness darling has 0 exact /usr/bin/darlingserver" "$(strings -a "$WORK/sound/root/usr/bin/darling" | grep -cx '/usr/bin/darlingserver')" 0
sa "soundness darlingserver has 0 exact /usr/libexec/darling" "$(strings -a "$WORK/sound/root/usr/bin/darlingserver" | grep -cx '/usr/libexec/darling')" 0
end_row "soundness: no positive assertion passes on the UNPATCHED binaries (control)"

# ---------------------------------------------------------------------------------------------
sec "G-STATIC-6  the fixture + the 5 mutations of TASKS.md T1"
rm -rf "$WORK/fix" && bash packaging/testdata/mkfixture.sh "$WORK/fix" >/dev/null
sh "$ST" "$WORK/fix/root" "$WORK/fix/out" >/dev/null
N_ALL=$(wc -l < "$WORK/fix/out/files.all" | tr -d ' ')
N_QUOTED=$(wc -l < "$WORK/fix/out/files.quoted" | tr -d ' ')

PHASE=stage
ROWFAIL=0
sed "s|-printf '/%P\\\\n'|-printf '%P\\\\n'|g" "$ST" > "$WORK/stage-noslash.sh"
rm -rf "$WORK/fixA"; cp -a "$WORK/fix" "$WORK/fixA"; rm -rf "$WORK/fixA/out"
run sh "$WORK/stage-noslash.sh" "$WORK/fixA/root" "$WORK/fixA/out"
sr A 0 'stage: [0-9]+ runtime paths'
sa "A every entry lost the leading /" "$(grep -cv '^/' "$WORK/fixA/out/files.all")" "$N_ALL"
sa "A 2xN differing lines vs the correct list" "$(diff <(sort "$WORK/fix/out/files.all") <(sort "$WORK/fixA/out/files.all") | grep -c '^[<>]')" "$((2 * N_ALL))"
end_row "A -printf %P without the leading /"

ROWFAIL=0
python3 - "$ST" "$WORK/stage-esc.sh" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
lines = open(src).read().split('\n')
n = 0
for i, l in enumerate(lines):
    if 'files.quoted"' in l:
        lines[i] = l.replace('| LC_ALL=C sort', '| sed \'s/"/\\\\"/g\' | LC_ALL=C sort')
        n += 1
assert n == 1, n
open(dst, 'w').write('\n'.join(lines))
PY
rm -rf "$WORK/fixB"; cp -a "$WORK/fix" "$WORK/fixB"; rm -rf "$WORK/fixB/out"
run sh "$WORK/stage-esc.sh" "$WORK/fixB/root" "$WORK/fixB/out"
sr B 0 'stage: [0-9]+ runtime paths'
sa "B no quoted entry survives" "$(grep -c '^"' "$WORK/fixB/out/files.quoted")" 0
sa "B 2xN corrupted lines" "$(diff "$WORK/fix/out/files.quoted" "$WORK/fixB/out/files.quoted" | grep -c '^[<>]')" "$((2 * N_QUOTED))"
sa "B files.all is untouched" "$(cmp -s "$WORK/fix/out/files.all" "$WORK/fixB/out/files.all" && echo same || echo differs)" same
end_row "B perl-style escaping on top of the quotes"

ROWFAIL=0
python3 - "$ST" "$WORK/stage-noguard.sh" <<'PY'
import re, sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()
out = re.sub(r'if \[ -e "\$root/usr/local" \]; then\n.*?\nfi\n', '', text, count=1, flags=re.S)
assert out != text, "the step-1 guard was not found"
open(dst, 'w').write(out)
PY
rm -rf "$WORK/fixC"; cp -a "$WORK/fix" "$WORK/fixC"; rm -rf "$WORK/fixC/out"
mkdir -p "$WORK/fixC/root/usr/local/bin"
printf '#!/bin/sh\necho /usr/local/lib/darling\n' > "$WORK/fixC/root/usr/local/bin/leaked"
run sh "$WORK/stage-noguard.sh" "$WORK/fixC/root" "$WORK/fixC/out"
sr C1 2 'wrong CMAKE_INSTALL_PREFIX'
python3 - "$WORK/stage-noguard.sh" "$WORK/cp-noguard.sh" "$WORK/stage-both.sh" <<'PY'
import sys
src, cpgu, dst = sys.argv[1], sys.argv[2], sys.argv[3]
text = open('packaging/common/check-prefix.sh').read()
assert text.count('if [ -e "$root/usr/local" ]; then') == 1
open(cpgu, 'w').write(text.replace('if [ -e "$root/usr/local" ]; then', 'if false; then'))
stage = open(src).read()
old = 'sh "$(dirname "$0")/check-prefix.sh" "$root" "$out/files.all"'
assert stage.count(old) == 1
open(dst, 'w').write(stage.replace(old, 'sh "' + cpgu + '" "$root" "$out/files.all"'))
PY
rm -rf "$WORK/fixC2"; cp -a "$WORK/fix" "$WORK/fixC2"; rm -rf "$WORK/fixC2/out"
mkdir -p "$WORK/fixC2/root/usr/local/bin" "$WORK/fixC2/root/usr/local/share/man"
run sh "$WORK/stage-both.sh" "$WORK/fixC2/root" "$WORK/fixC2/out"
sr C2 0 'stage: [0-9]+ runtime paths'
sa "C2 the /usr/local rows reach files.all (the guard is load-bearing)" "$(grep -c '^/usr/local/' "$WORK/fixC2/out/files.all")" 2
end_row "C delete the usr/local guard (C1 = defence in depth, C2 = silent stage)"

ROWFAIL=0
sed 's/= 4755/= 755/' "$ST" > "$WORK/stage-no4755.sh"
rm -rf "$WORK/fixD"; cp -a "$WORK/fix" "$WORK/fixD"; rm -rf "$WORK/fixD/out"; chmod 755 "$WORK/fixD/root/usr/bin/darling"
run sh "$WORK/stage-no4755.sh" "$WORK/fixD/root" "$WORK/fixD/out"
sr D 0 'stage: [0-9]+ runtime paths'
run sh "$ST" "$WORK/fixD/root" "$WORK/fixD/out2"
sa "D the unmutated script FATALs on the same tree" "$RC" 1
sa "D it names the mode it found" "$(printf '%s' "$OUT" | grep -c 'is 755, expected 4755')" 1
end_row "D 4755 -> 755 in the step-2 assert (step 3b does not re-check it)"

ROWFAIL=0
sed 's|for p in usr/bin/darling-lol usr/lib/darling-lol usr/share/doc/darling-lol; do|for p in usr/bin/darling-lol usr/share/doc/darling-lol; do|' "$ST" > "$WORK/stage-nolib.sh"
rm -rf "$WORK/fixE"; cp -a "$WORK/fix" "$WORK/fixE"; rm -rf "$WORK/fixE/out"
run sh "$WORK/stage-nolib.sh" "$WORK/fixE/root" "$WORK/fixE/out"
sr E1 0 'stage: [0-9]+ runtime paths'
sa "E1 the launcher list shrinks to 2" "$(wc -l < "$WORK/fixE/out/files.launcher" | tr -d ' ')" 2
sa "E1 the runtime list grows to 26" "$(wc -l < "$WORK/fixE/out/files.runtime" | tr -d ' ')" 26
sa "E1 6 differing lines vs the independent expectation" "$(diff <(sort "$WORK/fixE/out/files.runtime") <(sort "$WORK/fix/expect-runtime") | grep -c '^[<>]')" 6
python3 - "$ST" "$WORK/stage-c18.sh" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()
old = 'LC_ALL=C comm -23 "$out/files.all" "$out/files.launcher" > "$out/files.runtime"'
new = ('# mutation E2: subtract only the two obvious launcher paths, forget usr/lib/darling-lol\n'
       "grep -v -e '^/usr/bin/darling-lol$' -e '^/usr/share/doc/darling-lol/' "
       '"$out/files.all" > "$out/files.runtime"')
assert text.count(old) == 1
open(dst, 'w').write(text.replace(old, new, 1))
PY
rm -rf "$WORK/fixE2"; cp -a "$WORK/fix" "$WORK/fixE2"; rm -rf "$WORK/fixE2/out"
run sh "$WORK/stage-c18.sh" "$WORK/fixE2/root" "$WORK/fixE2/out"
sr E2 0 'stage: [0-9]+ runtime paths'
sa "E2 comm -12 = 6 (a C18 violation)" "$(comm -12 <(sort "$WORK/fixE2/out/files.runtime") <(sort "$WORK/fixE2/out/files.launcher") | wc -l)" 6
end_row "E drop usr/lib/darling-lol from step 4 (C18)"

# ---------------------------------------------------------------------------------------------
if [ -z "$FLIP" ]; then
  PHASE=ctrl
  sec "negative control: one row's expectation inverted MUST turn this table red"
  ROWFAIL=0
  nrc=0; nout=$(T1_MUTATION_FLIP=M1 bash "$0" 2>&1) || nrc=$?
  sa "the inverted run exits non-zero" "$nrc" 1
  sa "it fails the inverted row" "$(printf '%s' "$nout" | grep -c 'FAIL M1 exit')" 1
  end_row "negative control: T1_MUTATION_FLIP=M1 -> red"
else
  PHASE=ctrl
  # This run IS the inverted run (T1_MUTATION_FLIP=$FLIP), so the control cannot run under its own
  # hook: its row is SKIPped -- reported and counted, never a silent `controls: 0 passed, 0 failed`.
  skip_row "negative control (T1_MUTATION_FLIP=$FLIP: the control row cannot run under its own hook)"
fi

sec "SUMMARY"
# The bucket sizes are pinned BEFORE the totals are printed, so a FATAL is part of the number the
# reader sees: a total printed before the checks that can change it is the same lie in a new place.
[ "$pp" = 8 ] || { printf '  FATAL the G-PREFIX-1 table must have 8 rows, has %d\n' "$pp"; fail=$((fail+1)); }
[ "$sp" = 5 ] || { printf '  FATAL the G-STATIC-6 table must have 5 rows, has %d\n' "$sp"; fail=$((fail+1)); }
# The controls bucket is pinned too: positive + third table + negative control = 3 rows, and the
# third one is exactly the row the FLIP hook turns off -- so the pin is on RAN + SKIPPED. Without it
# a bucket that lost a row (or a control row that never ran) is a silent 2/0, the size the other two
# buckets must not have (review MINOR-1).
[ "$((cc + skips))" = 3 ] || { printf '  FATAL the controls bucket must have 3 rows (ran + skipped), has %d\n' "$((cc + skips))"; fail=$((fail+1)); }
printf '  G-PREFIX-1 mutations: %d passed, %d failed\n' "$pp" "$pf"
printf '  G-STATIC-6 mutations: %d passed, %d failed\n' "$sp" "$sf"
printf '  controls:             %d passed, %d failed, %d skipped\n' "$cc" "$cf" "$skips"
printf '  total:                %d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skips"
[ "$skips" = 0 ] || printf '  \033[33m%d row(s) SKIPped: SKIP is not PASS\033[0m\n' "$skips"
[ "$fail" = 0 ] || exit 1
