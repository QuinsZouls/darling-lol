#!/usr/bin/env bash
# packaging/testdata/run-gates.sh -- the T1 gate battery: self-contained, hermetic, asserting.
#
# Run from the repo root:
#
#     bash packaging/testdata/run-gates.sh
#
# Everything it needs it creates itself, inside one private `mktemp -d` workdir, and it reads
# nothing the harness did not write (T1 review MAJOR-1: the pre-review battery compared a rendered
# Depends against a *leftover* /tmp/render-eq it neither created nor shipped, and planted its
# snippet at /tmp/re/render-eq -- a typo -- so a clean box scored 48/49). The two stale leftovers
# of that generation are REPORTED, never removed (NIT-2): they are not this harness's files to
# delete, and the warning keeps the regression visible instead of silently cleaning up after it.
# This battery does not read them either way.
#
# The dependency lists are additionally compared against the PLAN's own fenced lists when
# T1_PLAN_FILE points at PLAN.md; the PLAN is not in this repo, so the check is skipped otherwise:
#
#     T1_PLAN_FILE=/path/to/PLAN.md bash packaging/testdata/run-gates.sh
#
# SKIP accounting (review C4): `skip()` paints a row and now COUNTS it, and the summary prints it
# (`N passed, M failed, K skipped`). A skipped row used to be visible in the body but invisible in
# the total, so `72 passed, 0 failed` read as "the whole battery ran" while one row had not been
# measured at all. What "expected to run" means here, decided and documented rather than implied:
# all three skip sites are genuinely OPTIONAL inputs/tooling -- shellcheck and dpkg-deb are
# convenience row-holders, and the PLAN (the T1_PLAN_FILE row) is not in this repo by design, so
# its absence is the documented NORMAL state of a checkout and NOT a degraded environment. There is
# therefore no expectation to violate: a skip is REPORTED, never turned into a failure, and rc stays
# 0. (Contrast run-deb-gates.sh, where the docker row's input IS expected in CI and T3_GATES_REQUIRE_
# DOCKER exists to force it; nothing here has a comparable expectation.) The counter is a real
# counter, not a constant: with T1_PLAN_FILE set the same battery prints `74 passed, 0 failed, 0
# skipped`, with it unset `73 passed, 0 failed, 1 skipped`.
#
# 🚨 `skip()` here is NOT launch-harness.sh's `skip()` (review MINOR-2). That one is a PRECONDITION
# guard: it exits 77 without ever painting a row. This one PAINTS a counted SKIP row in the body and
# lets the battery run on -- the same function name for two deliberately different things, so reading
# the two files together must not collapse them into one rule. And there is no `SKIP=` FIELD in this
# battery's summary at all: the only SKIP here is a skip() ROW, and rc is unaffected by it.
#
# Companions: packaging/testdata/run-mutations.sh (the two mutation tables, self-asserting, with a
# negative control), packaging/testdata/run-build-log-gates.sh (the install-log invariants of
# scripts/build-packaging.sh, solved as 9 asserted cases) and packaging/testdata/state-probe.sh
# (the transient current-state probe).
#
# `sh run-gates.sh` (= dash here) parses this file up to the first process substitution and dies
# there -- AFTER printing ~20 PASS lines, which a careless runner reads as "mostly green" (review
# INFO-3). Refuse up front instead, in a form dash can parse, so that the message is the output.
case "${BASH_VERSION:-}" in
  "") echo "run-gates: run me with bash: bash $0" >&2; exit 2 ;;
esac
set -u

if [ ! -f packaging/common/stage.sh ] || [ ! -d packaging/testdata ]; then
  echo "run-gates: run me from the repo root (no packaging/ in $PWD)" >&2
  exit 2
fi

# T1_GATES_BREAK=<name> breaks the object under test on purpose so the negative control at the
# bottom can prove the swept rows (G-STATIC-5b's two, and the stage.sh rc row) really go red. It
# mutates the OBJECT, not an expectation: render-fail / hash-leak / stage-fail. Unset in a normal
# run, and never inherited into the control's child run (the control skips itself when it is set).
BREAK=${T1_GATES_BREAK:-}

WORK=$(mktemp -d "${TMPDIR:-/tmp}/darling-t1-gates.XXXXXX")
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

for stale in "${TMPDIR:-/tmp}/render-eq" "${TMPDIR:-/tmp}/plan-bookworm.verbatim"; do
  [ -e "$stale" ] || continue
  printf "note: %s is present. The pre-8eb6bbe harness would have READ this leftover; this one ignores it (MAJOR-1). Not deleting it (NIT-2): it is not this harness's file, and the evidence should stay visible.\n" "$stale"
done

# Scratch copies and git tags -- never do this. A `cp -a` of a WORKTREE keeps its `.git` *pointer*,
# so the copy shares the original repo's refs and object store: `git -C <copy> tag -d v0.1.0`
# deletes the tag from the SHARED repo, not from a private copy. That is exactly how a PR-1 review
# repro wiped this repo's `v0.1.0` (recovered with `git fetch --tags`; the remote always had it).
# Scratch copies MUST be made with `git clone` or `git worktree add`, and a destructive git command
# must never run inside one. To reproduce a tagless box (the F4/F11 case) clone WITHOUT tags:
#     git clone --no-tags <repo> /tmp/tagless && (cd /tmp/tagless && bash packaging/testdata/run-gates.sh)

pass=0; fail=0; skips=0
ok()   { pass=$((pass+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
no()   { fail=$((fail+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
chk()  { if [ -z "$2" ]; then no "$1: EMPTY result (command failed)"; elif [ "$2" = "$3" ]; then ok "$1 ($2)"; else no "$1: got '$2', want '$3'"; fi; }
skip() { skips=$((skips+1)); printf '  \033[33mSKIP\033[0m %s\n' "$1"; }
sec()  { printf '\n\033[1m%s\033[0m\n' "$1"; }

# the pattern this file searches for, built so that the file does not itself contain it
space=' '
c19pat="grep${space}-R"

sec "G-STATIC-1  shellcheck -S warning + bash -n / sh -n over every script"
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck -S warning packaging/common/*.sh packaging/testdata/*.sh; then ok "shellcheck: 0 findings"; else no "shellcheck findings"; fi
else
  skip "shellcheck is not installed"
fi
syn=0
for f in packaging/common/*.sh packaging/testdata/*.sh; do
  bash -n "$f" 2>/dev/null || { sh -n "$f" 2>/dev/null || { no "syntax error: $f"; syn=$((syn+1)); }; }
done
chk "bash -n / sh -n: 0 syntax errors" "$syn" 0

sec "G-STATIC-3  pkg-version.sh reproduces the PLAN 6 table"
rc=0; out=$(./packaging/common/pkg-version.sh v0.1.0 v0.2.0-rc1 v1.0.0 0.1.0 v0.1.0-3-gabc1234 2>/dev/null) || rc=$?
printf '%s\n' "$out" | sed 's/^/    /'
chk "5 valid tags -> exit 0" "$rc" 0
chk "rows printed" "$(printf '%s\n' "$out" | wc -l)" 5
chk "v0.1.0 deb row" "$(printf '%s\n' "$out" | awk -F'\t' '$1=="v0.1.0"{print $3}')" "0.1.0+lol-1"
chk "v0.1.0 rpm row" "$(printf '%s\n' "$out" | awk -F'\t' '$1=="v0.1.0"{print $4}')" "0.1.0-1.lol.fc41"
chk "v0.1.0 arch row" "$(printf '%s\n' "$out" | awk -F'\t' '$1=="v0.1.0"{print $5}')" "0.1.0-1"
chk "0.2.0-rc1 -> 0.2.0 (suffix stripped)" "$(printf '%s\n' "$out" | awk -F'\t' '$1=="v0.2.0-rc1"{print $2}')" "0.2.0"
chk "bare 0.1.0 accepted" "$(printf '%s\n' "$out" | awk -F'\t' '$1=="0.1.0"{print $2}')" "0.1.0"
chk "describe suffix 0.1.0-3-gabc1234 -> 0.1.0" "$(printf '%s\n' "$out" | awk -F'\t' '$1=="v0.1.0-3-gabc1234"{print $2}')" "0.1.0"
./packaging/common/pkg-version.sh not-a-tag >/dev/null 2>"$WORK/verr"; chk "garbage fails loudly" "$?" 1
chk "garbage names the input" "$(grep -c "not-a-tag" "$WORK/verr")" 1
chk "garbage emits NO 0.0.0" "$(grep -c '0\.0\.0' "$WORK/verr")" 0

# F11 (authorised follow-up): classify()'s first arm used to admit only a DIGIT-initial string, so a
# bare hash whose first byte is a letter (a-f -- 6 of the 16 hex digits, ~37.5% of commits) fell to
# the `*)` FATAL while the file's own comment says the discriminator is the DOT. Pin the
# letter-initial case (the regression), the digit-initial case that already worked, the 4-hex-char
# floor, and the non-hex 4+ char case that must STAY fatal.
pkgv() { ./packaging/common/pkg-version.sh "$1" 2>/dev/null; }
chk "F11: a digit-initial bare hash -> the dev form" "$(pkgv 2d75d58 | cut -d. -f1-2)" "0.0"
chk "F11: a letter-initial bare hash -> the dev form" "$(pkgv deadbeef | cut -d. -f1-2)" "0.0"
chk "F11: another letter-initial hash (a1ae47e) -> the dev form" "$(pkgv a1ae47e | cut -d. -f1-2)" "0.0"
chk "F11: 4 hex characters are enough (abcd)" "$(pkgv abcd | cut -d. -f1-2)" "0.0"
chk "F11: the dev release is date-stamped (0.devYYYYMMDD)" \
  "$(./packaging/common/pkg-version.sh --deb deadbeef | grep -c '^0\.0\.0+lol-0\.dev[0-9][0-9]*$')" 1
./packaging/common/pkg-version.sh abcg >/dev/null 2>&1; chk "F11: a non-hex 4+ char string STAYS fatal" "$?" 1
# F11 control: the pin above must track the object, not the harness. Revert the arm in a copy and
# the same letter-initial input goes back to FATAL -- so a re-weakening really does turn it red.
sed 's/\[0-9a-f\]\*) : ;;/[0-9]*) : ;;/' packaging/common/pkg-version.sh > "$WORK/pkgv-f11.sh"
chk "F11 control: the reverted copy differs (mutation is real)" \
  "$(cmp -s packaging/common/pkg-version.sh "$WORK/pkgv-f11.sh" && echo same || echo differs)" "differs"
mrc=0; sh "$WORK/pkgv-f11.sh" deadbeef >/dev/null 2>&1 || mrc=$?
chk "F11 control: with the old arm a letter-initial hash FATALs again" "$mrc" 1

sec "G-STATIC-4/5  render.sh: one list -> three syntaxes, no drift, no tokens"
# --tag v0.1.0 on every render here, never the ambient `git describe` (MINOR-4, both ways round):
# in a tagless checkout (`git archive`, a `fetch-depth: 1` actions/checkout) the ambient "tag" is the
# commit hash, and render.sh then derives a date-stamped dev version -- which made the dpkg-deb row
# below fail on a CORRECT tree (53/1, with a confounding message) and made this whole section a
# function of WHICH commit is checked out: pkg-version.sh's hash path accepts a bare hash only when
# its first character is a digit, so on any commit whose short hash starts a..f every render here
# FATALled (11 red rows; F11 in the report). Explicit tags make the section version-independent and
# deterministic -- the version itself is asserted on purpose just below and in G-STATIC-3.
for fam in deb rpm arch; do
  ./packaging/common/render.sh --family "$fam" --tag v0.1.0 --fixture > "$WORK/$fam.out" || no "render $fam"
done
if ! grep -qE '@[A-Za-z_]+@' "$WORK/deb.out" "$WORK/rpm.out" "$WORK/arch.out" && \
   ! grep -qF '${binary:Version}' "$WORK/deb.out" "$WORK/rpm.out" "$WORK/arch.out"; then ok "no @TOKEN@ / \${binary:Version} left"; else no "token left"; fi
chk "deb: exactly one Depends line" "$(grep -c '^Depends: ' "$WORK/deb.out")" 1
chk "deb: Depends == deps.deb.noble" \
  "$(diff <(sed -n 's/^Depends: //p' "$WORK/deb.out" | tr ',' '\n' | sed 's/^ *//;s/ *$//' | sort -u) <(grep -v '^#' packaging/common/deps.deb.noble | sed 's/[[:space:]]*$//' | grep -v '^$' | sort -u) | wc -l)" 0
chk "deb: Conflicts == conflicts.txt" \
  "$(diff <(sed -n 's/^Conflicts: //p' "$WORK/deb.out" | tr ',' '\n' | sed 's/^ *//;s/ *$//' | sort -u) <(grep -v '^#' packaging/common/conflicts.txt | sed 's/[[:space:]]*$//' | grep -v '^$' | sort -u) | wc -l)" 0
chk "rpm: one Requires per entry" "$(grep -c '^Requires: ' "$WORK/rpm.out")" 27
chk "rpm: Requires == deps.rpm.fc41" \
  "$(diff <(sed -n 's/^Requires: //p' "$WORK/rpm.out" | sort -u) <(grep -v '^#' packaging/common/deps.rpm.fc41 | sed 's/[[:space:]]*$//' | grep -v '^$' | sort -u) | wc -l)" 0
chk "rpm: Version: has no dash" "$(grep -c '^Version: .*-.*$' "$WORK/rpm.out")" 0
chk "arch: one depend per entry" "$(grep -c '^depend = ' "$WORK/arch.out")" 25
chk "arch: depend == deps.arch" \
  "$(diff <(sed -n 's/^depend = //p' "$WORK/arch.out" | sort -u) <(grep -v '^#' packaging/common/deps.arch | sed 's/[[:space:]]*$//' | grep -v '^$' | sort -u) | wc -l)" 0
chk "arch: pkgver contains a dash (libalpm)" "$(grep -c '^pkgver = [^-]*-' "$WORK/arch.out")" 1
if command -v dpkg-deb >/dev/null 2>&1; then
  # deb.out is the --tag v0.1.0 render above, so this row is hermetic AND end to end: the version
  # dpkg-deb reads back comes from the tag, through render.sh, through pkg-version.sh.
  mkdir -p "$WORK/ctl/DEBIAN"; cp "$WORK/deb.out" "$WORK/ctl/DEBIAN/control"
  if dpkg-deb -b "$WORK/ctl" "$WORK/t1.deb" 2>/dev/null; then
    chk "dpkg-deb accepts the rendered control file" "$(dpkg-deb -f "$WORK/t1.deb" Version)" "0.1.0+lol-1"
  else no "dpkg-deb rejected the rendered control file"; fi
else
  skip "dpkg-deb is not installed"
fi
chk "the version really comes from the tag (--tag v9.9.9)" \
  "$(./packaging/common/render.sh --family deb --tag v9.9.9 --fixture | sed -n 's/^Version: //p')" "9.9.9+lol-1"

sec "G-STATIC-5b  render.sh accepts the PLAN's inline-comment style (hermetic -- MAJOR-1)"
# Build the snippet INSIDE the gate: copy the worktree's own packaging/common into the private
# workdir, give its bookworm list the inline-comment style PLAN 8.1 prints it with, and render
# *that*. Both sides of the comparison are produced by this run; nothing is read from /tmp.
#
# F4 sweep -- "a gate that passes by not testing" (plan C25). These two rows used to grep a render
# PIPELINE inline: a render that FATALled left both `sed`s empty, so `diff | wc -l` (=0) and
# `grep -c '#'` on empty output (=0) BOTH matched the expectation, and a dead section reported
# green. Each render now writes its control to a FILE first and its exit status is asserted; only
# then are the two files compared, so a failed render turns its rc row red instead of hiding behind
# an empty-vs-empty diff. The negative control proves it with T1_GATES_BREAK=render-fail/hash-leak.
mkdir -p "$WORK/eq"
cp packaging/common/*.sh packaging/common/*.txt packaging/common/deps.* "$WORK/eq/"
sed 's/^\([^#].*[^[:space:]]\)[[:space:]]*$/\1    # inline note (PLAN 8.1 style)/' \
  packaging/common/deps.deb.bookworm > "$WORK/eq/deps.deb.bookworm"
if cmp -s "$WORK/eq/deps.deb.bookworm" packaging/common/deps.deb.bookworm; then no "the inline-comment variant is identical to the delivered file (mutation is vacuous)"; else ok "the inline-comment variant differs from the delivered file"; fi

# render the inline-comment copy to a file; the rc is the row that was missing. hash-leak (a
# control) injects a '#' into its Depends, render-fail makes the render FATAL before printing.
eqrc=0
case "$BREAK" in
  render-fail) false > "$WORK/eq.inline.ctl" || eqrc=$? ;;
  hash-leak)   sh "$WORK/eq/render.sh" --family deb --tag v0.1.0 --release bookworm --fixture 2>/dev/null \
                 | sed 's/^Depends: /Depends: # leaked /' > "$WORK/eq.inline.ctl" || eqrc=$? ;;
  *)           sh "$WORK/eq/render.sh" --family deb --tag v0.1.0 --release bookworm --fixture \
                 > "$WORK/eq.inline.ctl" 2>"$WORK/eq.inline.err" || eqrc=$? ;;
esac
chk "the inline-comment render exits 0" "$eqrc" 0
# the delivered render -> its own file too, so the same class cannot reappear on the baseline side.
drc=0; ./packaging/common/render.sh --family deb --tag v0.1.0 --release bookworm --fixture \
  > "$WORK/eq.delivered.ctl" 2>"$WORK/eq.delivered.err" || drc=$?
chk "the delivered render (comparison baseline) exits 0" "$drc" 0
chk "the inline-comment render has a Depends line" "$(grep -c '^Depends: ' "$WORK/eq.inline.ctl")" 1
chk "the delivered render has a Depends line" "$(grep -c '^Depends: ' "$WORK/eq.delivered.ctl")" 1
chk "inline comments are a legal input: same Depends, 0 diff lines" \
  "$(diff <(sed -n 's/^Depends: //p' "$WORK/eq.inline.ctl") <(sed -n 's/^Depends: //p' "$WORK/eq.delivered.ctl") | wc -l)" 0
chk "no '#' leaks into the rendered Depends" \
  "$(sed -n 's/^Depends: //p' "$WORK/eq.inline.ctl" | grep -c '#' || true)" 0

sec "G-STATIC-6  stage.sh over the hostile-shape fixture"
rm -rf "$WORK/fix" && bash packaging/testdata/mkfixture.sh "$WORK/fix" >/dev/null
# stage.sh's exit status, asserted (belt and braces): the guard loop below already red-flags a
# missing artifact, but the two diff rows further down ("runtime + launcher == all", the C18
# comm) compare two *products* and would read 0 on an empty-vs-empty stage failure. With the rc row
# they cannot pass by not testing; T1_GATES_BREAK=stage-fail is its control.
st_rc=0
if [ "$BREAK" = stage-fail ]; then st_rc=1; else sh packaging/common/stage.sh "$WORK/fix/root" "$WORK/fix/out" >"$WORK/stage.log" || st_rc=$?; fi
chk "stage.sh over the hostile-shape fixture exits 0" "$st_rc" 0
missing=0
for a in files.all files.quoted files.emptydirs files.launcher files.runtime count.runtime count.launcher installed-size-kib; do
  [ -s "$WORK/fix/out/$a" ] || { no "artifact missing/empty: $a"; missing=1; }
done
# conditional: this used to be an unconditional `ok`, i.e. a green row that could never go red.
[ "$missing" = 0 ] && ok "all 8 artifacts present and non-empty"
chk "files.runtime == expect-runtime (independent computation)" \
  "$(diff <(sort "$WORK/fix/out/files.runtime") <(sort "$WORK/fix/expect-runtime") | wc -l)" 0
chk "runtime + launcher == all" \
  "$(diff <(cat "$WORK/fix/out/files.runtime" "$WORK/fix/out/files.launcher" | sort) <(sort "$WORK/fix/out/files.all") | wc -l)" 0
chk "C18: files.runtime ∩ files.launcher = empty" \
  "$(comm -12 <(sort "$WORK/fix/out/files.runtime") <(sort "$WORK/fix/out/files.launcher") | wc -l)" 0
chk "files.launcher owns usr/lib/darling-lol (C18)" "$(grep -c '^/usr/lib/darling-lol/' "$WORK/fix/out/files.launcher")" 6
chk "count.runtime matches the file" "$(cat "$WORK/fix/out/count.runtime")" "$(wc -l < "$WORK/fix/out/files.runtime" | tr -d ' ')"
chk "count.launcher matches the file" "$(cat "$WORK/fix/out/count.launcher")" "$(wc -l < "$WORK/fix/out/files.launcher" | tr -d ' ')"
chk "no relative paths in files.all" "$(grep -cv '^/' "$WORK/fix/out/files.all")" 0
chk "the 4 %-escapes survive verbatim" "$(grep -cE '%(21\.menu|7c-i\.ri|3f-i\.ri|3d%3d%3d-i\.ri)' "$WORK/fix/out/files.quoted")" 4
chk "the space path survives quoted" "$(grep -cF '"/usr/libexec/darling/System/Library/User Template"' "$WORK/fix/out/files.quoted")" 1
n=0; while IFS= read -r p; do [ -n "$p" ] && grep -qxF "$p" "$WORK/fix/out/files.all" && n=$((n+1)); done < <(printf '%s\n' /usr/bin/darling '/usr/libexec/darling/usr/bin/write' '/usr/libexec/darling/System/Library/User Template' '/usr/libexec/darling/System/Library/CoreServices/Menu Extras/%21.menu' '/usr/libexec/darling/usr/share/ipv6only%7c-i.ri' '/usr/libexec/darling/usr/share/eql%3f-i.ri' '/usr/libexec/darling/usr/share/%3d%3d%3d-i.ri' '/usr/libexec/darling/private/etc/machine-id' '/usr/libexec/darling/private/tmp')
chk "all 9 hostile shapes listed" "$n" 9
chk "stage.sh exits non-zero on usr/local (step 1)" \
  "$(rm -rf "$WORK/neg" && cp -a "$WORK/fix" "$WORK/neg" && mkdir -p "$WORK/neg/root/usr/local/x"; sh packaging/common/stage.sh "$WORK/neg/root" "$WORK/neg/out2" >/dev/null 2>&1; echo $?)" 1
chk "stage.sh exits non-zero when darling is not 4755 (step 2)" \
  "$(rm -rf "$WORK/neg2" && cp -a "$WORK/fix" "$WORK/neg2" && chmod 755 "$WORK/neg2/root/usr/bin/darling"; sh packaging/common/stage.sh "$WORK/neg2/root" "$WORK/neg2/out2" >/dev/null 2>&1; echo $?)" 1
chk "files.quoted is NOT what files.all is (quotes are real)" "$(grep -c '^"' "$WORK/fix/out/files.quoted")" "$(wc -l < "$WORK/fix/out/files.quoted" | tr -d ' ')"

sec "determinism  stage.sh twice -> byte-identical lists (MINOR-2: measured by hand, now gated)"
sh packaging/common/stage.sh "$WORK/fix/root" "$WORK/det2/out" >/dev/null
chk "same fixture, 2 runs: the 8 artifacts are byte-identical" "$(diff -r "$WORK/fix/out" "$WORK/det2/out" | wc -l)" 0
chk "same fixture, 2 runs: sha256 of files.* + count.* identical" \
  "$( (cd "$WORK/fix/out" && sha256sum files.all files.quoted files.emptydirs files.launcher files.runtime count.runtime count.launcher) | diff - <(cd "$WORK/det2/out" && sha256sum files.all files.quoted files.emptydirs files.launcher files.runtime count.runtime count.launcher) | wc -l)" 0
rm -rf "$WORK/det3" && bash packaging/testdata/mkfixture.sh "$WORK/det3" >/dev/null
sh packaging/common/stage.sh "$WORK/det3/root" "$WORK/det3/out" >/dev/null
chk "two independently built fixtures: the 8 artifacts are byte-identical" "$(diff -r "$WORK/fix/out" "$WORK/det3/out" | wc -l)" 0

# --- build-launcher.sh: the staged payload ships no Python build byproducts (review MAJOR) -----
# The launcher payload's tools/ half is a VERBATIM cp -a of the checkout's tools/, so a gitignored
# test-run byproduct (tools/**/__pycache__/*.pyc) used to be staged, listed by stage.sh and shipped
# -- while BOTH content sweeps skip binaries by design (check-prefix.sh greps with -InH,
# launch-harness.sh with -Il), so a stale cache compiled from pre-fix source could carry the
# forbidden /usr/local/libexec/darling literal past G-PREFIX-1 printing PREFIX: OK. No pre-existing
# row here runs build-launcher.sh, and extending G-STATIC-6's fixture was NOT the home for this:
# a __pycache__ under its launcher half moves the pinned `files.launcher owns usr/lib/darling-lol
# == 6` row. So this row builds its own scratch checkout instead: build-launcher resolves every
# source relative to its own location ($0/../..), and a copy of the tree under test is where the
# byproduct gets planted -- never the real tools/.
sec "G-LAUNCH-2  build-launcher.sh: the staged payload ships no Python build byproducts"
blfix=$WORK/bl
mkdir -p "$blfix/packaging/common" "$blfix/packaging/install" "$blfix/scripts"
cp packaging/common/build-launcher.sh "$blfix/packaging/common/"
cp packaging/install/darling-lol.in packaging/install/README-packaging.md.in "$blfix/packaging/install/"
cp scripts/configure.py scripts/common.py "$blfix/scripts/"
cp -a tools "$blfix/tools"
# The planted stale cache: byproduct content (NUL-leading, like real bytecode, so a text sweep
# skips it) carrying the old literal. The row is green only if the fixture really held it, the
# build succeeded, and NOTHING of it reached the staged tree.
mkdir -p "$blfix/tools/__pycache__"
printf '\000# stale cache of the pre-fix source\nfallback = "/usr/local/libexec/darling"\n' \
  > "$blfix/tools/__pycache__/stale.cpython-311.pyc"
have=0
if [ -f "$blfix/tools/__pycache__/stale.cpython-311.pyc" ] \
   && grep -qF '/usr/local/libexec/darling' "$blfix/tools/__pycache__/stale.cpython-311.pyc"; then have=1; fi
blrc=0; sh "$blfix/packaging/common/build-launcher.sh" "$WORK/blroot" >"$WORK/bl.log" 2>&1 || blrc=$?
[ "$blrc" = 0 ] || sed 's/^/    /' "$WORK/bl.log"
blleft=$(find "$WORK/blroot/usr/lib/darling-lol" \
           \( -type d -name __pycache__ \) -o \
           \( -type f \( -name '*.pyc' -o -name '*.pyo' \) \) 2>/dev/null | wc -l | tr -d ' ')
chk "the planted stale cache is held (1), staging exits 0 (0), zero __pycache__/pyc/pyo staged (0)" \
  "$have $blrc $blleft" "1 0 0"

sec "G-PREFIX-1  check-prefix.sh: the positive run"
rm -rf "$WORK/pfx" && bash packaging/testdata/mkprefixfixture.sh "$WORK/pfx" >/dev/null
sh packaging/common/check-prefix.sh "$WORK/pfx/root" "$WORK/pfx/files.all" >"$WORK/pfx.log" 2>&1; chk "positive exit" "$?" 0
chk "'PREFIX: OK' printed" "$(grep -c '^PREFIX: OK$' "$WORK/pfx.log")" 1
chk "guest count reported" "$(grep -c 'guest-side files containing' "$WORK/pfx.log")" 1

sec "info  current-state probe: the fixture pre-applies T8's fix, the real file does not"
prc=0; sh packaging/testdata/state-probe.sh >"$WORK/probe.log" 2>&1 || prc=$?
sed 's/^/    /' "$WORK/probe.log"
if [ "$prc" = 0 ] && grep -qE 'documented state OK|T8-LANDED' "$WORK/probe.log"; then
  ok "probe reports a documented state (rc=$prc)"
else
  no "probe is in an undocumented state (rc=$prc)"
fi

sec "G-PKG-2  scripts/build-packaging.sh: the three install-log invariants (MINOR-1/2/3, pinned)"
# The rig that asserted these once lived only in the T2 coder's artifacts; run-gates.sh now runs it
# here, so a later edit that re-weakens an invariant turns this battery red (review F10). The child
# extracts check_install_log() from the delivered script by text and asserts 9 cases + a control.
lrc=0; lout=$(sh packaging/testdata/run-build-log-gates.sh 2>&1) || lrc=$?
printf '%s\n' "$lout" | sed 's/^/    /'
chk "the log-invariant harness exits 0" "$lrc" 0
chk "its whole table ran (9 cases + 4 control rows)" \
  "$(printf '%s\n' "$lout" | sed -n 's/^  total:   \([0-9][0-9]*\) passed, [0-9][0-9]* failed$/\1/p')" 13
chk "and no row of it failed" \
  "$(printf '%s\n' "$lout" | sed -n 's/^  total:   [0-9][0-9]* passed, \([0-9][0-9]*\) failed$/\1/p')" 0

sec "acceptance: C19 / step ordering / no hard-coded version"
chk "check-prefix.sh is called from step 3b (after files.all)" \
  "$(awk '/files.all$/ {a=NR} /check-prefix.sh/ {b=NR} END {print (b>a) ? "later" : "earlier"}' packaging/common/stage.sh)" later
chk "no recursive grep in any packaging script (C19)" "$(grep -hF "$c19pat" packaging/common/*.sh packaging/testdata/*.sh | grep -vc '^#' || true)" 0
# scoped to packaging/common/ on purpose: that is the TASKS T1 criterion ("No file in
# packaging/common/ contains a hard-coded version string"). The fixtures and this harness must
# name concrete versions -- that is what they assert against.
chk "no hard-coded package version in packaging/common (comments excluded)" \
  "$(grep -vE '^[[:space:]]*#' packaging/common/*.sh | grep -cE '[^0-9]0\.9\.9|0\.1\.0\+lol|v0\.1\.0')" 0
chk "every file ends with a newline" "$(for f in packaging/common/* packaging/testdata/*; do [ -n "$(tail -c1 "$f")" ] && echo x; done | wc -l)" 0

if [ -n "${T1_PLAN_FILE:-}" ] && [ -r "${T1_PLAN_FILE:-}" ]; then
  sec "G-STATIC-5c  deps.* + conflicts.txt == the PLAN's source-of-truth fences"
  cat > "$WORK/checkdeps.py" <<'PY'
#!/usr/bin/env python3
"""Compare packaging/common/deps.* and conflicts.txt against the PLAN.md fenced lists."""
import re, sys, pathlib

plan = pathlib.Path(sys.argv[1])
text = plan.read_text()
blocks = {}
inside, buf = False, []
for l in text.split("\n"):
    if l.strip().startswith("```"):
        if inside:
            inside = False
            if buf and buf[0].startswith("# packaging/common/"):
                blocks[buf[0].strip()] = buf[1:]
            buf = []
        else:
            inside, buf = True, []
        continue
    if inside:
        buf.append(l)

def clean(xs):
    out = []
    for l in xs:
        l = re.sub(r"\s*#.*$", "", l)
        l = re.sub(r"\s+$", "", l)
        if l:
            out.append(l)
    return out

rc = 0
for name in ("deps.deb.noble", "deps.deb.bookworm", "deps.rpm.fc41", "deps.arch"):
    key = "# packaging/common/" + name
    assert key in blocks, "fence not found in the PLAN: " + key
    want = clean(blocks[key])
    have = clean(pathlib.Path("packaging/common/" + name).read_text().split("\n"))
    print("%-20s PLAN=%3d ours=%3d  %s" % (name, len(want), len(have),
          "IDENTICAL (order+content)" if want == have else "DIFFERS"))
    if want != have:
        rc = 1

i = text.index("Conflicts: darling, darling-core")
seg = text[i:text.index("Breaks:", i)]
names = [n.strip() for n in seg.replace("Conflicts:", " ").replace("\n", " ").split(",") if n.strip()]
have = clean(pathlib.Path("packaging/common/conflicts.txt").read_text().split("\n"))
print("%-20s PLAN=%3d ours=%3d  %s" % ("conflicts.txt", len(names), len(have),
      "IDENTICAL" if names == have else "DIFFERS"))
if names != have:
    rc = 1

for p in pathlib.Path("packaging/common").glob("deps.*"):
    bad = [l for l in clean(p.read_text().split("\n")) if "pcre" in l.lower()]
    assert not bad, (p, bad)
print("libpcre absent from every deps.* entry (only in comments): OK")
sys.exit(rc)
PY
  python3 "$WORK/checkdeps.py" "$T1_PLAN_FILE" >"$WORK/deps.log" 2>&1 || true
  grep 'IDENTICAL' "$WORK/deps.log" | sed 's/^/    /'
  chk "deps.* + conflicts.txt == the PLAN source lists" "$(grep -c 'IDENTICAL' "$WORK/deps.log")" 5
else
  skip "no T1_PLAN_FILE: the PLAN-pin check (the PLAN is not in this repo)"
fi

# --- negative control (F4 sweep) ---------------------------------------------------------------
# Each swept row must be able to go RED. The control breaks the OBJECT under test (T1_GATES_BREAK)
# and re-runs this file, asserting the run exits non-zero AND names the row that was swept. The
# child sees BREAK set, so it skips this section -- no recursion.
if [ -z "$BREAK" ]; then
  sec "negative control: the swept rows MUST go red when their object breaks"
  esc=$(printf '\033')
  ctl() { # ctl BREAK LABEL: the child must exit non-zero and FAIL exactly that row
    crc=0; cout=$(T1_GATES_BREAK="$1" bash "$0" 2>&1) || crc=$?
    cn=$(printf '%s\n' "$cout" | sed "s/${esc}\[[0-9;]*m//g" | grep -cF "FAIL $2")
    if [ "$crc" != 0 ] && [ "$cn" = 1 ]; then ok "T1_GATES_BREAK=$1 -> red on '$2' (rc $crc)"
    else no "T1_GATES_BREAK=$1: expected exactly 1 'FAIL $2', rc $crc, got $cn"; fi
  }
  ctl render-fail "the inline-comment render exits 0"
  ctl hash-leak   "no '#' leaks into the rendered Depends"
  ctl stage-fail  "stage.sh over the hostile-shape fixture exits 0"
fi

sec "SUMMARY"
printf '  %d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skips"
[ "$skips" = 0 ] || printf '  \033[33m%d row(s) SKIPped: SKIP is not PASS\033[0m\n' "$skips"
[ "$fail" = 0 ] || exit 1
