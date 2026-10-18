#!/usr/bin/env bash
# packaging/testdata/run-arch-gates.sh -- T6's gate battery: PLAN 11's G-ARCH-1..3, PLAN 12's
# tar/SHA256SUMS invariants, PLAN 5's C18, the TASKS.md T6 acceptance rows, the C52 pair the T6
# amendment inherits from T4, and TASKS.md T6's mutation table -- self-contained, ASSERTING and
# hermetic.
#
#   bash packaging/testdata/run-arch-gates.sh
#
# WHAT IT IS. Every row asserts a value AND the command that produced it; a row that cannot be made
# to fail is not a row. The object under test is a byte-identical copy of `packaging/` in one
# private `mktemp -d` (asserted with `diff -r`), so the negative controls break the object without
# touching the repo, and nothing else is read: no `dist/`, no state from an earlier run.
#
# WHY A CONTAINER. bsdtar, zstd, rpmbuild and dpkg-deb must be on ONE host for `build-all.sh
# fixture` to produce all four formats (PLAN 12.3's single entry point), and this box has no
# rpmbuild and no bsdtar outside an image. The battery hands the copy to one container run that
# MEASURES (build, list, query, collect) while every assertion is made here, on the artifacts it
# collected.
#
#   T6_ARCH_IMAGE=<image>   default `fedora:41`, which is BARE (no bsdtar, no rpmbuild, no
#                           dpkg-deb -- measured). The battery therefore provisions the gate image
#                           ONCE and reuses the tag for the (1 + N controls) container runs; an
#                           explicit T6_ARCH_IMAGE is used as it is and refused if it cannot drive
#                           all four builders. The recipe it builds:
#
#       docker build -t darling-arch-gates:fc41 - <<'EOF'
#       FROM fedora:41
#       RUN dnf -y install rpm-build rpmlint xz diffutils binutils zstd dpkg bsdtar gzip tar \
#            && dnf clean all
#       EOF
#       T6_ARCH_IMAGE=darling-arch-gates:fc41 bash packaging/testdata/run-arch-gates.sh
#                           (that env var is the way to skip the build when the image is there.)
#
#                           (fedora:41 is PLAN 10.3's pin for everything that needs the rpm
#                           toolchain; the Arch half needs no Arch host at all -- makepkg is
#                           deliberately NOT used, PLAN 11 -- which is why ONE image covers all
#                           four formats.)
#   T6_GATES_BREAK=<name>   negative-control hook: break the OBJECT under test and re-run (see the
#                           bottom of this file). Unset in a normal run.
#   T6_GATES_CONTROLS=<spec> `all` (default) or a space-separated subset of the control names. The
#                           knob is READ (it was documented and inert): the resolved list is what the
#                           sweep runs AND what the skip account counts, and a spec that selects no
#                           control is a FAILED row -- an empty sweep is not a green sweep.
#   T6_GATES_NO_CONTROLS=1  do not run the control sweep. The gate rows are unchanged; the sweep is
#                           the proof they can go red, so it is ON by default. A sweep that does
#                           not run is REPORTED and counted as skipped (`K skipped` in the summary
#                           plus one named SKIP per control), never folded into `passed` and never
#                           fatal: nothing in CI runs this battery (grep -rn testdata .github/ ->
#                           no match), so no input is *expected* here and there is no equivalent of
#                           run-deb-gates.sh's T3_GATES_REQUIRE_DOCKER to mirror.
#   T6_GATES_QUIET=1        print only the rows that are not PASS (what the sweep reads). A SKIP is
#                           not a PASS, so the skip lines and every summary count still print.
#   T6_GATES_KEEP=1         keep and print the private work directory, for a red row that needs its
#                           artifacts inspected.
#
# `sh run-arch-gates.sh` (= dash here) would die on the first bashism, AFTER printing part of the
# table -- which a careless runner reads as "mostly green". Refuse up front instead, in a form dash
# can parse, so that the message is the output (same defence as run-gates.sh / run-rpm-gates.sh).
case "${BASH_VERSION:-}" in
  "") echo "run-arch-gates: run me with bash: bash $0" >&2; exit 2 ;;
esac
set -u

for _f in packaging/common/build-all.sh packaging/common/build-arch.sh packaging/common/build-tar.sh \
  packaging/arch/PKGINFO.in packaging/arch/launcher-PKGINFO.in packaging/arch/INSTALL; do
  if [ ! -f "$_f" ]; then
    echo "run-arch-gates: run me from the repo root, with $_f present" >&2
    exit 2
  fi
done

CONTROL_NAMES="no-recursion absolute-list word-split pkgver-nohyphen metadata-order mtree-no-mode \
no-fakeroot gzip-mtree exit1-hook sha-incomplete"
case "${1:-}" in
  --list-controls)
    for c in $CONTROL_NAMES; do printf '%s\n' "$c"; done
    exit 0
    ;;
  "") : ;;
  *) echo "run-arch-gates: unknown argument '$1' (try --help)" >&2; exit 2 ;;
esac

# every control names the row it must turn red; the sweep asserts THAT row fails, that the child run
# fails at all, and that the break itself was not a no-op.
ctl_row() {
  case $1 in
    no-recursion)     echo "G-TAR-2 no duplicate member in either tarball (C2)" ;;
    absolute-list)    echo "G-TAR-3 the tarball holds the payload, not the host's /usr (C43-a)" ;;
    word-split)       echo "G-ARCH-3 the member list never went through word splitting" ;;
    pkgver-nohyphen)  echo "G-ARCH-1 .PKGINFO pkgver carries the '-' libalpm needs" ;;
    metadata-order)   echo "G-ARCH-1 metadata first: .PKGINFO .MTREE .INSTALL" ;;
    mtree-no-mode)    echo "G-ARCH-2 .MTREE records mode=4755 for ./usr/bin/darling" ;;
    no-fakeroot)      echo "G-ARCH-4 every member is 0/root/root" ;;
    gzip-mtree)       echo "G-ARCH-2 .MTREE records mode=4755 for ./usr/bin/darling" ;;
    exit1-hook)       echo "G-ARCH-5 the pacman hook reports, it never fails the transaction" ;;
    sha-incomplete)   echo "G-ALL-3 SHA256SUMS covers every asset" ;;
  esac
}

BREAK=${T6_GATES_BREAK:-}
IMAGE=${T6_ARCH_IMAGE:-fedora:41}
CONTROLS=${T6_GATES_NO_CONTROLS:-}
if [ -n "$BREAK" ]; then
  case " $CONTROL_NAMES " in
    *" $BREAK "*) : ;;
    *) echo "run-arch-gates: T6_GATES_BREAK='$BREAK' is not a control (--list-controls)" >&2; exit 2 ;;
  esac
  CONTROLS=1 # a broken run never sweeps: that is the recursion guard
fi
QUIET=${T6_GATES_QUIET:-}

WORK=$(mktemp -d "${TMPDIR:-/tmp}/darling-t6-arch.XXXXXX")
O=$WORK/out
SRC=$WORK/src

# The container runs as root, so everything it writes into the bind mount is root-owned and the
# cleanup below would fail without help: it chowns /work on the way out, and if it died too early
# this fallback removes the tree from inside a container instead of leaving junk in $TMPDIR.
cleanup_work() {
  if [ -n "${T6_GATES_KEEP:-}" ]; then
    printf 'run-arch-gates: kept %s (T6_GATES_KEEP)\n' "$WORK" >&2
    return 0
  fi
  [ -d "$WORK" ] || return 0
  rm -rf "$WORK" 2>/dev/null && return 0
  if [ -n "${DOCKER:-}" ]; then
    "$DOCKER" run --rm -v "$WORK:/work" --entrypoint sh "$IMAGE" -c 'rm -rf /work' >/dev/null 2>&1
  fi
  rm -rf "$WORK" 2>/dev/null \
    || printf 'run-arch-gates: could not remove %s (the container left root-owned files)\n' "$WORK" >&2
}
trap cleanup_work EXIT HUP INT TERM

# Colour only for a terminal: redirected output (CI logs, the control sweep's own greps) is plain
# text, so what the sweep reads is what the reader sees.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_OK=$'\033[32m'; C_ER=$'\033[31m'; C_SK=$'\033[33m'; C_B=$'\033[1m'; C_0=$'\033[0m'
else
  C_OK=; C_ER=; C_SK=; C_B=; C_0=
fi
# Every row ends in exactly one of three states: PASS, FAIL, or SKIP. A skipped row is COUNTED and
# NAMED (see run-deb-gates.sh, the model for `skips`) and is never folded into `pass` -- a battery
# that reports a green total over rows that never ran is the lie this counter exists to prevent.
# `rows` is the number of rows that produced a verdict, so `rows == pass + fail`, asserted at the
# summary: a counter without a definition is the same lie in a new place.
rows=0; pass=0; fail=0; skips=0; ROWFAIL=0
# control-row counters (G-ARCH-6, below the summary): ctl_no prints a FAIL and counts a control that
# did not kill its row. It deliberately does NOT touch `fail`: the gate rows' verdict is printed by
# the summary, and a control failure must not rewrite a number that was already reported.
ctl_ok=0; ctl_bad=0; ctl_rows=0
no2() { fail=$((fail+1)); printf '  %sFAIL%s %s\n' "$C_ER" "$C_0" "$1"; }
ctl_no() { ctl_bad=$((ctl_bad+1)); printf '  %sFAIL%s %s\n' "$C_ER" "$C_0" "$1"; }
skip() { skips=$((skips+1)); printf '  %sSKIP%s %s\n' "$C_SK" "$C_0" "$1"; }
chk() { # chk LABEL GOT WANT -- a one-assertion row
  rows=$((rows+1))
  if [ -z "$2" ]; then no2 "$1: EMPTY result (command failed)"
  elif [ "$2" = "$3" ]; then pass=$((pass+1)); [ -n "$QUIET" ] || printf '  %sPASS%s %s (%s)\n' "$C_OK" "$C_0" "$1" "$2"
  else no2 "$1: got '$2', want '$3'"; fi
}
sec() { [ -n "$QUIET" ] || printf '\n%s%s%s\n' "$C_B" "$1" "$C_0"; }
sa() { # sa LABEL GOT WANT -- one arm of a multi-assertion row
  if [ -z "$2" ]; then ROWFAIL=1; [ -n "$QUIET" ] || printf '      FAIL %s: EMPTY (command failed)\n' "$1"
  elif [ "$2" = "$3" ]; then [ -n "$QUIET" ] || printf '      %sok%s %s (%s)\n' "$C_OK" "$C_0" "$1" "$2"
  else ROWFAIL=1; printf '      FAIL %s: got %s, want %s\n' "$1" "$2" "$3"; fi
}
sage() { # sage LABEL GOT MIN -- an arm that must be AT LEAST MIN
  if [ -z "$2" ]; then ROWFAIL=1; [ -n "$QUIET" ] || printf '      FAIL %s: EMPTY (command failed)\n' "$1"
  elif [ "$2" -ge "$3" ] 2>/dev/null; then [ -n "$QUIET" ] || printf '      %sok%s %s (%s >= %s)\n' "$C_OK" "$C_0" "$1" "$2" "$3"
  else ROWFAIL=1; printf '      FAIL %s: got %s, want >= %s\n' "$1" "$2" "$3"; fi
}
end_row() { # end_row LABEL
  rows=$((rows+1))
  if [ "$ROWFAIL" = 0 ]; then pass=$((pass+1)); [ -n "$QUIET" ] || printf '  %sPASS%s %s\n' "$C_OK" "$C_0" "$1"
  else fail=$((fail+1)); printf '  %sFAIL%s %s\n' "$C_ER" "$C_0" "$1"; fi
  ROWFAIL=0
}
val() { [ -f "$O/$1" ] && cat "$O/$1"; }                       # an artifact, or empty
cnt() { if [ -f "$O/$1" ]; then wc -l < "$O/$1" | tr -d ' '; else echo missing; fi; }
num() { # num FILE ERE
  if [ -f "$O/$1" ]; then c=$(grep -c -E -- "$2" "$O/$1"); printf '%s' "${c:-0}"; else echo missing; fi
}
lit() { # lit FILE STRING
  if [ -f "$O/$1" ]; then c=$(grep -c -F -- "$2" "$O/$1"); printf '%s' "${c:-0}"; else echo missing; fi
}
uniq_line() { # uniq_line FILE -- the file's sorted-unique non-empty lines, space-joined
  if [ -f "$O/$1" ]; then LC_ALL=C sort -u "$O/$1" | tr '\n' ' '; fi
}
rc()  { if [ -f "$O/$1.rc" ]; then cat "$O/$1.rc"; else echo missing; fi; }

# ================================================================================================
sec "G-ARCH-0  the object under test, and the container"

mkdir -p "$SRC"
cp -a packaging "$SRC/packaging"
# Three things OUTSIDE packaging/ are read on the way through build-all.sh: the upstream pin
# (packaging/deb/mk-copyright.sh reads upstream/manifest.json) and the two files the rpm's
# %license / the deb's copyright header carry. Copying them keeps the battery hermetic -- without
# them `build-all.sh fixture` dies in the deb step, after the Arch packages are already built, and
# every artifact row below would be red for a reason that has nothing to do with T6.
for _p in upstream LICENSE NOTICE.md; do
  [ -e "$_p" ] && cp -a "$_p" "$SRC/"
done
chk "the object under test is a byte-identical copy of packaging/" \
  "$(diff -r packaging "$SRC/packaging" >/dev/null 2>&1 && echo same || echo differs)" "same"

DOCKER=
for d in docker podman; do command -v "$d" >/dev/null 2>&1 && { DOCKER=$d; break; }; done
if [ -z "$DOCKER" ]; then
  printf '\n%sFATAL%s no container runtime: not one G-ARCH row can run on this box.\n' "$C_ER" "$C_0" >&2
  exit 1
fi
if ! "$DOCKER" info >/dev/null 2>&1; then
  printf '\n%sFATAL%s %s daemon unreachable: not one G-ARCH row can run.\n' "$C_ER" "$C_0" "$DOCKER" >&2
  exit 1
fi

# The image must carry all four toolchains: PLAN 12.3's single entry point drives the deb, the rpm,
# the Arch package and the release tarballs from one staging tree, and that chain is half of what T6
# asserts. A bare `fedora:41` carries zstd/gzip/tar and neither bsdtar, rpmbuild nor dpkg-deb
# (measured), and the run would then print 19 red rows that blame the object for a missing package.
# So the battery provisions the gate image ONCE, from the recipe this file's header documents, and
# every later run reuses the tag instead of paying for it again.
image_ready() { # image_ready IMAGE -- the three toolchains `build-all.sh fixture` needs beyond core
  "$DOCKER" run --rm --entrypoint sh "$1" -c \
    'command -v bsdtar >/dev/null 2>&1 && command -v rpmbuild >/dev/null 2>&1 \
       && command -v dpkg-deb >/dev/null 2>&1' >/dev/null 2>&1
}
if [ -n "${T6_ARCH_IMAGE:-}" ]; then
  # An explicit choice is never second-guessed: it is provisioned, or the run stops here.
  if ! image_ready "$IMAGE"; then
    printf '\n%sFATAL%s T6_ARCH_IMAGE=%s carries no bsdtar/rpmbuild/dpkg-deb, so the fixture run would\n' \
      "$C_ER" "$C_0" "$IMAGE" >&2
    printf '       measure nothing. Point it at a provisioned image (see this file'"'"'s header).\n' >&2
    exit 1
  fi
elif image_ready "$IMAGE"; then
  : # a fedora:41 that already has them (someone provisioned it): use it as it is
elif image_ready darling-arch-gates:fc41; then
  printf '%snote%s %s is bare: using the prebuilt gate image darling-arch-gates:fc41\n' \
    "$C_B" "$C_0" "$IMAGE"
  IMAGE=darling-arch-gates:fc41
else
  printf '%snote%s %s is bare: building darling-arch-gates:fc41 once (dnf -y install ...)\n' \
    "$C_B" "$C_0" "$IMAGE"
  cat > "$WORK/gate-image.Dockerfile" <<DOCKERFILE
FROM $IMAGE
RUN dnf -y install rpm-build rpmlint xz diffutils binutils zstd dpkg bsdtar gzip tar \
  && dnf clean all
DOCKERFILE
  if ! "$DOCKER" build -t darling-arch-gates:fc41 -f "$WORK/gate-image.Dockerfile" "$WORK" >&2; then
    printf '\n%sFATAL%s could not provision the gate image (network? dnf?): nothing was measured.\n' \
      "$C_ER" "$C_0" >&2
    exit 1
  fi
  IMAGE=darling-arch-gates:fc41
fi
chk "container runtime" "$DOCKER" "$DOCKER"
chk "the image carries bsdtar, rpmbuild and dpkg-deb" "$(image_ready "$IMAGE" && echo yes)" "yes"

mkdir -p "$O"

# ------------------------------------------------------------------------------------------------
# the container half: generated here, MEASURES only, every assertion stays in this file
cat > "$WORK/in-container.sh" <<'IN_CONTAINER'
#!/bin/bash
# in-container.sh -- the container half of packaging/testdata/run-arch-gates.sh: it MEASURES, the
# harness ASSERTS. /src is the battery's byte-identical copy of packaging/ (writable, so a negative
# control can break the object under test without touching the repo); /work is its scratch; every
# artifact lands in /work/out, and this file reads nothing it did not write.
set -u
export LC_ALL=C

# The bind mount is the host's $TMPDIR tree and this process is root: chown on the way out so the
# harness can clean up after itself (it is the host user who has to remove it).
chown_work() {
  [ -n "${T6_HOST_UID:-}" ] || return 0
  chown -R "$T6_HOST_UID:${T6_HOST_GID:-0}" /work 2>/dev/null || :
}
trap chown_work EXIT

OUT=/work/out
DIST=/work/dist
SRC=/src
rm -rf "$OUT" "$DIST" /work/dl
mkdir -p "$OUT"

printf '%s\n' "$(uname -m)" > "$OUT/uname-m.txt"
for t in bsdtar zstd tar gzip rpmbuild rpm dpkg-deb sha256sum; do
  if command -v "$t" >/dev/null 2>&1; then
    "$t" --version 2>&1 | head -1 > "$OUT/tool-$t.txt"
  else
    echo absent > "$OUT/tool-$t.txt"
  fi
done

# --- the negative-control hook: break the OBJECT, and prove the break is real -------------------
BRK=${T6_GATES_BREAK:-}
break_one() { # break_one FILE 'SED EXPR'
  _f=$1
  _e=$2
  _b=$(md5sum "$_f")
  sed -i "$_e" "$_f"
  _a=$(md5sum "$_f")
  [ "$_b" != "$_a" ] || { echo "BREAK-NOOP: '$_e' changed nothing in $_f"; exit 5; }
  echo "break $BRK: mutated $_f"
}
case "$BRK" in
  "")
    ;;
  no-recursion)
    # C2: with recursion on, a LISTED directory duplicates its children. Two breaks, because the
    # T1 fixture's files.all lists no non-empty directory (mkfixture.sh emits files, symlinks and
    # EMPTY dirs only) -- so dropping the flag alone is inert HERE, measured. The second break
    # restores C2's premise with a directory the fixture really has (it carries the four %-paths).
    break_one "$SRC/packaging/common/build-tar.sh" 's# --no-recursion##g'
    break_one "$SRC/packaging/common/build-tar.sh" \
      's#sed '"'"'s|^/||'"'"' "$pkg/files.all" > "$tmp/files.all.rel"#sed '"'"'s|^/||'"'"' "$pkg/files.all" > "$tmp/files.all.rel"; echo usr/libexec/darling/usr/share >> "$tmp/files.all.rel"#'
    ;;
  absolute-list)
    # C43-a: an absolute -T entry is stat'ed from /, so the tarball ships the HOST's /usr.
    break_one "$SRC/packaging/common/build-tar.sh" \
      's#sed '"'"'s|^/||'"'"' "$pkg/files.all" > "$tmp/files.all.rel"#cp "$pkg/files.all" "$tmp/files.all.rel"#'
    break_one "$SRC/packaging/common/build-tar.sh" \
      's#grep -q '"'"'\^/'"'"' "$tmp/files.all.rel"#: #'
    ;;
  word-split)
    # PLAN 11.4 trap 2: the member list must never reach the archiver through shell word splitting.
    break_one "$SRC/packaging/common/build-arch.sh" \
      's#--null -T "$_list" -cf -#-cf - $(tr "\\n" " " < "$_list")#'
    ;;
  pkgver-nohyphen)
    # FACTS:145-149: libalpm rejects a pkgver without '-'.
    break_one "$SRC/packaging/arch/PKGINFO.in" 's#^pkgver = @ARCH_PKGVER@-@ARCH_PKGREL@$#pkgver = @ARCH_PKGVER@#'
    break_one "$SRC/packaging/arch/launcher-PKGINFO.in" 's#^pkgver = @ARCH_PKGVER@-@ARCH_PKGREL@$#pkgver = @ARCH_PKGVER@#'
    ;;
  metadata-order)
    # The archive is handed the MTREE input list, which has no .MTREE entry (it is being written):
    # the runtime package is then used to prove the order arm.
    break_one "$SRC/packaging/common/build-arch.sh" \
      's#make_archive "$_name" "$tmp/$_name.nul" "$_out"#make_archive "$_name" "$tmp/$_name.mtree.nul" "$_out"#'
    ;;
  mtree-no-mode)
    # PLAN 11.2's recipe lists the mtree keywords; `mode` is the one that records 4755. (Dropping
    # `use-set` does NOT remove it -- measured: the keyword is what emits the attribute; the set is
    # only how equal values are factored out. See the T6 report.)
    break_one "$SRC/packaging/common/build-arch.sh" 's#use-set,type,uid,gid,mode,time#use-set,type,uid,gid,time#'
    ;;
  no-fakeroot)
    # makepkg packages under fakeroot; without it every member records the builder's uid.
    break_one "$SRC/packaging/common/build-arch.sh" \
      's#--uid 0 --gid 0 --uname root --gname root --null -T "$_list"#--null -T "$_list"#'
    ;;
  gzip-mtree)
    # PLAN 11.2's fence pipes the mtree through gzip; T6 ships it as text (see the report). This
    # control is what keeps the two apart: with the gz form the member is deflate, not mtree.
    break_one "$SRC/packaging/common/build-arch.sh" \
      's#mv "$tmp/$_name.mtree.raw" "$root/.MTREE"#gzip -c -f -n "$tmp/$_name.mtree.raw" > "$root/.MTREE"#'
    ;;
  exit1-hook)
    # PLAN 11.3 / R11: a pacman hook cannot fail the transaction, so it must not `exit 1`.
    break_one "$SRC/packaging/arch/INSTALL" 's#^post_install() {$#post_install() { exit 1#'
    ;;
  sha-incomplete)
    # PLAN 12.2: SHA256SUMS covers EVERY asset, the two tarballs included.
    break_one "$SRC/packaging/common/build-tar.sh" 's#for _f in "$zst_out" "$gz_out"; do#for _f in; do#'
    ;;
  *)
    echo "BREAK-UNKNOWN: '$BRK'" >&2
    exit 5
    ;;
esac

# --- the build: PLAN 12.3's single entry point, over the hostile-shape fixture -------------------
# SOURCE_DATE_EPOCH pins builddate / %changelog / the mtimes, so two runs of this battery produce
# the same bytes (it is also what rpm's _source_date_epoch_from_changelog reads).
cd "$SRC" || exit 6
export SOURCE_DATE_EPOCH=1700000000
# The fixture tag, ONE value for all four builders -- the same convention run-deb-gates.sh pins
# (TAG=v0.1.0): the harness owns the literal version, packaging/common/ derives its own
# (pkg-version.sh -> git describe, and this copy has no .git). build-all.sh exports the resolved
# value, so the Arch/rpm/deb rows below can assert an exact version instead of a shape.
export TAG=v0.1.0 ALL_FIXTURE_TAG=v0.1.0 ARCH_FIXTURE_TAG=v0.1.0 TAR_FIXTURE_TAG=v0.1.0
DARLING_PKG_DIST=$DIST sh packaging/common/build-all.sh fixture > "$OUT/build.log" 2>&1
echo $? > "$OUT/build.rc"

[ -d "$DIST" ] && ls -1 "$DIST" > "$OUT/inventory.txt"
# Collect what there is. A failed build is a row of its own (build.rc); every artifact row below is
# then EMPTY, which is a FAIL and not a crash.
if [ -f "$DIST/pkg/files.all" ]; then
  wc -l < "$DIST/pkg/files.all" | tr -d ' ' > "$OUT/files-all.count.txt"
fi
if [ -f "$DIST/pkg/files.runtime" ]; then
  wc -l < "$DIST/pkg/files.runtime" | tr -d ' ' > "$OUT/files-runtime.count.txt"
  grep -c ' ' "$DIST/pkg/files.runtime" > "$OUT/files-runtime.space.txt"
fi
if [ -f "$DIST/pkg/files.launcher" ]; then
  wc -l < "$DIST/pkg/files.launcher" | tr -d ' ' > "$OUT/files-launcher.count.txt"
fi

# --- the Arch packages --------------------------------------------------------------------------
if [ -f "$DIST/fix.pkg.tar.zst" ]; then
  bsdtar -tf "$DIST/fix.pkg.tar.zst" > "$OUT/pkg.members.txt" 2>/dev/null
  head -3 "$OUT/pkg.members.txt" > "$OUT/pkg.first3.txt"
  bsdtar -tvf "$DIST/fix.pkg.tar.zst" > "$OUT/pkg.tv.txt" 2>/dev/null
  awk 'NF > 4 { print $2 "/" $3 "/" $4 }' "$OUT/pkg.tv.txt" | LC_ALL=C sort -u > "$OUT/pkg.owners.txt"
  awk '$1 ~ /^-rws/ { print $NF }' "$OUT/pkg.tv.txt" | LC_ALL=C sort -u > "$OUT/pkg.setuid.txt"
  bsdtar -xOf "$DIST/fix.pkg.tar.zst" .PKGINFO > "$OUT/pkginfo.runtime.txt" 2>/dev/null
  bsdtar -xOf "$DIST/fix.pkg.tar.zst" .INSTALL > "$OUT/pkg.install.txt" 2>/dev/null
  # R11: a pacman hook must not abort the transaction. Counted comment-aware: the file's own header
  # explains that it never `exit 1`s, and a naive grep would read that sentence as the defect.
  awk '/^[[:space:]]*#/ { next }
       /(^|[^[:alnum:]_])exit 1([^[:alnum:]_]|$)/ { c++ }
       END { print c+0 }' "$OUT/pkg.install.txt" > "$OUT/pkg.install.exit1.txt"
  zstdcat "$DIST/fix.pkg.tar.zst" | bsdtar -xOf - .MTREE > "$OUT/pkg.mtree.txt" 2>/dev/null
  file "$OUT/pkg.mtree.txt" > "$OUT/pkg.mtree.file.txt" 2>/dev/null
  grep -c ' ' "$OUT/pkg.members.txt" > "$OUT/pkg.space.txt"
  grep -c '%' "$OUT/pkg.members.txt" > "$OUT/pkg.percent.txt"
  grep -oE 'uid=[0-9]+' "$OUT/pkg.mtree.txt" 2>/dev/null | LC_ALL=C sort -u > "$OUT/mtree.uids.txt"
  grep -oE 'gid=[0-9]+' "$OUT/pkg.mtree.txt" 2>/dev/null | LC_ALL=C sort -u > "$OUT/mtree.gids.txt"
  # C18 (PLAN 5): one path, one package -- asserted on the ARTIFACTS. The three metadata members
  # are excluded: every package carries its own .PKGINFO/.MTREE, and only the runtime an .INSTALL.
  sed -e 's|/$||' -e '/^\.PKGINFO$/d' -e '/^\.MTREE$/d' -e '/^\.INSTALL$/d' \
    "$OUT/pkg.members.txt" | LC_ALL=C sort > "$OUT/pkg.members.c18"
fi
if [ -f "$DIST/fix-launcher.pkg.tar.zst" ]; then
  bsdtar -tf "$DIST/fix-launcher.pkg.tar.zst" > "$OUT/launcher.members.txt" 2>/dev/null
  head -3 "$OUT/launcher.members.txt" > "$OUT/launcher.first3.txt"
  bsdtar -xOf "$DIST/fix-launcher.pkg.tar.zst" .PKGINFO > "$OUT/pkginfo.launcher.txt" 2>/dev/null
  sed -e 's|/$||' -e '/^\.PKGINFO$/d' -e '/^\.MTREE$/d' -e '/^\.INSTALL$/d' \
    "$OUT/launcher.members.txt" | LC_ALL=C sort > "$OUT/launcher.members.c18"
fi
if [ -f "$OUT/pkg.members.c18" ] && [ -f "$OUT/launcher.members.c18" ]; then
  comm -12 "$OUT/pkg.members.c18" "$OUT/launcher.members.c18" > "$OUT/pkg.overlap.txt"
fi

# --- the tarballs --------------------------------------------------------------------------------
if [ -f "$DIST/fix.tar.zst" ]; then
  tar -tf "$DIST/fix.tar.zst" > "$OUT/tar.zst.members.txt" 2>/dev/null
  zstdcat "$DIST/fix.tar.zst" | tar -tvf - > "$OUT/tar.zst.tv.txt" 2>/dev/null
  sed 's|/$||' "$OUT/tar.zst.members.txt" | LC_ALL=C sort | uniq -d > "$OUT/tar.zst.dups.txt"
  grep -c ' ' "$OUT/tar.zst.members.txt" > "$OUT/tar.space.txt"
  grep -c '%' "$OUT/tar.zst.members.txt" > "$OUT/tar.percent.txt"
  grep -c '^/' "$OUT/tar.zst.members.txt" > "$OUT/tar.absolute.txt"
fi
if [ -f "$DIST/fix.tar.gz" ]; then
  tar -tf "$DIST/fix.tar.gz" > "$OUT/tar.gz.members.txt" 2>/dev/null
  sed 's|/$||' "$OUT/tar.gz.members.txt" | LC_ALL=C sort | uniq -d > "$OUT/tar.gz.dups.txt"
fi

# --- the sums and the provenance -----------------------------------------------------------------
if [ -f "$DIST/SHA256SUMS" ]; then
  cat "$DIST/SHA256SUMS" > "$OUT/sha256sums.txt"
  awk '{ $1=""; sub(/^ +/, ""); print }' "$DIST/SHA256SUMS" > "$OUT/sha256sums.names.txt"
  grep -c '/' "$DIST/SHA256SUMS" > "$OUT/sha256sums.slashes.txt"
  ( cd "$DIST" && sha256sum -c SHA256SUMS ) > "$OUT/sha.verify.txt" 2>&1
  echo $? > "$OUT/sha.verify.rc"
  # The download-dir arm: relative names exist so the sums verify SOMEWHERE ELSE. Only FILES are
  # copied -- the staging tree and the rpm builder's config are not release assets.
  mkdir -p /work/dl
  : > "$OUT/sha.missing.txt"
  find "$DIST" -maxdepth 1 -type f | while read -r f; do
    n=${f##*/}
    case $n in SHA256SUMS|rpmlint.toml) continue ;; esac
    cp "$f" /work/dl/
    grep -qxF "$n" "$OUT/sha256sums.names.txt" || echo "$n" >> "$OUT/sha.missing.txt"
  done
  cp "$DIST/SHA256SUMS" /work/dl/SHA256SUMS
  ( cd /work/dl && sha256sum -c SHA256SUMS ) > "$OUT/sha.dl.txt" 2>&1
  echo $? > "$OUT/sha.dl.rc"
fi
if [ -f "$DIST/BUILD-INFO-packages.txt" ]; then
  cat "$DIST/BUILD-INFO-packages.txt" > "$OUT/buildinfo.txt"
  grep -c '^[a-z][a-z-]*: ' "$DIST/BUILD-INFO-packages.txt" > "$OUT/buildinfo.keys.txt"
fi

# --- C52 (the T4 -> T6 amendment): the Source1/rpm pair ------------------------------------------
if [ -f "$DIST/pkg/darling-lol-filelist.txt" ]; then
  grep -c '^%attr(4755,root,root) "/usr/bin/darling"$' "$DIST/pkg/darling-lol-filelist.txt" \
    > "$OUT/source1.attr4755.txt"
fi
for r in "$DIST"/darling-lol-*.rpm; do
  [ -f "$r" ] || continue
  rpm -qp --dump "$r" > "$OUT/rpm.dump.txt" 2>/dev/null
  break
done
if [ -f "$OUT/rpm.dump.txt" ]; then
  awk '$1 == "/usr/bin/darling" { print $5, $6, $7; exit }' "$OUT/rpm.dump.txt" \
    > "$OUT/rpm.dump.darling.txt"
fi

# --- G-STATIC-1's sh -n arm for the shipped shell files ------------------------------------------
shn=0
for f in packaging/arch/INSTALL packaging/common/build-arch.sh packaging/common/build-tar.sh \
  packaging/common/build-all.sh; do
  sh -n "$f" || shn=1
done
echo $shn > "$OUT/shn.rc"
exit 0
IN_CONTAINER

sec "G-ARCH-0  the build (build-all.sh fixture, one container run)"
# Run as the INVOKING user, not as root. The ownership arm (G-ARCH-4) is why: staged under root the
# fixture's files are already 0/0, so dropping build-arch.sh's --uid/--gid/--uname/--gname changes
# nothing and the 'no-fakeroot' control could not fire (measured, and the reason makepkg runs its
# packaging step under fakeroot in the first place). As the invoking user the difference is visible
# in the artifact itself: without the flags every member records that user.
"$DOCKER" run --rm -i \
  --user "$(id -u):$(id -g)" \
  -v "$SRC:/src" -v "$WORK:/work" \
  -e T6_HOST_UID="$(id -u)" -e T6_HOST_GID="$(id -g)" \
  -e T6_GATES_BREAK="$BREAK" \
  --entrypoint bash "$IMAGE" /work/in-container.sh > "$WORK/container.log" 2>&1
crc=$?
if [ "$crc" != 0 ]; then
  tail -20 "$WORK/container.log" | sed 's/^/      | /'
fi
if [ "$crc" = 5 ]; then
  printf '\n%sFATAL%s the negative control did not change the object under test.\n' "$C_ER" "$C_0" >&2
  exit 1
fi

sec "G-ARCH-0  the toolchain the rows rely on"
for t in bsdtar zstd tar gzip rpmbuild dpkg-deb; do
  printf '      %-12s %s\n' "$t" "$(val "tool-$t.txt")"
done

# ================================================================================================
sec "G-ALL  the single entry point: four formats, provenance, sums"
chk "G-ALL-0 build-all.sh fixture exits 0" "$(rc build)" "0"
chk "G-ALL-1 BUILD-INFO-packages.txt has the 9+13 = 22 keys of PLAN 12.3" \
  "$(val buildinfo.keys.txt)" "22"
sa "the .deb pair"           "$(lit inventory.txt '.deb')" "2"
sa "the .rpm pair"           "$(lit inventory.txt '.rpm')" "2"
sa "the Arch pair"           "$(lit inventory.txt '.pkg.tar.zst')" "2"
sa "the .tar.zst"            "$(lit inventory.txt 'fix.tar.zst')" "1"
sa "the .tar.gz"             "$(lit inventory.txt 'fix.tar.gz')" "1"
sa "SHA256SUMS"              "$(lit inventory.txt 'SHA256SUMS')" "1"
sa "BUILD-INFO-packages.txt" "$(lit inventory.txt 'BUILD-INFO-packages.txt')" "1"
end_row "G-ALL-2 build-all.sh fixture produced the four formats + provenance + SHA256SUMS"
sa "sums lines (fixture set)"        "$(cnt sha256sums.txt)" "9"
sa "every dist file is summed"       "$(cnt sha.missing.txt)" "0"
sa "no name holds a '/'"             "$(val sha256sums.slashes.txt)" "0"
sa "the .tar.zst is summed"          "$(lit sha256sums.names.txt 'fix.tar.zst')" "1"
sa "the .tar.gz is summed"           "$(lit sha256sums.names.txt '.tar.gz')" "1"
end_row "G-ALL-3 SHA256SUMS covers every asset"
chk "G-ALL-4 sha256sum -c SHA256SUMS in dist" "$(rc sha.verify)" "0"
chk "G-ALL-5 sha256sum -c SHA256SUMS in a download dir (relative names)" "$(rc sha.dl)" "0"
chk "G-STATIC-1 sh -n is clean on the shipped shell files" "$(rc shn)" "0"
chk "C52 the Source1 file list carries %attr(4755,root,root) \"/usr/bin/darling\"" \
  "$(val source1.attr4755.txt)" "1"
chk "C52 rpm -qp --dump shows 0104755 root root /usr/bin/darling" \
  "$(val rpm.dump.darling.txt)" "0104755 root root"

# ================================================================================================
sec "G-ARCH-1  .PKGINFO -- what libalpm refuses"
sa "runtime pkgname"  "$(lit pkginfo.runtime.txt 'pkgname = darling-lol')" "1"
sa "launcher pkgname" "$(lit pkginfo.launcher.txt 'pkgname = darling-lol-launcher')" "1"
sa "runtime arch"     "$(lit pkginfo.runtime.txt 'arch = x86_64')" "1"
sa "launcher arch"    "$(lit pkginfo.launcher.txt 'arch = any')" "1"
# FACTS:145-149: the '-' is not cosmetic, it is the difference between a package and a rejection.
sa "runtime pkgver has a '-'"  "$(num pkginfo.runtime.txt '^pkgver = [^-]*-.*$')" "1"
sa "launcher pkgver has a '-'" "$(num pkginfo.launcher.txt '^pkgver = [^-]*-.*$')" "1"
sa "runtime pkgver is 0.1.0-1" "$(lit pkginfo.runtime.txt 'pkgver = 0.1.0-1')" "1"
end_row "G-ARCH-1 .PKGINFO pkgver carries the '-' libalpm needs"
sa "runtime metadata is first"  "$(tr '\n' ' ' < "$O/pkg.first3.txt" 2>/dev/null)" ".PKGINFO .MTREE .INSTALL "
sa "launcher metadata is first" "$(tr '\n' ' ' < "$O/launcher.first3.txt" 2>/dev/null)" ".PKGINFO .MTREE usr/bin/darling-lol "
sa "the launcher has no .INSTALL" "$(lit launcher.first3.txt '.INSTALL')" "0"
end_row "G-ARCH-1 metadata first: .PKGINFO .MTREE .INSTALL"
# render.sh writes line-oriented metadata and libalpm reads it line by line: a last line without its
# newline is the kind of file that works until a reader is rewritten. Asserted on the SHIPPED
# members (the staging root's .PKGINFO is overwritten by the second package), with the same
# `tail -c1` idiom run-gates.sh uses on the tree -- command substitution strips a trailing newline
# to nothing, so "non-empty" MEANS unterminated.
unterminated() { # unterminated FILE
  [ -s "$O/$1" ] || { echo missing; return; }
  if [ -n "$(tail -c1 "$O/$1")" ]; then echo unterminated; else echo terminated; fi
}
sa "runtime .PKGINFO"  "$(unterminated pkginfo.runtime.txt)"  "terminated"
sa "launcher .PKGINFO" "$(unterminated pkginfo.launcher.txt)" "terminated"
sa "runtime .INSTALL"  "$(unterminated pkg.install.txt)"      "terminated"
end_row "G-ARCH-1 the metadata members end with a newline"
sa "one ffmpeg6 optdepend" "$(num pkginfo.runtime.txt '^optdepend = ffmpeg6: ')" "1"
sa "no ffmpeg6 depend"     "$(num pkginfo.runtime.txt '^depend = ffmpeg6')" "0"
sa "depend lines == deps.arch" "$(num pkginfo.runtime.txt '^depend = ')" \
  "$(grep -cvE '^[[:space:]]*(#|$)' "$SRC/packaging/common/deps.arch")"
sa "conflict lines == conflicts.txt" "$(num pkginfo.runtime.txt '^conflict = ')" \
  "$(grep -cvE '^[[:space:]]*(#|$)' "$SRC/packaging/common/conflicts.txt")"
sa "provides line"         "$(num pkginfo.runtime.txt '^provides = darling-lol=')" "1"
end_row "G-ARCH-1 ffmpeg6 is an optdepend (R4) and the dep lists are the reviewed ones"

sec "G-ARCH-2  .MTREE -- the setuid bit's second source"
sa ".MTREE is mtree text, not deflate" "$(num pkg.mtree.file.txt 'mtree')" "1"
sa "mode=4755 on ./usr/bin/darling" "$(num pkg.mtree.txt '^\./usr/bin/darling .*mode=4755')" "1"
sa "sha256digest on the darling line" "$(num pkg.mtree.txt '^\./usr/bin/darling .*sha256digest=')" "1"
end_row "G-ARCH-2 .MTREE records mode=4755 for ./usr/bin/darling"
sa "uid values recorded" "$(uniq_line mtree.uids.txt)" "uid=0 "
sa "gid values recorded" "$(uniq_line mtree.gids.txt)" "gid=0 "
end_row "G-ARCH-2 .MTREE records root ownership (no builder uid)"

sec "G-ARCH-3  the member list is a list, never a word-split"
sa "runtime members == files.runtime + 3 metadata" "$(cnt pkg.members.txt)" \
  "$(($(val files-runtime.count.txt) + 3))"
sa "launcher members == files.launcher + 2 metadata" "$(cnt launcher.members.txt)" \
  "$(($(val files-launcher.count.txt) + 2))"
sage "space paths survive (>= files.runtime's)" "$(val pkg.space.txt)" "$(val files-runtime.space.txt)"
sage "%-paths survive"  "$(val pkg.percent.txt)" "4"
end_row "G-ARCH-3 the member list never went through word splitting"
sa "C18 overlap between the two packages" "$(cnt pkg.overlap.txt)" "0"
end_row "G-ARCH-3 the two Arch packages claim no common path (C18)"

sec "G-ARCH-4  ownership: makepkg's fakeroot, made explicit"
sa "owner triples"  "$(uniq_line pkg.owners.txt)" "0/root/root "
sa "setuid members" "$(uniq_line pkg.setuid.txt)" "usr/bin/darling "
end_row "G-ARCH-4 every member is 0/root/root"

# ================================================================================================
sec "G-TAR  the release tarballs"
sa "zst member count == files.all" "$(cnt tar.zst.members.txt)" "$(val files-all.count.txt)"
sa "gz member count == files.all"  "$(cnt tar.gz.members.txt)"  "$(val files-all.count.txt)"
sa "no absolute member name"       "$(val tar.absolute.txt)" "0"
sa "a payload member is present"   "$(lit tar.zst.members.txt 'usr/bin/darlingserver')" "1"
sa "the setuid mode survived"      "$(num tar.zst.tv.txt '^-rwsr-xr-x 0/0 .* usr/bin/darling$')" "1"
sage "space paths"                 "$(val tar.space.txt)" "2"
sage "%-paths"                     "$(val tar.percent.txt)" "4"
end_row "G-TAR-3 the tarball holds the payload, not the host's /usr (C43-a)"
sa "duplicates (zst)" "$(cnt tar.zst.dups.txt)" "0"
sa "duplicates (gz)"  "$(cnt tar.gz.dups.txt)" "0"
end_row "G-TAR-2 no duplicate member in either tarball (C2)"

sec "G-ARCH-5  the pacman hook (PLAN 11.3, R11)"
sage "the hook is shipped"  "$(cnt pkg.install.txt)" "20"
sa "no exit 1 statement in the hook" "$(val pkg.install.exit1.txt)" "0"
sa "post_install defined"   "$(lit pkg.install.txt 'post_install()')" "1"
sa "post_upgrade defined"   "$(lit pkg.install.txt 'post_upgrade()')" "1"
sa "post_remove defined"    "$(lit pkg.install.txt 'post_remove()')" "1"
sa "it reports on stderr"   "$(num pkg.install.txt 'FATAL .*>&2')" "2"
end_row "G-ARCH-5 the pacman hook reports, it never fails the transaction"

# ================================================================================================
# A disabled sweep is decided BEFORE the summary: its rows are rows of this battery, so they have to
# reach the summary's `skipped` field. A bare `note` (what this used to be) let the whole G-ARCH-6
# sweep vanish from every total -- measured: `T6_GATES_NO_CONTROLS=1 T6_GATES_QUIET=1` printed
# `24 rows: 24 passed, 0 failed` with `grep -ci 'control\|skip'` = 0 over the transcript.
#
# The sweep's row list is resolved ONCE (T6_GATES_CONTROLS=all|subset) so that the sweep and its skip
# accounting iterate the SAME list: `K skipped` is then the same K as the controls that would run.
# The knob was documented at the top of this file and never read: a subset request silently swept
# everything. Same class, one level up -- the doc promised a row and no code ran it.
sweep_rows=
for c in $CONTROL_NAMES; do
  case " ${T6_GATES_CONTROLS:-all} " in
    " all " | *" $c "*) sweep_rows="$sweep_rows $c" ;;
  esac
done
# An empty resolved list is not "no controls to run": it is an unaccountable sweep -- a typo in
# T6_GATES_CONTROLS, or a CONTROL_NAMES that lost its rows -- and the summary would then read
# "0 control(s) killed their row, 0 did not": green, with the whole proof absent. Refuse up front,
# like the T6_GATES_BREAK name check above (stderr + rc 2), because a battery that cannot say what it
# swept has nothing to report.
if [ -z "$sweep_rows" ]; then
  printf 'run-arch-gates: the control list is empty: T6_GATES_CONTROLS=%s selected no control (--list-controls)\n' \
    "${T6_GATES_CONTROLS:-all}" >&2
  exit 2
fi
sweep_skipped=0
if [ -n "$CONTROLS" ]; then
  sweep_skipped=1
  sweep_n=0
  skips0=$skips
  for c in $sweep_rows; do
    sweep_n=$((sweep_n + 1))
    skip "G-ARCH-6 control $c (the sweep is off: T6_GATES_NO_CONTROLS / T6_GATES_BREAK)"
  done
  # The `skipped` field has to be the sweep's REAL row count, so it is asserted: a constant in place
  # of the counter is the same lie in a new place. It is asserted as a DELTA (this file has no other
  # skip site today, but the assertion must not depend on that).
  [ "$((skips - skips0))" = "$sweep_n" ] \
    || no2 "the skip counter is torn: $((skips - skips0)) SKIPped for $sweep_n control row(s)"
fi

sec "SUMMARY"
# `rows` is one unambiguous thing (a row that produced a verdict): assert it, so the summary can
# never read "fewer rows than passed" (the shape run-rpm-gates.sh had, where `chk` did not count).
[ "$rows" = "$((pass + fail))" ] \
  || no2 "the row counter is torn: rows=$rows != pass+fail=$((pass + fail))"
printf '  %d rows: %s%d passed%s, %s%d failed%s, %d skipped\n' "$rows" \
  "$C_OK" "$pass" "$C_0" "$C_ER" "$fail" "$C_0" "$skips"
[ "$skips" = 0 ] \
  || printf '  %s%d row(s) SKIPped: SKIP is not PASS%s\n' "$C_SK" "$skips" "$C_0"
if [ "$fail" != 0 ]; then
  printf '\n%sFAILED%s -- %d row(s) red. A red row here is a red gate: fix the object, not the row.\n' \
    "$C_ER" "$C_0" "$fail" >&2
  exit 1
fi
[ "$sweep_skipped" = 0 ] || exit 0

# ================================================================================================
# THE CONTROL SWEEP. Each one breaks the OBJECT under test in the private copy, re-runs this whole
# battery, and asserts that the row it names goes RED -- and that the break itself was not a no-op
# (a mutation that changes nothing proves nothing). A control run never sweeps (recursion guard).
sec "G-ARCH-6  the negative controls (T6_GATES_BREAK=<name>, T6_GATES_CONTROLS='$sweep_rows')"
for c in $sweep_rows; do
  ctl_rows=$((ctl_rows + 1))
  want=$(ctl_row "$c")
  log=$WORK/ctl-$c.log
  T6_GATES_BREAK="$c" T6_GATES_NO_CONTROLS=1 T6_GATES_QUIET=1 bash "$0" > "$log" 2>&1
  cret=$?
  if grep -q 'BREAK-NOOP\|BREAK-UNKNOWN' "$log"; then
    ctl_no "control $c: the mutation itself is broken (see the log above)"
  elif [ "$cret" = 0 ]; then
    ctl_no "control $c: the battery still passed with the object broken"
  elif ! grep -qF "FAIL $want" "$log"; then
    ctl_no "control $c: '$want' did not go red"
    grep -F 'FAIL' "$log" | sed 's/^/      | /'
  else
    ctl_ok=$((ctl_ok+1))
    [ -n "$QUIET" ] || printf '  %sPASS%s control %-16s -> %s went red\n' "$C_OK" "$C_0" "$c" "$want"
  fi
done
# The sweep's own total is asserted the same way as the gate rows': k control names were declared,
# so ctl_ok + ctl_bad must be k. A control row that vanishes is exactly the defect this file fixes.
if [ "$((ctl_ok + ctl_bad))" != "$ctl_rows" ]; then
  printf '  %sFAIL%s the sweep counter is torn: %d of %d control(s) reported\n' \
    "$C_ER" "$C_0" "$((ctl_ok + ctl_bad))" "$ctl_rows"
  printf '\n%sFAILED%s -- the control sweep cannot account for its own rows.\n' "$C_ER" "$C_0" >&2
  exit 1
fi
printf '\n%d control(s) killed their row, %s%d did not%s\n' \
  "$ctl_ok" "$C_ER" "$ctl_bad" "$C_0"
if [ "$ctl_bad" != 0 ]; then
  printf '\n%sFAILED%s -- %d control(s) did not kill their row: a gate without a control is a ghost row.\n' \
    "$C_ER" "$C_0" "$ctl_bad" >&2
  exit 1
fi
exit 0
