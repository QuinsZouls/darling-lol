#!/bin/sh
# packaging/common/build-launcher.sh (T8, R-1) -- stage the launcher package's payload.
#
# stage.sh owns the launcher half of the *list* (its step 4) and stays byte-identical to the
# PLAN's stage.sh fence; the *copy* is this script's job. Run it AFTER
# scripts/build-packaging.sh (whose pre-flight refuses a non-empty staging tree) and BEFORE
# stage.sh (whose step 3b sweeps the payload and whose step 4 lists it).
#
# Why a script and not a block inside stage.sh: stage.sh has five callers and only one is
# production. The fixture batteries (run-gates.sh / run-mutations.sh, via mkfixture.sh) and
# the three builders in fixture mode build their roots with a *stub* launcher tree of 8 paths
# and assert exact counts over it; copying 200+ files inside stage.sh would turn those rows
# red, and guarding the copy ("only if the tree is absent") is a branch that silently skips
# the one thing it exists to do. The losing cost is two invariants plus a 74/0 battery.
#
# The manifest (what it writes):
#   usr/bin/darling-lol                           <- packaging/install/darling-lol.in, with the
#                                                    two package-time tokens rendered by sed
#   usr/lib/darling-lol/scripts/configure.py      <- scripts/configure.py
#   usr/lib/darling-lol/scripts/common.py         <- scripts/common.py
#   usr/lib/darling-lol/tools/**                  <- tools/ VERBATIM, modes preserved (cp -a)
#   usr/share/doc/darling-lol/README-packaging.md <- packaging/install/README-packaging.md.in
#
# 🚨 scripts/ is NOT copied verbatim: it holds 13 files and 3 of them contain `usr/local`
# (build.sh, build-packaging.sh, common.py). Only the two named above ship; copying the others
# trips the /usr/local content sweep in check-prefix.sh (G-PREFIX-1).
# 🚨 Nothing under usr/lib/darling-lol may contain /home/runner: the templates ship
# UNRENDERED (the shipped v0.1.0 tarball carries the CI user's home baked in, which is the bug
# this package fixes) -- the wrapper renders them per user on first run.
# 🚨 render.sh cannot render this template: its token table has no SDK/TEMPLATES, it refuses a
# family-less input, and it FATALs on any leftover @TOKEN@ -- while the wrapper's own comments
# legitimately name five more tokens. The two seds below are the render, and the residual-token
# guard is scoped to non-comment lines for exactly that reason.
#
# usage: build-launcher.sh [ROOT]
#   ROOT defaults to ${DARLING_PKG_DIST:-dist}/pkg/root, like stage.sh's own default.
#   DARLING_LAUNCHER_SDK / DARLING_LAUNCHER_TEMPLATES override the two rendered values
#   (defaults: /usr/libexec/darling and /usr/lib/darling-lol).
#
# Needs no root, no cmake and no x86-64: it reads the checkout and writes ROOT.
set -eu

prog=${0##*/}
die() { echo "$prog: FATAL $*" >&2; exit 1; }

case "${1:-}" in
  -h|--help) sed -n '2,41p' "$0"; exit 0 ;;
  -*)        die "unknown option '$1' (try --help)" ;;
esac
[ $# -le 1 ] || die "too many arguments (usage: $prog [ROOT]; see --help)"

root=${1:-${DARLING_PKG_DIST:-dist}/pkg/root}
[ -n "$root" ] || die "empty ROOT"
repo=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)

sdk=${DARLING_LAUNCHER_SDK:-/usr/libexec/darling}
templates=${DARLING_LAUNCHER_TEMPLATES:-/usr/lib/darling-lol}

# 1. The sources. Fail closed here, not halfway through the copy: a missing template is a
#    broken checkout, and learning that after writing half the tree is the expensive version.
template=$repo/packaging/install/darling-lol.in
readme=$repo/packaging/install/README-packaging.md.in
for f in "$template" "$readme" "$repo/scripts/configure.py" "$repo/scripts/common.py"; do
  [ -f "$f" ] || die "missing source: $f"
done
[ -d "$repo/tools" ] || die "missing source: $repo/tools/"

# 2. Render the two package-time tokens. This is the ONLY substitution: the wrapper's comments
#    name five more @TOKENS@ on purpose (they are per-user and rendered by configure.py).
tmp=$(mktemp "${TMPDIR:-/tmp}/darling-lol-wrapper.XXXXXX")
trap 'rm -f "$tmp"' EXIT HUP INT TERM
sed -e "s|@SDK@|$sdk|g" -e "s|@TEMPLATES@|$templates|g" "$template" > "$tmp"
# Scoped to CODE lines: the fence's comments legitimately still carry @TOKEN@ names, so the
# naive form would fire on a correct render. A token left on a code line is the failure.
if grep -vE '^[[:space:]]*#' "$tmp" | grep -qE '@[A-Za-z_]+@'; then
  echo "$prog: FATAL unexpanded token in the rendered wrapper (sdk=$sdk templates=$templates):" >&2
  grep -vE '^[[:space:]]*#' "$tmp" | grep -nE '@[A-Za-z_]+@' | head -5 >&2
  exit 1
fi

# 3. The payload. The tools/ tree is idempotent by construction: the target directory is
#    recreated, so a re-run (a re-dispatched job) cannot leave a stale file behind.
#
# Every write into the staging tree below carries `|| stage_fail` -- the REAL writes are the
# guard, there is no probe. The raw command's errno line is deliberately NOT suppressed (round-2
# N1: silenced, it let the FATAL assert an ownership cause for ENOTDIR/EACCES/EROFS failures);
# only the FATAL line below is actionable, and it states a hypothesis, not a known cause (N1b).
# On CI usr/** is root-owned after scripts/build-packaging.sh's sudo install (it sets the setuid
# bit on usr/bin/darling), so an unprivileged run dies there with that one line (run 39136194994).
stage_fail() {
  die "cannot stage the launcher payload into $root as uid $(id -u); if usr/** is root-owned (scripts/build-packaging.sh's sudo install, for the setuid bit on usr/bin/darling) run this step with the privileges that created the tree (CI: under sudo)"
}
mkdir -p "$root/usr/bin" "$root/usr/share/doc/darling-lol" || stage_fail
rm -rf "$root/usr/lib/darling-lol" || stage_fail
mkdir -p "$root/usr/lib/darling-lol/scripts" "$root/usr/lib/darling-lol/tools" || stage_fail
install -m 0755 "$tmp" "$root/usr/bin/darling-lol" || stage_fail
install -m 0755 "$repo/scripts/configure.py" "$repo/scripts/common.py" \
  "$root/usr/lib/darling-lol/scripts/" || stage_fail
cp -a "$repo/tools/." "$root/usr/lib/darling-lol/tools/" || stage_fail
# Python build byproducts never ship: tools/**/__pycache__/*.pyc are gitignored output of the
# repo's own test command, and BOTH content sweeps skip binaries by design (check-prefix.sh greps
# with -InH, launch-harness.sh with -Il), so a stale cache compiled from pre-fix source could
# carry /usr/local/libexec/darling past G-PREFIX-1 while it prints PREFIX: OK. Strip them from
# the STAGED tree right after the copy (the checkout's own tools/ stays untouched); section 4
# below fails closed on the result, so a byproduct from any other source dies loudly too.
find "$root/usr/lib/darling-lol/tools" -type d -name __pycache__ -prune -exec rm -rf {} + || stage_fail
find "$root/usr/lib/darling-lol/tools" -type f \( -name '*.pyc' -o -name '*.pyo' \) -exec rm -f {} + || stage_fail
install -m 0644 "$readme" "$root/usr/share/doc/darling-lol/README-packaging.md" || stage_fail

# 4. Fail closed on the result. stage.sh step 4's guard is `[ -e "$root/$p" ] && ...`, which
#    makes an absent payload SILENT: files.launcher ends up 0 bytes and stage.sh exits 0, and
#    the failure only surfaces one step later in build-all.sh. These assertions are the fix.
for p in usr/bin/darling-lol usr/lib/darling-lol/scripts/configure.py \
         usr/lib/darling-lol/scripts/common.py usr/lib/darling-lol/tools \
         usr/share/doc/darling-lol/README-packaging.md; do
  [ -e "$root/$p" ] || die "payload missing after staging: $root/$p"
done
[ -x "$root/usr/bin/darling-lol" ] || die "$root/usr/bin/darling-lol is not executable"
# The staged payload must carry NO Python build byproducts, asserted fail-closed on the whole
# usr/lib/darling-lol tree (not just the tools/ copy above): __pycache__/*.pyc/*.pyo are
# gitignored build output, not payload, and the content sweeps CANNOT see them -- both skip
# binaries by design (check-prefix.sh greps with -InH, launch-harness.sh with -Il) -- so a stale
# cache compiled from pre-fix source could ship the forbidden /usr/local/libexec/darling literal
# while G-PREFIX-1 prints PREFIX: OK. Offenders are listed first, same style as the /home/runner
# check below.
byp=$(find "$root/usr/lib/darling-lol" \
        \( -type d -name __pycache__ \) -o \
        \( -type f \( -name '*.pyc' -o -name '*.pyo' \) \) \
        | LC_ALL=C sort)
if [ -n "$byp" ]; then
  printf '%s\n' "$byp" | head -5 >&2
  die "the staged payload carries Python build byproducts (listed above): __pycache__/*.pyc/*.pyo are build output that the content sweeps cannot see because they skip binaries (check-prefix.sh -InH, launch-harness.sh -Il), so a stale cache could ship a forbidden literal past G-PREFIX-1"
fi

# 5. Two properties of the shipped payload, asserted count-agnostically. Never assert a file
#    count here: tools/ holds 212 top-level files plus 14 in subdirectories on this commit (226 in
#    all; the pre-merge tree had 205 + 14) and has drifted before (the plan-era pin said 190).
n_tok=$(grep -rl '@GUEST_HOME@' "$root/usr/lib/darling-lol/tools" 2>/dev/null | wc -l | tr -d ' ')
[ "$n_tok" -gt 0 ] || die "no @GUEST_HOME@ under $root/usr/lib/darling-lol/tools: the templates must ship UNRENDERED"
if grep -rl '/home/runner' "$root/usr/bin/darling-lol" "$root/usr/lib/darling-lol" 2>/dev/null | grep -q .; then
  grep -rl '/home/runner' "$root/usr/bin/darling-lol" "$root/usr/lib/darling-lol" 2>/dev/null | head -5 >&2
  die "the payload carries the build host's home (/home/runner): the templates must be unrendered"
fi

echo "$prog: payload staged (sdk=$sdk templates=$templates, $n_tok unrendered template file(s) under tools/)"
