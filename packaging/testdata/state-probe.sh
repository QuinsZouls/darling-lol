#!/bin/sh
# packaging/testdata/state-probe.sh -- REGRESSION GUARD for C22 (T1 review, INFO).
#
# It is no longer a "current-state probe": the literal default it used to document HAS been removed
# from tools/install-riot-darling-server.py, and this guard's job is to keep it from coming back --
# it covers the window until T8 stages the launcher tree, after which G-PREFIX-1 sweeps the real
# tree and T8 may delete this file.
#
# Why it still exists (unchanged): the positive G-PREFIX-1 fixture (mkprefixfixture.sh `prefix_host`)
# deliberately writes the **T8-FIXED** installer: no literal prefix, resolved with shutil.which().
# That is the state the packaging wants, so the fixture is right to do it -- but it means the
# positive run proves the gate against a state whose installer is a stand-in. The real tracked file
# used to carry the literal default:
#
#     tools/install-riot-darling-server.py:89
#         parser.add_argument("--destination", type=Path, default=Path("/usr/local/bin/darlingserver"))
#
# and that path is not on check-prefix.sh's 4-file allowlist, so sweeping a tree that contains the
# real file with the literal FATALs (this is exactly mutation M7). Keeping the discrepancy hidden
# behind the fixture would hide a live bug, so this guard runs the delivered gate over a tree in
# which the ONLY difference from the desirable state is that the installer is the REAL tracked file,
# and FAILS the moment that file stops being prefix-neutral.
#
# Contract: exit 0 only when the real installer is literal-free AND the sweep over it passes
# (the required state); exit 1 when the literal is back (a C22 regression) or when anything else
# moved, so it stays safe to wire into run-gates.sh.
#
# usage: sh packaging/testdata/state-probe.sh      (from the repo root)
set -eu

here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo=$(CDPATH='' cd -- "$here/../.." && pwd)
real=$repo/tools/install-riot-darling-server.py
rel=${real#"$repo"/}
work=${TMPDIR:-/tmp}/darling-t1-state-probe.$$
trap 'rm -rf "$work"' EXIT HUP INT TERM

[ -f "$real" ] || { echo "PROBE: FATAL $rel not found -- run me from a checked-out repo" >&2; exit 1; }

# 1. what the real file says today (the fix landed => the literal must be gone for good)
state=LITERAL-ABSENT
if grep -q 'usr/local' "$real"; then state=LITERAL-PRESENT; fi
printf 'PROBE: %s /usr/local -> %s\n' "$rel" "$state"

# 2. the desirable state everywhere except the installer, which is the real file
sh "$here/mkprefixfixture.sh" "$work/pfx" >/dev/null
cp "$real" "$work/pfx/root/usr/lib/darling-lol/tools/install-riot-darling-server.py"
chmod 0644 "$work/pfx/root/usr/lib/darling-lol/tools/install-riot-darling-server.py"
prefix_files_all() { ( cd "$1" && find . \( ! -type d -o -type d -empty \) -printf '/%P\n' ) | LC_ALL=C sort > "$2"; }
prefix_files_all "$work/pfx/root" "$work/pfx/files.all"

rc=0
out=$(sh "$repo/packaging/common/check-prefix.sh" "$work/pfx/root" "$work/pfx/files.all" 2>&1) || rc=$?
printf '%s\n' "$out" | grep -E 'FATAL|install-riot-darling-server\.py' | sed 's/^/PROBE: /' || true
printf 'PROBE: check-prefix.sh over the REAL installer -> rc=%s\n' "$rc"

# 3. the required state, and a loud failure if the literal came back
case "$state:$rc" in
LITERAL-ABSENT:0)
  echo "PROBE: documented state OK -- LITERAL-ABSENT:0, the real installer is prefix-neutral and the sweep agrees"
  exit 0 ;;
LITERAL-PRESENT:0)
  echo "PROBE: FATAL regression -- $rel carries a literal prefix again AND the sweep still passes: G-PREFIX-1 is blind" >&2
  exit 1 ;;
LITERAL-PRESENT:*)
  echo "PROBE: FATAL regression -- $rel carries a literal prefix again (C22 came back)" >&2
  exit 1 ;;
*)
  echo "PROBE: unexpected state ($state + rc=$rc) -- update this guard" >&2
  exit 1 ;;
esac
