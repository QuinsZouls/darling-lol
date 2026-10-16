#!/bin/sh
# packaging/testdata/state-probe.sh -- CURRENT-STATE probe for C22 (T1 review, INFO).
#
# ⚠ TRANSIENT -- delete me when T8 lands.
#
# The positive G-PREFIX-1 fixture (mkprefixfixture.sh `prefix_host`) deliberately writes the
# **T8-FIXED** installer: no literal prefix, resolved with shutil.which(). That is the state the
# packaging wants, so the fixture is right to do it -- but it means the positive run proves the
# gate against a state that does not exist in the tree yet. Today the tracked file still carries
# the literal default:
#
#     tools/install-riot-darling-server.py:89
#         parser.add_argument("--destination", type=Path, default=Path("/usr/local/bin/darlingserver"))
#
# and that path is not on check-prefix.sh's 4-file allowlist, so sweeping a tree that contains the
# real file FATALs (this is exactly mutation M7). The discrepancy is real and must stay visible
# rather than hidden behind the fixture, so this probe runs the delivered gate over a tree in which
# the ONLY difference from the desirable state is that the installer is the REAL tracked file, and
# documents the result.
#
# Exit status: 0 when the observed state matches what this file documents (so it is safe to wire
# into run-gates.sh), 1 when reality moved and this comment/probe must be updated.
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

# 1. what the real file says today (T8 not landed => the literal is still there)
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

# 3. the documented state, and a loud failure if it moved without this file being updated
case "$state:$rc" in
LITERAL-PRESENT:1)
  printf '%s\n' "$out" | grep -q 'install-riot-darling-server\.py' || {
    echo "PROBE: FATAL rc=1 but the installer is NOT named -- the sweep went blind" >&2; exit 1; }
  echo "PROBE: documented state OK -- rc=1 names $rel (T8 has NOT landed; this is expected today)"
  exit 0 ;;
LITERAL-PRESENT:0)
  echo "PROBE: FATAL the literal is present yet the sweep passes -- G-PREFIX-1 is blind" >&2; exit 1 ;;
LITERAL-ABSENT:0)
  echo "PROBE: T8-LANDED -- the literal is gone and the sweep passes; delete this probe" >&2; exit 0 ;;
*)
  echo "PROBE: unexpected state ($state + rc=$rc) -- update this probe" >&2; exit 1 ;;
esac
