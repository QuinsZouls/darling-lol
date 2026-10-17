#!/usr/bin/env bash
# packaging/install/test-detect.sh -- G-INSTALL-2b, runnable from the tree (T10b review, MAJOR-4).
#
# The fixtures this gate runs live in packaging/install/testdata/os-release/ and travel WITH the
# commit. Before that they were reconstructed ad hoc in the pre-review battery, so the one gate that
# caught C24 (`*archlinux*` rejecting the Steam Deck, whose ID_LIKE is the lone token `arch`) could
# not be executed from the repository at all -- and the mutation that kills the fix, `*arch*)` ->
# `*archlinux*)`, stayed invisible to every in-tree gate (it is exactly `mx_archlinux_token` in
# run-mutations.sh, which this gate is what catches).
#
#   bash packaging/install/test-detect.sh packaging/install/darling-lol-install.sh
#
# NO root and NO container: --detect-only is unprivileged exit #2 (before require_root). That is
# deliberate -- this is the arm CSS-* machine-independent half, so it runs on any CI runner.
#
# Rows: fixtures-present (all 7, and the load-bearing fields inside them), one row per fixture
# (family + release), and alpine-refusal (rc != 0 with the --method tar hint). Every row has a
# mutant in run-mutations.sh.
set -eu

INSTALLER=${1:-dist/darling-lol-install.sh}
FIXTURES=${FIXTURE_DIR:-packaging/install/testdata/os-release}
EXPECTED="ubuntu debian fedora arch steamos linuxmint alpine"

[ -f "$INSTALLER" ] || { echo "SKIP: $INSTALLER does not exist (pass the installer path as \$1)"; exit 77; }
[ -d "$FIXTURES" ] || { echo "SKIP: no fixture dir $FIXTURES"; exit 77; }

fail=0
ok()  { printf 'OK   %s\n' "$1"; }
bad() { printf 'FAIL %s: %s\n' "$1" "$2"; fail=1; }

# ---- row fixtures-present: the seven files, and the fields that make each one carry its weight ---
missing=""
for d in $EXPECTED; do
  [ -r "$FIXTURES/$d" ] || missing="$missing $d"
done
if [ -n "$missing" ]; then
  bad fixtures-present "missing fixture(s):$missing (they live in packaging/install/testdata/os-release/)"
else
  # A fixture that has been "tidied" tests nothing. These four lines are the load-bearing values:
  # steamos' ID_LIKE is the bare `arch` token (C24), linuxmint has MINT's VERSION_ID plus Ubuntu's
  # UBUNTU_CODENAME (NIT-2), and arch/alpine carry no ID_LIKE at all, so the ID branch is the only
  # thing that can identify them.
  problems=""
  grep -qx 'ID_LIKE=arch' "$FIXTURES/steamos" || problems="$problems steamos-ID_LIKE!=arch"
  grep -qx 'UBUNTU_CODENAME=noble' "$FIXTURES/linuxmint" || problems="$problems linuxmint-UBUNTU_CODENAME!=noble"
  grep -qx 'VERSION_ID="22"' "$FIXTURES/linuxmint" || problems="$problems linuxmint-VERSION_ID!=22"
  for d in arch alpine; do
    grep -q '^ID_LIKE=' "$FIXTURES/$d" && problems="$problems $d-unexpected-ID_LIKE"
  done
  if [ -n "$problems" ]; then
    bad fixtures-present "a fixture no longer carries the value this gate asserts:$problems"
  else
    ok fixtures-present
  fi
fi

# ---- detect: FIXTURE FAMILY RELEASE -----------------------------------------------------------------
detect() { # detect FIXTURE FAMILY RELEASE
  _f=$1 _fam=$2 _rel=$3
  set +e
  _out=$(OS_RELEASE_FIXTURE="$FIXTURES/$_f" bash "$INSTALLER" --detect-only 2>&1)
  _rc=$?
  set -e
  if [ "$_rc" -ne 0 ]; then
    bad "$_f" "rc=$_rc (--detect-only must exit 0 unprivileged): $(printf '%s' "$_out" | tail -2 | tr '\n' ' ')"
    return 0
  fi
  if printf '%s' "$_out" | grep -qE "family=$_fam release=$_rel(\$| )"; then
    ok "$_f"
  else
    bad "$_f" "expected family=$_fam release=$_rel, got: $(printf '%s' "$_out" | tail -1)"
  fi
}

detect ubuntu    deb  noble         # VERSION_CODENAME / UBUNTU_CODENAME
detect debian    deb  bookworm      # VERSION_CODENAME, no ID_LIKE
detect linuxmint deb  noble         # 🚨 derivative: VERSION_ID is MINT's 22, the codename is Ubuntu's
detect fedora    rpm  fc41          # RELEASE = fc${VERSION_ID%%.*}
detect arch      arch rolling       # no ID_LIKE: only the ID branch identifies it
detect steamos   arch rolling       # 🚨 C24: ID_LIKE=arch, NOT archlinux

# ---- row alpine-refusal: no family this installer knows -> die with the --method tar hint --------
set +e
out=$(OS_RELEASE_FIXTURE="$FIXTURES/alpine" bash "$INSTALLER" --detect-only 2>&1)
rc=$?
set -e
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q -- '--method tar'; then
  ok alpine-refusal
else
  bad alpine-refusal "rc=$rc; alpine must be refused with the '--method tar' hint: $(printf '%s' "$out" | tail -2 | tr '\n' ' ')"
fi

if [ "$fail" = 0 ]; then
  echo "G-INSTALL-2b: OK (7 fixtures: 6 detected + alpine refused with the --method tar hint)"
else
  echo "G-INSTALL-2b: FAILED"
fi
exit "$fail"
