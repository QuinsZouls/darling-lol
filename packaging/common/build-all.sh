#!/bin/sh
# packaging/common/build-all.sh -- the single entry point for the release assets (TASKS.md T6,
# PLAN 12.3). A human or CI runs this and gets every format, or an error:
#
#   darling-lol_<ver>_amd64.deb                     -> packaging/common/build-deb.sh   (T3)
#   darling-lol-<ver>.<arch>.rpm                    -> packaging/common/build-rpm.sh   (T4)
#   darling-lol-<ver>-x86_64.pkg.tar.zst            -> packaging/common/build-arch.sh  (T6)
#   darling-lol-<ver>-linux-x86_64.tar.zst/.tar.gz  -> packaging/common/build-tar.sh   (T6)
#   SHA256SUMS, BUILD-INFO-packages.txt             -> here (the sums by build-tar.sh)
#
# It re-implements NOTHING. Every format is produced by the builder that owns it, through the entry
# point the plan names, so there is exactly one convention per format and no second one can grow
# here (T1's contract: if the staging tree and its lists are right, the four formats cannot
# disagree). What this script owns is the ORDER and the provenance:
#
#   1. arch  2. deb  3. rpm   -> the three packages
#   4. BUILD-INFO-packages.txt (before the sums, so SHA256SUMS covers it -- PLAN 12.2's asset list)
#   5. tar    -> the two release tarballs AND SHA256SUMS, i.e. last, because it is the step that
#                sums whatever the four families put in $dist
#   6. verification: the four formats exist and `sha256sum -c SHA256SUMS` passes
#
# Idempotent: every builder starts by removing the tree it is about to write, so a second run over
# an existing dist/ is a rebuild, not a collision (PLAN 18's re-dispatch concern).
#
# usage: build-all.sh {fixture|TAG}
#   fixture   build every format from packaging/testdata/mkfixture.sh's hostile-shape tree, through
#             the same code paths as a release. Needs dpkg-deb, rpmbuild, bsdtar and zstd on ONE
#             host, plus RPM_FIXTURE_ARCH on a host that cannot build x86_64 -- which build-all
#             sets for the fixture only. See the gate image in packaging/testdata/run-arch-gates.sh.
#   TAG       build every format from $DARLING_PKG_DIST/pkg/root, which scripts/build-packaging.sh
#             + packaging/common/stage.sh produced. This is the CI call.
#
# Environment (all optional):
#   DARLING_PKG_DIST  absolute dist/ directory (default: <repo>/dist)
#   PKG_DISTRO        the %dist token pkg-version.sh renders the rpm 'Release:' with (default: the
#                     inherited DIST, else 'fc41' -- the pin PLAN 10.3 states). NOT an output
#                     directory: see the DIST collision note in the body.
#   DEB_FAMILY, SUBJECT_DIST etc.  passed through untouched to the builder that reads them.
#   TAG               the version tag. Fixture mode reads ALL_FIXTURE_TAG first, then TAG, and
#                     otherwise derives it from the checkout (pkg-version.sh -> git describe);
#                     the resolved value is exported, so all four builders agree on one version.
set -eu

dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo=$(CDPATH='' cd -- "$dir/../.." && pwd)
prog=build-all

fatal() { echo "$prog: FATAL $*" >&2; exit 1; }
note() { echo "$prog: $*"; }
step() { echo "$prog: === $*"; }

[ "$#" -eq 1 ] || fatal "usage: sh packaging/common/build-all.sh {fixture|TAG}"
case $1 in
  -h | --help)
    sed -n '2,37p' "$0"
    exit 0
    ;;
esac
arg=$1

dist=${DARLING_PKG_DIST:-$repo/dist}
case "$dist" in
  /*) : ;;
  *) fatal "DARLING_PKG_DIST must be an absolute path (got '$dist')" ;;
esac
pkg=$dist/pkg
mkdir -p "$dist"
# `DIST` is TWO different variables on this branch, and this script is the only place they meet:
#   build-deb.sh   (T3)  DIST = the output/staging DIRECTORY (default `dist`)
#   pkg-version.sh (T1)  DIST = the %dist TOKEN of the rpm 'Release:' (default `fc41`)
# Exporting one value for both is a measured failure, not a worry: with DIST=/work/dist exported,
# the rendered spec said `Release: 1.lol./work/dist` and rpmbuild died with `rc=1, Illegal char
# '/' (0x2f)`. So the directory is handed to the deb builder as a PER-COMMAND assignment (it never
# enters this script's environment) and the token is handed to the rpm builder the same way.
pkg_distro=${PKG_DISTRO:-${DIST:-fc41}}
case "$pkg_distro" in
  */*)
    fatal "the %dist token is '$pkg_distro', which is a path.
  DIST is also build-deb.sh's output directory, so pass the token as PKG_DISTRO=fc41 (PLAN 10.3)
  instead of exporting DIST." ;;
esac

if [ "$arg" = fixture ]; then
  mode=fixture
  # The fixture tag is what the run was given (ALL_FIXTURE_TAG, else the exported TAG) and
  # otherwise the checkout's own version -- the same single derivation the production path uses
  # (pkg-version.sh -> git describe). packaging/common/ never carries a literal version
  # (G-STATIC); a git-less copy still renders the 0.0.0 dev form. It is exported as TAG below, so
  # no sub-builder can version itself differently.
  tag=${ALL_FIXTURE_TAG:-${TAG:-$(sh "$dir/pkg-version.sh")}}
else
  mode=production
  tag=$arg
  [ -d "$pkg/root" ] || fatal "$pkg/root is missing.
  Run scripts/build-packaging.sh (it needs x86-64) and then packaging/common/stage.sh, or use the
  'fixture' mode."
fi

# --- 0. pre-flights: read access and CI provenance, BEFORE the first builder --------------------
# Section 1..3 hands the tree to four builders that read it and copy it. Two things must be true
# before they start, and each is cheaper to learn here than halfway through a format.
#
# (a) READABILITY of the payload. scripts/build-packaging.sh installs the DESTDIR with sudo (it
# sets the setuid bit on usr/bin/darling), so on CI $pkg/root is root-owned -- including guest
# files that are mode 0700 BY DESIGN, the CUPS backends usr/libexec/cups/backend/{ipp,lpd,dnssd}.
# An unprivileged copy of those dies with "cp: cannot open '…/ipp' for reading: Permission denied"
# and run()'s wrapper buries it as "FATAL sh failed" ($1 = "sh"): run 39218437320 lost the real
# cause that way. Fail closed HERE, naming the path and the remedy instead.
#   - files AND directories, because a builder needs to read both.
#   - NO symlink following (find's default -P mode, and the test is restricted to -type f/-type
#     d): the tree carries usr/libexec/darling/Volumes/DarlingEmulatedDrive -> /, and a walk that
#     follows it escapes the tree entirely (C19).
#   - find's rc and stderr are captured SEPARATELY from its output (no pipe to hide the status):
#     stderr non-empty means the sweep could not complete, and an incomplete sweep is fail-closed
#     too -- a probe that cannot see the tree must not vouch for it.
# Runs in BOTH modes. Fixture trees are small and user-owned, so the probe is a no-op there; and
# as root every file reads, so a clean probe under sudo is the CORRECT reading, not a gap: the CI
# shape IS root (mirroring the T8 launcher step and the docker gates that verify these builders
# as root).
if [ -d "$pkg/root" ]; then
  _find_err=$(mktemp "${TMPDIR:-/tmp}/build-all-find-err.XXXXXX")
  _frc=0
  _unread=$(find "$pkg/root" \( -type f -o -type d \) ! -readable -print 2> "$_find_err") || _frc=$?
  _ferr=$(cat "$_find_err" 2>/dev/null || true)
  rm -f "$_find_err"
  if [ -n "$_unread" ]; then
    _n=$(printf '%s\n' "$_unread" | wc -l | tr -d ' ')
    fatal "cannot read $_n entries under $pkg/root as uid $(id -u):
$(printf '%s\n' "$_unread" | head -5 | sed 's/^/    /')
  the tree is root-owned after scripts/build-packaging.sh's sudo install (the setuid bit on
  usr/bin/darling): run this step with the privileges that created the tree (CI: under sudo -E,
  like the T8 launcher staging step)"
  fi
  if [ "$_frc" -ne 0 ] || [ -n "$_ferr" ]; then
    fatal "the readability sweep of $pkg/root did not complete (find rc=$_frc):
$(printf '%s\n' "$_ferr" | head -5 | sed 's/^/    /')
  fail closed rather than hand a tree it could not read to the builders: fix the sweep's
  environment, or run this step with the privileges that created the tree (CI: under sudo -E)"
  fi
fi

# (b) CI PROVENANCE. The workflow's env: block supplies COMMIT/REF/RUN for
# BUILD-INFO-packages.txt (PLAN 12.3). Without them build-info.sh falls back to "local" /
# "unknown" -- correct defaults for a laptop, a silent provenance lie for a CI build. The way the
# environment gets lost is a plain sudo without -E (env_reset), i.e. exactly the privilege
# boundary this step crosses, so the fatal names that remedy. Non-CI runs skip the check
# entirely: local builds are supposed to say "local".
if [ -n "${CI:-}" ]; then
  _miss=
  [ -n "${COMMIT:-}" ] || _miss="$_miss COMMIT"
  [ -n "${REF:-}" ] || _miss="$_miss REF"
  [ -n "${RUN:-}" ] || _miss="$_miss RUN"
  if [ -n "$_miss" ]; then
    fatal "CI is set but the provenance environment is empty:$_miss
  BUILD-INFO-packages.txt would record build-info.sh's 'local'/'unknown' defaults instead of
  this run (PLAN 12.3): the environment did not survive the privilege boundary -- run this step
  with sudo -E (or sudo --preserve-env=COMMIT,REF,RUN)"
  fi
fi

for f in files.all files.runtime files.launcher; do
  # In fixture mode the first builder stages the tree; in production the T1 contract says stage.sh
  # already ran, so a missing list is a broken pipeline rather than something to paper over.
  if [ "$mode" = production ]; then
    [ -s "$pkg/$f" ] || fatal "$pkg/$f is missing or empty: run packaging/common/stage.sh first"
  fi
done

# T4's fixture-arch knob is opt-in by design ("it has to say so") because the shipped runtime spec
# pins `ExclusiveArch: x86_64` and rpmbuild on any other host refuses it outright (measured:
# "No compatible architectures found for build" / "Architecture is not included"). build-all is a
# fixture runner, so it says so -- and only for the fixture: the production path never sets it, so
# a release still fails loudly if it is attempted from a host that cannot build x86_64.
if [ "$mode" = fixture ]; then
  RPM_FIXTURE_ARCH=${RPM_FIXTURE_ARCH:-$(uname -m)}
  export RPM_FIXTURE_ARCH
fi

# --- 1..3. the three packages, each through its own entry point ---------------------------------
# build-deb.sh reads the tag from the environment (its own `TAG` contract); every other builder
# takes it as an argument. One value, exported once, so no builder can version itself differently.
TAG=$tag
export TAG
run() { # run PROGRAM ARGS...
  step "$*"
  "$@" || fatal "$1 failed"
}
run sh "$dir/build-arch.sh" "$arg"

if [ "$mode" = fixture ]; then
  run env DIST="$dist" sh "$dir/build-deb.sh" fixture
else
  run env DIST="$dist" sh "$dir/build-deb.sh"
fi

run env DIST="$pkg_distro" sh "$dir/build-rpm.sh" "$arg"

# --- 4. provenance (PLAN 12.3) ------------------------------------------------------------------
# BUILD-INFO-packages.txt EXTENDS the 9-key schema the /usr/local release already publishes
# (EVIDENCE C17) -- one schema, one generator (build-info.sh); this script only supplies the values
# that are true of *this* build and that the generator cannot know. Written BEFORE build-tar.sh so
# SHA256SUMS covers it, and it is never hand-written: a parallel schema is exactly what C17 forbids.
step "BUILD-INFO-packages.txt"
# The rpm payload token is READ OFF THE SPEC that pins it (T4's MENOR-1 fix) instead of repeating
# the spelling here: build-info.sh's own default is the plan's `w19T.zstd`, which rpmbuild rejects.
# One spelling, one place; the battery asserts the two agree.
rpm_payload=$(sed -n 's/^%global _binary_payload //p' "$repo/packaging/rpm/darling-lol.spec.in" | head -1)
[ -n "$rpm_payload" ] || fatal "no '%global _binary_payload' pin in packaging/rpm/darling-lol.spec.in"
count_of() { [ -r "$1" ] && tr -d ' \t\n' < "$1" || printf 'unknown'; }
COMPONENTS=${COMPONENTS:-stock} PKG_PREFIX=${PKG_PREFIX:-/usr} \
  CMAKE_INSTALL_LIBDIR=${CMAKE_INSTALL_LIBDIR:-lib} CMAKE_INSTALL_PREFIX=${CMAKE_INSTALL_PREFIX:-/usr} \
  DEB_COMPRESSION=${DEB_COMPRESSION:-xz} RPM_PAYLOAD="$rpm_payload" \
  TAR_COMPRESSION=${TAR_COMPRESSION:-zstd -19 -T0} \
  RUNTIME_PATHS="$(count_of "$pkg/count.runtime")" \
  LAUNCHER_PATHS="$(count_of "$pkg/count.launcher")" \
  INSTALLED_SIZE_KIB="$(count_of "$pkg/installed-size-kib")" \
  sh "$dir/build-info.sh" "$dist/BUILD-INFO-packages.txt"
note "wrote $dist/BUILD-INFO-packages.txt ($(grep -c '^[a-z-]*: ' "$dist/BUILD-INFO-packages.txt" | tr -d ' ') keys)"

# --- 5. the tarballs + SHA256SUMS ---------------------------------------------------------------
run sh "$dir/build-tar.sh" "$arg"

# --- 6. verification: the property this script exists to prove ----------------------------------
# The four formats from ONE staging tree, and one manifest that covers them. A missing family or a
# SHA256SUMS that does not verify is a failure here, before anything is published.
step "verify the release asset set"
ver=$(sh "$dir/pkg-version.sh" "$tag")
missing=
# match_one PATTERN -- print the first file in $dist matching PATTERN's glob, or nothing. No `set --`
# here: this loop must not disturb the script's own positional parameters.
match_one() {
  for _f in "$dist"/$1; do
    if [ -f "$_f" ]; then
      printf '%s' "${_f##*/}"
      return 0
    fi
  done
  return 1
}
if [ "$mode" = fixture ]; then
  # fixture mode names its artifacts as TASKS.md T6's gate block does (`fix.*`), so the release-name
  # patterns below cannot match them: assert the fixture set with the same intent. The two package
  # formats are asserted through their own family pattern rather than by a hard-coded name, so a
  # renamed artifact is still caught.
  for pat in fix.pkg.tar.zst fix-launcher.pkg.tar.zst fix.tar.zst fix.tar.gz fix.deb \
    fix-launcher.deb 'darling-lol-*.rpm' SHA256SUMS BUILD-INFO-packages.txt; do
    match_one "$pat" > /dev/null || missing="$missing $pat"
  done
else
  for pat in "darling-lol_${ver}+lol-*_amd64.deb" "darling-lol-${ver}-*.rpm" \
    "darling-lol-${ver}-*-x86_64.pkg.tar.zst" "darling-lol-${ver}-linux-x86_64.tar.zst" \
    "darling-lol-${ver}-linux-x86_64.tar.gz" SHA256SUMS BUILD-INFO-packages.txt; do
    match_one "$pat" > /dev/null || missing="$missing $pat"
  done
fi
[ -z "$missing" ] || fatal "the release is incomplete, missing:$missing"
( cd "$dist" && sha256sum -c SHA256SUMS > /dev/null ) || fatal "SHA256SUMS does not verify in $dist"

note "assets in $dist:"
# A glob, not `ls | grep` (SC2010): the names here are the ones this run just wrote, and a loop
# keeps unusual-but-legal characters intact. Directories (the staging tree, the fixture tree) and
# the rpm builder's config copy are not release assets.
for _f in "$dist"/*; do
  [ -e "$_f" ] || continue
  case "${_f##*/}" in
    pkg | fixture | rpmlint.toml) continue ;;
  esac
  printf '    %s\n' "${_f##*/}"
done
note "done: $ver (tag $tag, mode $mode)"
