#!/usr/bin/env bash
# packaging/testdata/run-rpm-gates.sh -- T4's gate battery: PLAN 10's G-RPM-1..4, the TASKS.md T4
# acceptance rows, and TASKS.md T4's mutation table -- self-contained, ASSERTING and hermetic.
#
#   bash packaging/testdata/run-rpm-gates.sh
#
# WHAT IT IS. Every row asserts an exit code AND the text that came with it; a row that cannot be
# made to fail is not a row. The object under test is a byte-identical copy of `packaging/` in one
# private `mktemp -d` (asserted with `diff -r`), so the negative controls break the object without
# touching the repo, and nothing else is read: no `dist/`, no state from an earlier run.
#
# WHY A CONTAINER. There is no rpm on this box at all -- rpm, rpmbuild, rpmspec and rpmlint are
# absent on Ubuntu/arm64 (measured) -- and `build-rpm.sh` refuses to run without rpmbuild. PLAN
# 10.3 pins `fedora:41` for everything that needs the toolchain, so the battery hands the copy to
# one container run that MEASURES (build, query, collect) while every assertion is made here, on
# the artifacts it collected.
#
#   T4_RPM_IMAGE=<image>      default `fedora:41`. A bare image pays `dnf -y install rpm-build
#                             rpmlint` on every one of the (1 + N controls) container runs; to pay
#                             it once, build the gate image the T4 report used:
#
#       docker build -t darling-rpm-gates:fc41 - <<'EOF'
#       FROM fedora:41
#       RUN dnf -y install rpm-build rpmlint xz diffutils binutils && dnf clean all
#       EOF
#       T4_RPM_IMAGE=darling-rpm-gates:fc41 bash packaging/testdata/run-rpm-gates.sh
#
#                             binutils is what the G-RPM-5 witness needs (as/ld/objdump); the
#                             fedora:41 tag satisfies it through rpm-build's own dependencies.
#   T4_GATES_BREAK=<name>     negative-control hook: break the OBJECT under test and re-run (see
#                             the bottom of this file). Unset in a normal run.
#   T4_GATES_CONTROLS=<spec>  `all` (default) or a space-separated subset of the control names.
#   T4_GATES_NO_CONTROLS=1    skip the control sweep. The gate rows are unchanged; the sweep is the
#                             proof they can go red, so it is ON by default.
#   T4_GATES_QUIET=1          print only the rows that are not PASS (what the sweep reads).
#   T4_GATES_KEEP=1           keep and print the private work directory, for a red row that needs
#                             its artifacts inspected.
#
# ARCHITECTURE. The shipped runtime spec pins `ExclusiveArch: x86_64` because that is the payload's
# architecture, and rpmbuild refuses a foreign arch outright. On a host that cannot build x86_64
# the battery still runs the whole hostile-shape fixture: `build-rpm.sh` rewrites that single line
# for the FIXTURE only, loudly, and this battery asserts both halves (the shipped render keeps
# x86_64, and the knob may not touch any other line).
#
# `sh run-rpm-gates.sh` (= dash here) would die on the first bashism, AFTER printing part of the
# table -- which a careless runner reads as "mostly green". Refuse up front instead, in a form dash
# can parse, so that the message is the output (same defence as run-gates.sh).
case "${BASH_VERSION:-}" in
  "") echo "run-rpm-gates: run me with bash: bash $0" >&2; exit 2 ;;
esac
set -u

if [ ! -f packaging/common/build-rpm.sh ] || [ ! -f packaging/rpm/darling-lol.spec.in ] \
   || [ ! -f packaging/rpm/darling-lol-launcher.spec.in ] || [ ! -f packaging/rpm/rpmlint.toml ]; then
  echo "run-rpm-gates: run me from the repo root, with packaging/rpm/ present" >&2
  exit 2
fi

CONTROL_NAMES="post-mode-target unquote-list autoreqprov dir-drop attr-weaken \
token-inline launcher-autoreq deps-drop comment-macro arch-spelling stage-break \
witness-autoreq escape-inert payload-elf"
# every control names the row it must turn red; the sweep asserts THAT row fails, that the child
# run fails at all, and that the break itself was not a no-op.
ctl_row() {
  case $1 in
    post-mode-target) echo "G-RPM-3 the %post scriptlet expands %a and the install reaches the mldr assert" ;;
    unquote-list)     echo "the runtime %files list is stage.sh's quoted list, byte-for-byte" ;;
    autoreqprov)      echo "G-RPM-1 the rendered spec pins AutoReqProv: no and states the deviation" ;;
    dir-drop)         echo "G-RPM-2 every files.emptydirs entry is owned as a directory (%dir)" ;;
    attr-weaken)      echo "G-RPM-2 the hardened modes come from %attr, not from the payload" ;;
    token-inline)     echo "G-RPM-3 the rendered Requires: token stands alone (no double prefix)" ;;
    launcher-autoreq) echo "G-RPM-5 the auto-reqprov sensor is live on this toolchain (launcher interp)" ;;
    deps-drop)        echo "G-RPM-3 the requires are exactly the reviewed list" ;;
    comment-macro)    echo "G-RPM-1 rpmspec -P: rc=0, non-empty parse, EMPTY stderr" ;;
    arch-spelling)    echo "G-RPM-1 the shipped render pins ExclusiveArch: x86_64, not BuildArch" ;;
    stage-break)      echo "G-RPM-2 rpmbuild -bb builds exactly the two packages" ;;
    witness-autoreq)  echo "G-RPM-5 C11 witness: the sonotype is absent under AutoReqProv: no" ;;
    escape-inert)     echo "G-RPM-5 the %a mutation of TASKS.md T4 is inert on this toolchain" ;;
    payload-elf)      echo "G-RPM-5 the auto-reqprov sensor is live on this toolchain (launcher interp)" ;;
    *)                echo "" ;;
  esac
}

case ${1:-} in
  -h | --help)
    sed -n '2,43p' "$0"
    exit 0
    ;;
  --list-controls)
    for c in $CONTROL_NAMES; do printf '%s\n' "$c"; done
    exit 0
    ;;
  "") : ;;
  *) echo "run-rpm-gates: unknown argument '$1' (try --help)" >&2; exit 2 ;;
esac

BREAK=${T4_GATES_BREAK:-}
IMAGE=${T4_RPM_IMAGE:-fedora:41}
CONTROLS=${T4_GATES_NO_CONTROLS:-}
if [ -n "$BREAK" ]; then
  case " $CONTROL_NAMES " in
    *" $BREAK "*) : ;;
    *) echo "run-rpm-gates: T4_GATES_BREAK='$BREAK' is not a control (--list-controls)" >&2; exit 2 ;;
  esac
  CONTROLS=1 # a broken run never sweeps: that is the recursion guard
fi
QUIET=${T4_GATES_QUIET:-}

WORK=$(mktemp -d "${TMPDIR:-/tmp}/darling-t4-rpm.XXXXXX")
O=$WORK/out
SRC=$WORK/src
HOSTDIST=$WORK/hostdist
HO=$WORK/hostout        # the host render only: the container wipes $O, so keep it out of the way

# The container runs as root, so everything it writes into the bind mount is root-owned and the
# cleanup below would fail without help: it chowns /work on the way out, and if it died too early
# this fallback removes the tree from inside a container instead of leaving junk in $TMPDIR.
cleanup_work() {
  if [ -n "${T4_GATES_KEEP:-}" ]; then
    printf 'run-rpm-gates: kept %s (T4_GATES_KEEP)\n' "$WORK" >&2
    return 0
  fi
  [ -d "$WORK" ] || return 0
  rm -rf "$WORK" 2>/dev/null && return 0
  if [ -n "${DOCKER:-}" ]; then
    "$DOCKER" run --rm -v "$WORK:/work" --entrypoint sh "$IMAGE" -c 'rm -rf /work' >/dev/null 2>&1
  fi
  rm -rf "$WORK" 2>/dev/null \
    || printf 'run-rpm-gates: could not remove %s (the container left root-owned files)\n' "$WORK" >&2
}
trap cleanup_work EXIT HUP INT TERM

# ------------------------------------------------------------------------------------------------
# Colour only for a terminal: redirected output (CI logs, the control sweep's own greps) is plain
# text, so what the sweep reads is what the reader sees.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_OK=$'\033[32m'; C_ER=$'\033[31m'; C_SK=$'\033[33m'; C_B=$'\033[1m'; C_0=$'\033[0m'
else
  C_OK=; C_ER=; C_SK=; C_B=; C_0=
fi
rows=0; pass=0; fail=0; skips=0
ROWFAIL=0
ok()   { pass=$((pass+1)); [ -n "$QUIET" ] || printf '  %sPASS%s %s\n' "$C_OK" "$C_0" "$1"; }
no()   { fail=$((fail+1)); printf '  %sFAIL%s %s\n' "$C_ER" "$C_0" "$1"; }
sk()   { skips=$((skips+1)); printf '  %sSKIP%s %s\n' "$C_SK" "$C_0" "$1"; }
chk() { # chk LABEL GOT WANT
  if [ -z "$2" ]; then no "$1: EMPTY result (command failed)"
  elif [ "$2" = "$3" ]; then ok "$1 ($2)"
  else no "$1: got '$2', want '$3'"; fi
}
sec()  { [ -n "$QUIET" ] || printf '\n%s%s%s\n' "$C_B" "$1" "$C_0"; }
sa() { # sa LABEL GOT WANT -- a row fails when any sub-assert fails
  if [ -z "$2" ]; then ROWFAIL=1; [ -n "$QUIET" ] || printf '      FAIL %s: EMPTY (command failed)\n' "$1"
  elif [ "$2" = "$3" ]; then [ -n "$QUIET" ] || printf '      %sok%s %s (%s)\n' "$C_OK" "$C_0" "$1" "$2"
  else ROWFAIL=1; printf '      FAIL %s: got %s, want %s\n' "$1" "$2" "$3"; fi
}
end_row() { # end_row LABEL
  rows=$((rows+1))
  if [ "$ROWFAIL" = 0 ]; then pass=$((pass+1)); [ -n "$QUIET" ] || printf '  %sPASS%s %s\n' "$C_OK" "$C_0" "$1"
  else fail=$((fail+1)); printf '  %sFAIL%s %s\n' "$C_ER" "$C_0" "$1"; fi
  ROWFAIL=0
}
val()  { [ -f "$O/$1" ] && cat "$O/$1"; }                 # an artifact, or empty
cnt()  { if [ -f "$O/$1" ]; then wc -l < "$O/$1" | tr -d ' '; else echo missing; fi; }
num()  { # num FILE ERE -- how many lines of the artifact match the extended regex
  if [ -f "$O/$1" ]; then c=$(grep -c -E -- "$2" "$O/$1"); printf '%s' "${c:-0}"; else echo missing; fi
}
lit()  { # lit FILE STRING -- how many lines contain the fixed string
  if [ -f "$O/$1" ]; then c=$(grep -c -F -- "$2" "$O/$1"); printf '%s' "${c:-0}"; else echo missing; fi
}
field() { # field FILE NAME -- the deptype field of the FIRST NAME row of a 'NAME|DEPTYPE' artifact
  if [ -f "$O/$1" ]; then awk -F'|' -v n="$2" '$1 == n { print $2; exit }' "$O/$1"; fi
}
subdep() { # subdep FILE SUBSTR -- 1 when a requires row whose NAME contains SUBSTR has an auto deptype
  if [ -f "$O/$1" ]; then
    awk -F'|' -v s="$2" 'index($1, s) > 0 && $2 ~ /(^|,)auto($|,)/ { c++ } END { print c+0 }' "$O/$1"
  else echo missing; fi
}
depauto() { # depauto FILE [NAME] -- count of 'auto' deptypes (for NAME when given)
  if [ -f "$O/$1" ]; then
    awk -F'|' -v n="${2-}" '$2 ~ /(^|,)auto($|,)/ && (n == "" || $1 == n) { c++ } END { print c+0 }' "$O/$1"
  else echo missing; fi
}
rc()   { if [ -f "$O/$1.rc" ]; then cat "$O/$1.rc"; else echo missing; fi; }

# ================================================================================================
sec "G-RPM-0  the object under test, the container, and the build"

mkdir -p "$SRC"
cp -a packaging "$SRC/packaging"
cp -a LICENSE NOTICE.md "$SRC/" 2>/dev/null || :
chk "the object under test is a byte-identical copy of packaging/" \
  "$(diff -r packaging "$SRC/packaging" >/dev/null 2>&1 && echo same || echo differs)" "same"

DOCKER=
for d in docker podman; do command -v "$d" >/dev/null 2>&1 && { DOCKER=$d; break; }; done
if [ -z "$DOCKER" ]; then
  sk "no docker/podman: every G-RPM row needs the container's toolchain (PLAN 10.3)"
  printf '\n%sFATAL%s no container runtime: 0 of the G-RPM rows can run on this box.\n' "$C_ER" "$C_0" >&2
  exit 1
fi
if ! "$DOCKER" info >/dev/null 2>&1; then
  sk "$DOCKER present but its daemon is not reachable ($DOCKER info failed)"
  printf '\n%sFATAL%s %s daemon unreachable: 0 of the G-RPM rows can run.\n' "$C_ER" "$C_0" "$DOCKER" >&2
  exit 1
fi
chk "container runtime" "$DOCKER" "$DOCKER"

# The shipped render, on THIS box, with no rpm toolchain at all: run before the container so a box
# with no rpm still proves what CI will ship -- and prove the shipped arch is x86_64 while the
# fixture is free to be rewritten. --render-only stops after step 7 (specs + sources, no rpmbuild).
mkdir -p "$O" "$HO" "$HOSTDIST"
( cd "$SRC" && DARLING_PKG_DIST="$HOSTDIST" sh packaging/common/build-rpm.sh fixture --render-only ) \
  > "$HO/host-render.log" 2>&1
echo $? > "$HO/host-render.rc"
cp "$HOSTDIST/pkg/rpmbuild/SPECS/darling-lol.spec"          "$HO/spec-host-runtime.txt"  2>/dev/null || :
cp "$HOSTDIST/pkg/rpmbuild/SPECS/darling-lol-launcher.spec" "$HO/spec-host-launcher.txt" 2>/dev/null || :

# ------------------------------------------------------------------------------------------------
# the container half: generated here, MEASURES only, every assertion stays in this file
cat > "$WORK/in-container.sh" <<'IN_CONTAINER'
#!/bin/bash
# in-container.sh -- the container half of packaging/testdata/run-rpm-gates.sh: it MEASURES, the
# harness ASSERTS. /src is the battery's byte-identical copy of packaging/ (writable, so a negative
# control can break the object under test without touching the repo); /work is its scratch; every
# artifact lands in /work/out, and this file reads nothing it did not write.
set -u
export LC_ALL=C

# The bind mount is the host's $TMPDIR tree and this process is root: chown on the way out so the
# harness can clean up after itself (it is the host user who has to remove it).
chown_work() {
  [ -n "${T4_HOST_UID:-}" ] || return 0
  chown -R "$T4_HOST_UID:${T4_HOST_GID:-0}" /work 2>/dev/null || :
}
trap chown_work EXIT

OUT=/work/out
DIST=/work/dist
SRC=/src
rm -rf "$OUT" "$DIST" /work/shipped /work/witness /work/rpmdb
mkdir -p "$OUT"

printf '%s\n' "$(uname -m)" > "$OUT/uname-m.txt"
rpm --version > "$OUT/rpm-version.txt" 2>&1
for t in rpmbuild rpmspec rpmlint as ld objdump; do
  if command -v "$t" >/dev/null 2>&1; then "$t" --version 2>&1 | head -1 > "$OUT/tool-$t.txt"
  else echo absent > "$OUT/tool-$t.txt"; fi
done

# The fixture must be buildable HERE: the shipped runtime spec pins ExclusiveArch x86_64 and
# rpmbuild refuses a foreign arch outright. The knob is fixture-only (build-rpm.sh ignores it for a
# TAG build), it rewrites exactly one line, and the battery asserts the shipped render separately.
arch=$(uname -m)
case $arch in x86_64) fixarch= ;; *) fixarch=$arch ;; esac
printf '%s\n' "${fixarch:--}" > "$OUT/fixture-arch.txt"
export RPM_FIXTURE_ARCH=$fixarch

# --- the negative-control hook: break the OBJECT, and prove the break is real -------------------
BRK=${T4_GATES_BREAK:-}
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
  "") ;;
  post-mode-target) break_one "$SRC/packaging/rpm/darling-lol.spec.in" 's|mode=$(stat -c .%%a. %{_bindir}/darling|mode=$(stat -c .%%a. %{_bindir}/darlingserver|' ;;
   escape-inert) ;; # not a source mutation: it un-sets the %a probe's switch, below
  unquote-list) break_one "$SRC/packaging/common/build-rpm.sh" 's/if (!(t in skip)) print }/if (!(t in skip)) print t }/' ;;
  autoreqprov)  break_one "$SRC/packaging/rpm/darling-lol.spec.in" 's/^AutoReqProv:    no$/AutoReqProv:    yes/' ;;
  dir-drop)     break_one "$SRC/packaging/common/build-rpm.sh" 's|done < "$pkg/files.emptydirs" > "$tmp/block.emptydirs"|done < /dev/null > "$tmp/block.emptydirs"|' ;;
  attr-weaken)  break_one "$SRC/packaging/common/build-rpm.sh" 's#darling|%{_bindir}/darling|4755#darling|%{_bindir}/darling|0755#; s#server|%{_bindir}/darlingserver|0755#server|%{_bindir}/darlingserver|0644#' ;;
  token-inline) break_one "$SRC/packaging/rpm/darling-lol.spec.in" 's|^@RPM_REQUIRES@$|Requires:       @RPM_REQUIRES@|' ;;
  launcher-autoreq) break_one "$SRC/packaging/rpm/darling-lol-launcher.spec.in" 's|^Name:           darling-lol-launcher$|Name:           darling-lol-launcher\nAutoReqProv:    no|' ;;
  deps-drop)    break_one "$SRC/packaging/common/deps.rpm.fc41" '/^fuse-libs$/d' ;;
  comment-macro) break_one "$SRC/packaging/rpm/darling-lol.spec.in" 's/%%{_docdir}/%{_docdir}/' ;;
  arch-spelling) break_one "$SRC/packaging/rpm/darling-lol.spec.in" 's/^ExclusiveArch:  x86_64$/BuildArch:      x86_64/' ;;
  stage-break)  break_one "$SRC/packaging/common/stage.sh" '/^#!/a exit 9' ;;
  payload-elf)  break_one "$SRC/packaging/testdata/mkprefixfixture.sh" \
                  's|> "$_g/usr/lib/libguest.bin"$|> /dev/null; cp /usr/bin/rpm "$_g/usr/lib/libguest.bin"|' ;;
  witness-autoreq) ;; # not a source mutation: it un-sets the witness's own switch, below
  *) echo "BREAK-UNKNOWN: $BRK"; exit 4 ;;
esac

# --- 1. the production path: fixture = mkfixture.sh -> stage.sh -> render.sh -> rpmbuild ---------
cd /work
export DARLING_PKG_DIST="$DIST"
sh "$SRC/packaging/common/build-rpm.sh" fixture > "$OUT/build.log" 2>&1
echo $? > "$OUT/build.rc"

# --- 2. the same render with the knob OFF: what CI ships, provable here with no rpmbuild --------
RPM_FIXTURE_ARCH= DARLING_PKG_DIST=/work/shipped \
  sh "$SRC/packaging/common/build-rpm.sh" fixture --render-only > "$OUT/renderonly.log" 2>&1
echo $? > "$OUT/renderonly.rc"

# --- 3. collect: specs, the stage.sh products, the packages, the config -------------------------
# The runtime spec is darling-lol.spec, not darling-lol-runtime.spec: spell both names out.
cp "$DIST/pkg/rpmbuild/SPECS/darling-lol.spec"          "$OUT/spec-runtime.txt" 2>/dev/null || :
cp "$DIST/pkg/rpmbuild/SPECS/darling-lol-launcher.spec" "$OUT/spec-launcher.txt" 2>/dev/null || :
cp /work/shipped/pkg/rpmbuild/SPECS/darling-lol.spec          "$OUT/spec-shipped-runtime.txt"  2>/dev/null || :
cp /work/shipped/pkg/rpmbuild/SPECS/darling-lol-launcher.spec "$OUT/spec-shipped-launcher.txt" 2>/dev/null || :
for f in files.runtime files.quoted files.launcher files.emptydirs \
         darling-lol-filelist.txt darling-lol-launcher-filelist.txt; do
  cp "$DIST/pkg/$f" "$OUT/stage-$f" 2>/dev/null || :
done
cp "$SRC/packaging/common/deps.rpm.fc41" "$OUT/deps.txt" 2>/dev/null || :
cp "$SRC/packaging/common/conflicts.txt" "$OUT/conflicts.txt" 2>/dev/null || :
cp "$SRC/packaging/rpm/rpmlint.toml"     "$OUT/rpmlint-config.toml" 2>/dev/null || :
stat -c '%a %U %G %n' \
  "$DIST/pkg/root/usr/bin/darling" \
  "$DIST/pkg/root/usr/bin/darlingserver" \
  "$DIST/pkg/root/usr/libexec/darling/usr/bin/write" > "$OUT/staged-modes.txt" 2>&1
# Why the runtime half of C11 is a text row: swept over the WHOLE staged root, not one file. Not a
# single staged file has a dynamic section (objdump -p finds 0 DT_NEEDED everywhere), and the only
# two files carrying the ELF magic are guest stubs with no soname inside them -- so rpmbuild's
# elfdeps generator has nothing to turn into a requirement (T4 report F3, evidence C11).
find "$DIST/pkg/root" -type f | sed "s|^$DIST/pkg/root/||" | LC_ALL=C sort > "$OUT/staged-root-files.txt"
: > "$OUT/payload-elf.txt"
while read -r p; do
  printf '%s %s %s\n' "$p" \
    "$(od -An -c -N4 "$DIST/pkg/root/$p" 2>/dev/null | tr -d ' \n')" \
    "$(objdump -p "$DIST/pkg/root/$p" 2>/dev/null | grep -c NEEDED)" >> "$OUT/payload-elf.txt"
done < "$OUT/staged-root-files.txt"
mkdir -p "$OUT/rpms"
cp "$DIST"/*.rpm "$OUT/rpms/" 2>/dev/null || :
ls -1 "$OUT/rpms" > "$OUT/rpms.txt" 2>/dev/null || :
RT=$(ls "$OUT"/rpms/darling-lol-[0-9]*.rpm 2>/dev/null | head -1)
LT=$(ls "$OUT"/rpms/darling-lol-launcher-[0-9]*.rpm 2>/dev/null | head -1)
printf '%s\n' "${RT##*/}" > "$OUT/rpm-runtime.txt"
printf '%s\n' "${LT##*/}" > "$OUT/rpm-launcher.txt"

# --- 4. the metadata queries --------------------------------------------------------------------
if [ -n "$RT" ]; then
  rpm -qp --dump       "$RT" > "$OUT/dump-runtime.txt"       2>&1; echo $? > "$OUT/dump-runtime.rc"
  rpm -qp --list       "$RT" > "$OUT/list-runtime.txt"       2>&1; echo $? > "$OUT/list-runtime.rc"
  rpm -qp --requires   "$RT" > "$OUT/requires-runtime.txt"   2>&1; echo $? > "$OUT/requires-runtime.rc"
  rpm -qp --recommends "$RT" > "$OUT/recommends-runtime.txt" 2>&1; echo $? > "$OUT/recommends-runtime.rc"
  rpm -qp --conflicts  "$RT" > "$OUT/conflicts-runtime.txt"  2>&1; echo $? > "$OUT/conflicts-runtime.rc"
  rpm -qp --scripts    "$RT" > "$OUT/scripts-runtime.txt"    2>&1; echo $? > "$OUT/scripts-runtime.rc"
  rpm -qp --filecaps   "$RT" > "$OUT/filecaps-runtime.txt"   2>&1; echo $? > "$OUT/filecaps-runtime.rc"
  rpm -qp --qf '[%{REQUIRENAME}\n]' "$RT"                         > "$OUT/reqnames-runtime.txt" 2>&1
  rpm -qp --qf '[%{REQUIRENAME}|%{REQUIREFLAGS:deptype}\n]' "$RT" > "$OUT/deptypes-runtime.txt" 2>&1
  rpm -qp --qf '%{NAME}|%{VERSION}|%{RELEASE}|%{ARCH}|%{PAYLOADCOMPRESSOR}|%{PAYLOADFLAGS}\n' "$RT" \
      > "$OUT/qf-runtime.txt" 2>&1
fi
if [ -n "$LT" ]; then
  rpm -qp --dump     "$LT" > "$OUT/dump-launcher.txt"     2>&1; echo $? > "$OUT/dump-launcher.rc"
  rpm -qp --list     "$LT" > "$OUT/list-launcher.txt"     2>&1
  rpm -qp --requires "$LT" > "$OUT/requires-launcher.txt" 2>&1
  rpm -qp --scripts  "$LT" > "$OUT/scripts-launcher.txt"  2>&1
  rpm -qp --qf '[%{REQUIRENAME}|%{REQUIREFLAGS:deptype}\n]' "$LT" > "$OUT/deptypes-launcher.txt" 2>&1
  rpm -qp --qf '%{NAME}|%{ARCH}|%{PAYLOADCOMPRESSOR}|%{PAYLOADFLAGS}\n' "$LT" > "$OUT/qf-launcher.txt" 2>&1
fi

# --- 5. rpmspec -P: the parse of the FACTORY render (CI runs it on the shipped one) -------------
for pair in "shipped-runtime:$OUT/spec-shipped-runtime.txt" \
            "shipped-launcher:$OUT/spec-shipped-launcher.txt" \
            "built-runtime:$OUT/spec-runtime.txt"; do
  _n=${pair%%:*}
  _s=${pair#*:}
  rpmspec -P --define "dist .fc41" "$_s" > "$OUT/rpmspec-$_n.out" 2> "$OUT/rpmspec-$_n.err"
  echo $? > "$OUT/rpmspec-$_n.rc"
done
# the plan's G-RPM-1d/-1e shapes, measured on the shipped render
rpmspec -q --requires --define "dist .fc41" "$OUT/spec-shipped-runtime.txt" \
  > "$OUT/rpmspec-req.out" 2> "$OUT/rpmspec-req.err"
echo $? > "$OUT/rpmspec-req.rc"

# --- 5b. C43-n: the two comment traps are DIFFERENT traps, measured on one spec -----------------
# The spec's header comment claims WHICH spelling warns inside a comment. One comment line carries
# only a bare, undefined %a; the next carries only the braced spelling of a DEFINED macro. If the
# warning were per-comment-line rather than per-macro, both lines would warn -- they must not.
cat > "$OUT/cmt-bare.spec" <<'SPEC'
# only a bare, undefined %a in this comment
# only the braced spelling of a defined macro in this comment: %{_docdir}
%global __os_install_post %{nil}
Name:           cmt
Version:        1
Release:        1
Summary:        comment macro probe
License:        MIT
%description
d.
%files
%dir /usr/share/cmt
SPEC
rpmspec -P "$OUT/cmt-bare.spec" > "$OUT/cmt-bare.out" 2> "$OUT/cmt-bare.err"
echo $? > "$OUT/cmt-bare.rc"

# --- 6. rpmlint: with the config, with the plan's literal --file, and with none -----------------
if command -v rpmlint >/dev/null 2>&1 && [ -n "$RT" ] && [ -n "$LT" ]; then
  rpmlint -c "$OUT/rpmlint-config.toml" "$RT" "$LT"     > "$OUT/rpmlint-cfg.txt"   2>&1; echo $? > "$OUT/rpmlint-cfg.rc"
  rpmlint --file "$OUT/rpmlint-config.toml" "$RT" "$LT" > "$OUT/rpmlint-file.txt"  2>&1; echo $? > "$OUT/rpmlint-file.rc"
  rpmlint "$RT" "$LT"                                   > "$OUT/rpmlint-nocfg.txt"  2>&1; echo $? > "$OUT/rpmlint-nocfg.rc"
else
  for n in cfg file nocfg; do : > "$OUT/rpmlint-$n.txt"; echo 127 > "$OUT/rpmlint-$n.rc"; done
fi

# --- 7. install it: the %post has to run, the modes have to survive extraction, and the empty ---
#        dirs (%dir) have to leave with the package -------------------------------------------------
if [ -n "$RT" ]; then
  mkdir -p /work/rpmdb
  rpm -i --nodeps --dbpath /work/rpmdb "$RT" > "$OUT/install.out" 2> "$OUT/install.err"
  echo $? > "$OUT/install.rc"
  stat -c '%a %U %G %n' /usr/bin/darling > "$OUT/installed-mode.txt" 2>&1
  for d in /usr/libexec/darling/private/tmp "/usr/libexec/darling/System/Library/User Template"; do
    [ -e "$d" ] && echo "present $d" || echo "absent $d"
  done > "$OUT/installed-dirs.txt"
  rpm -e --nodeps --dbpath /work/rpmdb darling-lol > "$OUT/erase.log" 2>&1
  echo $? > "$OUT/erase.rc"
  for d in /usr/libexec/darling/private/tmp "/usr/libexec/darling/System/Library/User Template"; do
    [ -e "$d" ] && echo "present $d" || echo "absent $d"
  done > "$OUT/erased-dirs.txt"
fi

# --- 8. the C11 witness: does THIS rpmbuild auto-generate a soname requirement at all? ----------
# The T1 fixture's payload is hostile in shape but carries no real ELF (mkfixture's stand-ins have
# the magic and nothing else), so flipping the runtime spec to AutoReqProv: yes changes NOTHING
# there -- measured. This witness answers what the plan's mutation row 3 is really about: rpmbuild
# 4.20.1 DOES turn an ELF's DT_NEEDED into `libavcodec.so.60()(64bit)` when the switch is on, and
# the switch is what suppresses it. It packages an ELF this script builds with binutils, in the
# harness's own scratch: it probes the toolchain, it is never a second build path for T4's
# artifacts (PLAN 10.3's build command is the only one that builds darling-lol).
WIT=/work/witness
mkdir -p "$WIT/SOURCES" "$WIT/pkg"
printf '    .globl wit\nwit:\n    nop\n' > "$WIT/w.s"
as -o "$WIT/w.o" "$WIT/w.s" > "$OUT/witness-as.txt" 2>&1
echo $? >> "$OUT/witness-as.txt"
ld -shared -soname libavcodec.so.60 -o "$WIT/libavcodec.so.60" "$WIT/w.o"  > "$OUT/witness-ld.txt" 2>&1
ld -shared -o "$WIT/libwitness.so.1" "$WIT/w.o" "$WIT/libavcodec.so.60"   >> "$OUT/witness-ld.txt" 2>&1
objdump -p "$WIT/libwitness.so.1" | grep -E 'NEEDED|SONAME' > "$OUT/witness-objdump.txt" 2>&1
cp "$WIT/libwitness.so.1" "$WIT/SOURCES/"
for arp in no yes; do
  # the probe's own self-test: with witness-autoreq BOTH halves ask for yes, so the "absent" row
  # can be seen to be able to fail (a witness that cannot fail is not evidence).
  [ "$BRK" = witness-autoreq ] && arp=yes
  cat > "$WIT/witness-$arp.spec" <<SPEC
%global __os_install_post %{nil}
%define debug_package %{nil}
AutoReqProv:    $arp
Name:           witness-$arp
Version:        1
Release:        1
Summary:        auto-reqprov witness
License:        MIT
Source0:        libwitness.so.1
%description
Toolchain probe, not a darling-lol package.
%install
mkdir -p %{buildroot}/usr/lib64/witness
install -m 0755 %{SOURCE0} %{buildroot}/usr/lib64/witness/libwitness.so.1
%files
/usr/lib64/witness/libwitness.so.1
SPEC
  rpmbuild -bb --define "_topdir $WIT/pkg" --define "_sourcedir $WIT/SOURCES" \
    --define "dist .fc41" "$WIT/witness-$arp.spec" > "$WIT/log-$arp" 2>&1
  echo $? > "$OUT/witness-$arp.rc"
  WR=$(ls "$WIT"/pkg/RPMS/*/witness-$arp-1-1*.rpm 2>/dev/null | head -1)
  if [ -n "$WR" ]; then
    rpm -qp --qf '[%{REQUIRENAME}|%{REQUIREFLAGS:deptype}\n]' "$WR" > "$OUT/witness-$arp.requires.txt" 2>&1
  else
    : > "$OUT/witness-$arp.requires.txt"
  fi
done

# --- 9. the %a probe: TASKS.md T4's mutation row 1 says "write %a instead of %%a in %post and
#        the scriptlet prints a". Measured here instead of assumed: rpm leaves an UNDEFINED macro
#        alone, so both spellings reach the scriptlet as the same bytes. The probe builds both
#        spellings and the battery asserts the equivalence -- if a future rpm expands %a, that row
#        goes red and the spec's comment stops being defensive-only. escape-inert un-sets the probe
#        (the bare half asks for a DEFINED macro) so the row can be seen to be able to fail.
ESC=/work/escape
mkdir -p "$ESC"
for v in escaped bare; do
  if [ "$v" = escaped ]; then body='mode=$(stat -c "%%a" /usr/bin/darling)'; else body='mode=$(stat -c "%a" /usr/bin/darling)'; fi
  [ "$BRK" = escape-inert ] && [ "$v" = bare ] && body='mode=$(stat -c "%{_arch}" /usr/bin/darling)'
  cat > "$ESC/$v.spec" <<SPEC
%global __os_install_post %{nil}
%define debug_package %{nil}
Name:           esc-$v
Version:        1
Release:        1
Summary:        %a escape probe
License:        MIT
%description
Toolchain probe, not a darling-lol package.
%install
mkdir -p %{buildroot}/usr/share/esc
%post
$body
%files
%dir /usr/share/esc
SPEC
  rpmbuild -bb --define "_topdir $ESC/build-$v" --define "dist .fc41" "$ESC/$v.spec" > "$ESC/log-$v" 2>&1
  echo $? > "$OUT/escape-$v.rc"
  ER=$(ls "$ESC"/build-$v/RPMS/*/esc-$v-1-1*.rpm 2>/dev/null | head -1)
  if [ -n "$ER" ]; then
    rpm -qp --scripts "$ER" | grep '^mode=' > "$OUT/escape-$v.scriptlet.txt" 2>&1
  else
    : > "$OUT/escape-$v.scriptlet.txt"
  fi
done

echo "container: done -- rpmbuild rc $(cat "$OUT/build.rc"), $(wc -l < "$OUT/rpms.txt") package(s)"
IN_CONTAINER

[ -n "$QUIET" ] || printf '  running %s %s (one measurement run: build, queries, rpmlint, install)\n' "$DOCKER" "$IMAGE"
if ! "$DOCKER" run --rm -v "$WORK:/work" -v "$SRC:/src" \
     -e "T4_GATES_BREAK=$BREAK" -e "T4_HOST_UID=$(id -u)" -e "T4_HOST_GID=$(id -g)" \
     "$IMAGE" bash /work/in-container.sh > "$WORK/container.log" 2>&1; then
  sk "the container run did not exit 0 -- see the copy of the log in $O/container.log"
  no "G-RPM-0 the container measurement run exits 0"
  printf '    %s\n' "$(tail -5 "$WORK/container.log")"
else
  ok "G-RPM-0 the container measurement run exits 0"
fi
cp "$WORK/container.log" "$O/container.log" 2>/dev/null || :

chk "G-RPM-0 the image ran and reported its toolchain (rpm $(val rpm-version.txt))" \
  "$(if [ "$(val tool-rpmbuild.txt)" = absent ] || [ -z "$(val tool-rpmbuild.txt)" ]; then echo absent; else echo present; fi)" "present"

# A row whose input is missing can pass by accident (an empty `cmp` is still a match). Name the
# artifacts every row below reads, so a short collection is one loud row and not a quiet 0.
uncollected=
for f in build.rc spec-runtime.txt spec-shipped-runtime.txt stage-darling-lol-filelist.txt \
         stage-files.runtime stage-files.quoted stage-files.emptydirs staged-modes.txt \
         dump-runtime.txt list-runtime.txt reqnames-runtime.txt deptypes-runtime.txt \
         filecaps-runtime.txt recommends-runtime.txt installed-mode.txt witness-yes.requires.txt; do
  [ -s "$O/$f" ] || uncollected="$uncollected $f"
done
chk "G-RPM-0 the run collected every artifact the rows below read" "${uncollected:-none}" "none"
chk "G-RPM-0 the host render-only run exits 0 too" "$(cat "$HO/host-render.rc" 2>/dev/null || echo missing)" "0"

sec "G-RPM-1  rpmspec -P parses the rendered spec (PLAN 10.3, TASKS.md T4)"

sa "the shipped render is identical on this rpm-less box and inside the container" \
  "$(if [ -s "$HO/spec-host-runtime.txt" ] && [ -s "$O/spec-shipped-runtime.txt" ] && cmp -s "$HO/spec-host-runtime.txt" "$O/spec-shipped-runtime.txt"; then echo same; else echo differs; fi)" "same"
sa "the shipped render pins ExclusiveArch: x86_64, not BuildArch" \
  "$(num spec-shipped-runtime.txt '^ExclusiveArch:[[:space:]]*x86_64$')" "1"
sa "and no BuildArch line survives in it" \
  "$(num spec-shipped-runtime.txt '^BuildArch:')" "0"
sa "the launcher renders BuildArch: noarch" \
  "$(num spec-shipped-launcher.txt '^BuildArch:[[:space:]]*noarch$')" "1"
sa "no leftover @TOKEN@ in either shipped render" \
  "$(num spec-shipped-runtime.txt '@[A-Z_]+@')$(num spec-shipped-launcher.txt '@[A-Z_]+@')" "00"
sa "no un-spliced generated block (@RPM_HARDENED@ / @RPM_EMPTYDIRS@) is left" \
  "$(num spec-runtime.txt '^@RPM_HARDENED@$')$(num spec-runtime.txt '^@RPM_EMPTYDIRS@$')" "00"
end_row "G-RPM-1 the shipped render pins ExclusiveArch: x86_64, not BuildArch"

# the arch knob may only ever touch that one line: the built spec must equal the shipped one
# everywhere else, byte for byte.
sed 's/^ExclusiveArch:.*/ARCH-LINE/' "$O/spec-shipped-runtime.txt" > "$WORK/norm.shipped"
sed 's/^ExclusiveArch:.*/ARCH-LINE/' "$O/spec-runtime.txt"         > "$WORK/norm.built"
sa "the fixture arch knob rewrote exactly one line (ExclusiveArch)" \
  "$(if [ -s "$WORK/norm.shipped" ] && [ -s "$WORK/norm.built" ] && cmp -s "$WORK/norm.shipped" "$WORK/norm.built"; then echo identical; else echo differs; fi)" "identical"
sa "and it rewrote it to the build host's arch" "$(val fixture-arch.txt)" "$(val uname-m.txt)"
end_row "G-RPM-1 the fixture-only arch knob touches exactly one line of the built spec"

sa "rpmspec -P parses the shipped runtime spec" "$(rc rpmspec-shipped-runtime)" "0"
sa "rpmspec -P parses the shipped launcher spec" "$(rc rpmspec-shipped-launcher)" "0"
sa "rpmspec -P parses the BUILT runtime spec too" "$(rc rpmspec-built-runtime)" "0"
sa "the parse is not empty (an expanded spec, not 0 bytes)" \
  "$(if [ "$(wc -c < "$O/rpmspec-shipped-runtime.out" 2>/dev/null | tr -d ' ')" -gt 1000 ]; then echo yes; else echo no; fi)" "yes"
sa "rpmspec stderr is EMPTY on the runtime spec (no macro expanded in a comment, C43-m)" \
  "$(wc -c < "$O/rpmspec-shipped-runtime.err" 2>/dev/null | tr -d ' ')" "0"
sa "rpmspec stderr is EMPTY on the launcher spec" \
  "$(wc -c < "$O/rpmspec-shipped-launcher.err" 2>/dev/null | tr -d ' ')" "0"
end_row "G-RPM-1 rpmspec -P: rc=0, non-empty parse, EMPTY stderr"

sa "C43-n, one spec, two comment lines: the bare undefined %a line does NOT warn" \
  "$(rc cmt-bare)$(num cmt-bare.err 'Macro expanded in comment on line 1')" "00"
sa "while the very next line, the braced DEFINED spelling, does -- so the warning is per macro" \
  "$(num cmt-bare.err 'Macro expanded in comment on line 2')" "1"
sa "it is a warning only: the same spec still parses, rc=0" "$(rc cmt-bare)" "0"
sa "that is why the header comment escapes %%{_docdir} and leaves the bare %a unescaped" \
  "$(num cmt-bare.err 'Macro expanded in comment')" "1"
end_row "G-RPM-1 the two comment traps are different traps (C43-n)"

sa "AutoReqProv: no is in the rendered spec" "$(num spec-runtime.txt '^AutoReqProv:[[:space:]]*no$')" "1"
sa "and the header comment states the deviation from upstream, and why (C11)" \
  "$(num spec-runtime.txt 'Mach-O dependency generator')" "1"
sa "and names the sonames that exist on no RPM distro (in the header and in the Recommends note)" \
  "$(num spec-runtime.txt 'libavcodec\.so\.60')" "2"
sa "the explicit list is the rendered one, not a hand-copied string" \
  "$(num spec-runtime.txt '^Requires:[[:space:]]*glibc$')" "1"
end_row "G-RPM-1 the rendered spec pins AutoReqProv: no and states the deviation"

sec "G-RPM-2  rpmbuild -bb succeeds, and the payload metadata is the staged tree's own"

chk "G-RPM-2 rpmbuild -bb builds exactly the two packages" \
  "$(if [ "$(rc build)" = 0 ] && [ "$(cnt rpms.txt)" = 2 ]; then echo 2-rpms-rc0; else echo "rc=$(rc build) rpms=$(cnt rpms.txt)"; fi)" "2-rpms-rc0"

# the %dump of a path the payload carries 0644 is the shortest proof that the mode in the package
# is the METADATA's, not the staging tree's (PLAN 10.1's "%attr, not trusted from the payload").
sa "%dump: /usr/bin/darling is 0104755 root root" \
  "$(num dump-runtime.txt '^/usr/bin/darling .* 0104755 root root')" "1"
sa "%dump: darlingserver (payload 0644) is 0100755 -- the %attr block, not the payload" \
  "$(num dump-runtime.txt '^/usr/bin/darlingserver .* 0100755 root root')" "1"
sa "the staged payload really was 0644 for darlingserver" \
  "$(num staged-modes.txt '^644 root root .*/usr/bin/darlingserver$')" "1"
sa "%dump: the setgid guest write is 0102755 (nothing in the chain normalises modes, PLAN 13.1)" \
  "$(num dump-runtime.txt '^/usr/libexec/darling/usr/bin/write .* 0102755 root root')" "1"
end_row "G-RPM-2 the hardened modes come from %attr, not from the payload"

sa "every files.emptydirs entry is owned as a directory" \
  "$(num dump-runtime.txt '^/usr/libexec/darling/System/Library/User Template .* 040755 root root')$(num dump-runtime.txt '^/usr/libexec/darling/private/tmp .* 040755 root root')" "11"
sa "and the %dir block is generated from that list, not hand-written" \
  "$(num spec-runtime.txt '^%dir "/usr/libexec/darling/private/tmp"$')" "1"
sa "and the fixture's files.emptydirs has exactly those two entries" "$(cnt stage-files.emptydirs)" "2"
end_row "G-RPM-2 every files.emptydirs entry is owned as a directory (%dir)"

sa "the space path (User Template) round-trips" "$(num dump-runtime.txt 'User Template')" "1"
sa "the %-escaped name %21.menu round-trips" "$(num dump-runtime.txt 'Menu Extras/%21.menu')" "1"
sa "the %3d%3d%3d name round-trips" "$(num dump-runtime.txt '/usr/share/%3d%3d%3d-i.ri')" "1"
sa "the %3f name round-trips" "$(num dump-runtime.txt '/usr/share/eql%3f-i.ri')" "1"
sa "the %7c name round-trips" "$(num dump-runtime.txt '/usr/share/ipv6only%7c-i.ri')" "1"
sa "the guest write binary is owned" "$(num dump-runtime.txt '/usr/libexec/darling/usr/bin/write ')" "1"
sa "the dangling symlink is owned, with its target recorded" \
  "$(num dump-runtime.txt '/Volumes/SystemRoot/etc/machine-id$')" "1"
end_row "G-RPM-2 the %-paths, the space path and the setuid/setgid shapes round-trip"

sa "the runtime rpm is zstd-compressed at level 19T, for this host's arch" "$(val qf-runtime.txt)" \
  "darling-lol|0.1.0|1.lol.fc41|$(val uname-m.txt)|zstd|19T"
sa "the launcher rpm is zstd-compressed at level 19T too" "$(val qf-launcher.txt)" "darling-lol-launcher|noarch|zstd|19T"
sa "rpm adds the PayloadIsZstd feature requirement (an old rpm refuses it cleanly)" \
  "$(num reqnames-runtime.txt '^rpmlib\(PayloadIsZstd\)$')" "1"
sa "the payload token is the rpmio spelling, not the plan's (see the T4 report)" \
  "$(num spec-runtime.txt '^%global _binary_payload w19T.zstdio$')" "1"
end_row "G-RPM-2 the payload is zstd level 19T, pinned in the spec"

# %files -f <list>: byte-identical to what stage.sh wrote, minus the launcher's paths and minus the
# %dir block's paths -- and no re-quoting anywhere (EVIDENCE 7.2's silent corruption).
sed 's/^"//; s/"$//; s|^/||' "$O/stage-darling-lol-filelist.txt" | LC_ALL=C sort > "$WORK/fl.stripped"
sed 's/^"//; s/"$//; s|^/||' "$O/stage-files.quoted"             | LC_ALL=C sort > "$WORK/quoted.stripped"
sed 's|^/||' "$O/stage-files.runtime"   | LC_ALL=C sort > "$WORK/fr.stripped"
sed 's|^/||' "$O/stage-files.emptydirs" | LC_ALL=C sort > "$WORK/emptydirs.stripped"
sed 's|^/||' "$O/stage-files.launcher"  | LC_ALL=C sort > "$WORK/launcher.stripped"
sed 's|^/||' "$O/list-runtime.txt"       | LC_ALL=C sort > "$WORK/list.actual"
{ sed 's|^/||' "$O/stage-files.runtime"
  printf '%s\n' usr/share/doc/darling-lol/copyright usr/share/doc/darling-lol/BUILD-INFO.txt
} | LC_ALL=C sort > "$WORK/list.expected"
LC_ALL=C sort -u "$O/conflicts.txt" > "$WORK/conflicts.expected.raw"
grep -v '^#' "$WORK/conflicts.expected.raw" | grep -v '^[[:space:]]*$' | LC_ALL=C sort -u > "$WORK/conflicts.expected"
LC_ALL=C sort -u "$O/conflicts-runtime.txt" > "$WORK/conflicts.actual"
sed 's/\t.*//' "$O/filecaps-runtime.txt" | LC_ALL=C sort > "$WORK/filecaps.paths"
LC_ALL=C sort "$O/list-runtime.txt"                            > "$WORK/list.sorted"
sa "every runtime %files line is a byte-identical copy of a stage.sh line" \
  "$(LC_ALL=C comm -23 "$WORK/fl.stripped" "$WORK/quoted.stripped" | wc -l | tr -d ' ')" "0"
sa "and the runtime list is exactly files.runtime minus files.emptydirs" \
  "$( { cat "$WORK/fl.stripped"; cat "$WORK/emptydirs.stripped"; } | LC_ALL=C sort | LC_ALL=C comm -3 - "$WORK/fr.stripped" | wc -l | tr -d ' ')" "0"
sa "and it is 18 entries: 20 runtime paths minus the 2 empty dirs" \
  "$(cnt stage-darling-lol-filelist.txt)$(cnt stage-files.runtime)" "1820"
sa "every line of the runtime list is quoted (the only quoting that survives the space paths)" \
  "$(awk '!/^".*"$/' "$O/stage-darling-lol-filelist.txt" | wc -l | tr -d ' ')" "0"
sa "the launcher list is stage.sh's files.launcher, copied as-is" \
  "$(cmp -s "$O/stage-files.launcher" "$O/stage-darling-lol-launcher-filelist.txt" && echo same || echo differs)" "same"
sa "the two lists are disjoint (C18: no path is owned twice)" \
  "$(LC_ALL=C comm -12 "$WORK/fl.stripped" "$WORK/launcher.stripped" | wc -l | tr -d ' ')" "0"
sa "the runtime rpm owns exactly the staged paths plus the two %doc files %install adds" \
  "$(LC_ALL=C comm -3 "$WORK/list.expected" "$WORK/list.actual" | wc -l | tr -d ' ')" "0"
end_row "the runtime %files list is stage.sh's quoted list, byte-for-byte"

sec "G-RPM-3  the metadata a broken install would hide (requires, conflicts, caps, %post)"

{ grep -v '^#' "$O/deps.txt" | grep -v '^[[:space:]]*$'; } | LC_ALL=C sort -u > "$WORK/req.expected"
printf '%s\n' /bin/sh systemd-filesystems coreutils \
  'rpmlib(CompressedFileNames)' 'rpmlib(FileDigests)' 'rpmlib(PayloadFilesHavePrefix)' \
  'rpmlib(PayloadIsZstd)' >> "$WORK/req.expected"
LC_ALL=C sort -u -o "$WORK/req.expected" "$WORK/req.expected"
LC_ALL=C sort -u "$O/reqnames-runtime.txt" > "$WORK/req.actual"
sa "the requires are exactly deps.rpm.fc41 + the scriptlet interp + the two post requires + rpmlib" \
  "$(LC_ALL=C comm -3 "$WORK/req.expected" "$WORK/req.actual" | wc -l | tr -d ' ')" "0"
sa "the reviewed list is 27 entries" "$(grep -v '^#' "$O/deps.txt" | grep -vc '^[[:space:]]*$')" "27"
sa "and the package carries $(cnt reqnames-runtime.txt) requirement names (30 unique + 4 rpmlib)" \
  "$(LC_ALL=C sort -u "$O/reqnames-runtime.txt" | wc -l | tr -d ' ')" "34"
sa "no requirement is auto-generated: every deptype is manual/post/postun/interp/rpmlib" \
  "$(depauto deptypes-runtime.txt)" "0"
sa "the %post scriptlet interpreter is required, rpm's own" \
  "$(lit deptypes-runtime.txt '/bin/sh|post,interp')" "1"
sa "and so is the %postun one" \
  "$(lit deptypes-runtime.txt '/bin/sh|postun,interp')" "1"
sa "the plan's own query shape (G-RPM-1e): rpmspec -q --requires rc=0, 31 lines, 30 unique" \
  "$(rc rpmspec-req)$(cnt rpmspec-req.out)$(LC_ALL=C sort -u "$O/rpmspec-req.out" | wc -l | tr -d ' ')" "03130"
sa "with completely empty stderr (no comment/macro warning reaches the package-level query)" \
  "$(wc -c < "$O/rpmspec-req.err" | tr -d ' ')" "0"
sa "and at that level too no dependency is named 'Requires:' (G-RPM-1d, the C43-k shape)" \
  "$(num rpmspec-req.out '^Requires:$')" "0"
end_row "G-RPM-3 the requires are exactly the reviewed list"

sa "the rendered Requires: token stands alone, one line per entry, no double prefix" \
  "$(num spec-runtime.txt '^Requires:[[:space:]]*Requires:')" "0"
sa "and there is exactly one rendered Requires per non-comment deps entry" \
  "$(grep -c '^Requires:' "$O/spec-runtime.txt")" "27"
sa "the token line itself is gone (render.sh replaced it)" "$(num spec-runtime.txt '@RPM_REQUIRES@')" "0"
sa "and no dependency is named 'Requires:' (what the double-prefixed token really produces, C43-k)" \
  "$(num reqnames-runtime.txt '^Requires:$')" "0"
end_row "G-RPM-3 the rendered Requires: token stands alone (no double prefix)"

sa "ffmpeg-libs is a Recommends" "$(val recommends-runtime.txt)" "ffmpeg-libs"
sa "and it is NOT a Requires (R4: a hard dep would be satisfied while the runtime still fails)" \
  "$(num reqnames-runtime.txt '^ffmpeg-libs$')" "0"
sa "and the spec says why" "$(num spec-runtime.txt '^Recommends:[[:space:]]*ffmpeg-libs$')" "1"
end_row "G-RPM-3 ffmpeg-libs is Recommends, never Requires"

sa "the conflicts are exactly packaging/common/conflicts.txt" \
  "$(LC_ALL=C comm -3 "$WORK/conflicts.expected" "$WORK/conflicts.actual" | wc -l | tr -d ' ')" "0"
sa "the contract holds 21 upstream package names" "$(grep -vc '^#' "$O/conflicts.txt")" "21"
sa "and the spec consumes it: the rendered Conflicts: line starts with the file's first two" \
  "$(num spec-runtime.txt '^Conflicts:[[:space:]]*darling darling-core')" "1"
end_row "G-RPM-3 the conflicts are exactly the 21 names of packaging/common/conflicts.txt"

sa "every owned path reports an EMPTY capability set" \
  "$(awk -F'\t' 'NF > 1 && $2 != "" { n++ } END { print n+0 }' "$O/filecaps-runtime.txt")" "0"
sa "and --filecaps lists every owned path (nothing silently skipped)" \
  "$(LC_ALL=C comm -3 "$WORK/filecaps.paths" "$WORK/list.sorted" | wc -l | tr -d ' ')" "0"
sa "the spec carries no %caps() at all (EVIDENCE 7.2: it silently does not apply on -f)" \
  "$(lit spec-runtime.txt '%caps(')" "0"
end_row "G-RPM-3 no %caps() and an empty capability set for every owned path"

sa "the %post scriptlet was expanded to a real stat format (%%a -> %a)" \
  "$(lit scripts-runtime.txt "stat -c '%a' /usr/bin/darling")" "1"
sa "and it does NOT read the literal 'a' (TASKS.md T4's mutation row)" \
  "$(lit scripts-runtime.txt "stat -c 'a' /usr/bin/darling")" "0"
sa "no unexpanded %%a survives in the scriptlet" "$(lit scripts-runtime.txt '%%a')" "0"
sa "the install exits 0 (rpm reports a failed scriptlet as a warning, so the text is the assert)" \
  "$(rc install)" "0"
sa "and the scriptlet's output reaches the mldr assert, not a mode FATAL" \
  "$(if [ "$(num install.err 'FATAL')" = 1 ] && [ "$(num install.err 'FATAL .*mldr')" = 1 ] && [ "$(num install.err 'is mode')" = 0 ]; then echo mldr-only; else echo "fatal=$(num install.err 'FATAL') mode=$(num install.err 'is mode')"; fi)" "mldr-only"
sa "the mode the scriptlet read is the package's own: 4755 after extraction" \
  "$(num installed-mode.txt '^4755 root root /usr/bin/darling$')" "1"
end_row "G-RPM-3 the %post scriptlet expands %a and the install reaches the mldr assert"

sa "both empty dirs are on disk after the install" "$(num installed-dirs.txt '^present ')" "2"
sa "and both are gone after the erase (a dir that is not owned with %dir is never removed)" \
  "$(num erased-dirs.txt '^absent ')" "2"
end_row "G-RPM-3 uninstall removes the empty directories (%dir, PLAN 10.1 note 3)"

sa "the launcher has no maintainer scripts at all" \
  "$(wc -c < "$O/scripts-launcher.txt" 2>/dev/null | tr -d ' ')" "0"
sa "and requires the exact runtime build" \
  "$(num requires-launcher.txt '^darling-lol = 0\.1\.0-1\.lol\.fc41$')" "1"
end_row "G-RPM-3 the launcher carries no maintainer script"

sec "G-RPM-4  rpmlint in fedora:41 (errors fail, warnings do not)"

if [ "$(rc rpmlint-cfg)" = 127 ]; then
  sk "rpmlint is not in this image: G-RPM-4 unverified ($IMAGE)"
else
  sa "rpmlint -c exits 0" "$(rc rpmlint-cfg)" "0"
  sa "with 0 errors (13 warnings are tolerated by policy, PLAN 9.6's rule)" \
    "$(lit rpmlint-cfg.txt ' 0 errors, ')" "1"
  sa "and the two packages really were checked" \
    "$(lit rpmlint-cfg.txt '2 packages and 0 specfiles checked')" "1"
  sa "no E: line survives" "$(lit rpmlint-cfg.txt ': E: ')" "0"
  end_row "G-RPM-4 rpmlint -c: rc=0, 0 errors"

  sa "without the config rpmlint reports 26 errors and exits 64 -- the config is load-bearing" \
    "$(rc rpmlint-nocfg)$(lit rpmlint-nocfg.txt ' 26 errors, ')" "641"
  sa "and PLAN 10.3's literal --file does NOT load this TOML (same 26 errors, rc 64)" \
    "$(rc rpmlint-file)$(lit rpmlint-file.txt ' 26 errors, ')" "641"
  end_row "G-RPM-4 the config is the difference between 26 errors and 0 (--file cannot load it)"

  if command -v python3 >/dev/null 2>&1; then
    # every filter must still match something, and together they must explain every error the
    # no-config run reports: a dead filter would be a lie in the config, and an unexplained error
    # would mean the config passes by luck.
    python3 - "$O/rpmlint-config.toml" "$O/rpmlint-nocfg.txt" > "$O/filters.txt" 2>&1 <<'PY'
import re, sys, tomllib
cfg = tomllib.load(open(sys.argv[1], 'rb'))
lines = [l for l in open(sys.argv[2], encoding='utf-8', errors='replace').read().splitlines() if ': E: ' in l]
filters = cfg.get('Filters', [])
dead = [f for f in filters if not any(re.search(f, l) for l in lines)]
unexplained = [l for l in lines if not any(re.search(f, l) for f in filters)]
print("filters=%d" % len(filters))
print("dead=%d" % len(dead))
print("errors=%d" % len(lines))
print("unexplained=%d" % len(unexplained))
for l in dead:
    print("DEAD: " + l)
for l in unexplained:
    print("UNEXPLAINED: " + l)
PY
    sa "the config carries 8 filters, one reason each" "$(num filters.txt '^filters=8$')" "1"
    sa "no dead filter (each matches >=1 message of the no-config run)" "$(num filters.txt '^dead=0$')" "1"
    sa "and the filters explain every one of the 26 errors" "$(num filters.txt '^unexplained=0$')" "1"
    sa "the no-config run reports 26 errors, i.e. all of them" "$(num filters.txt '^errors=26$')" "1"
    end_row "G-RPM-4 every filter is load-bearing (8 filters explain all 26 errors, none dead)"
  else
    sk "no host python3: the per-filter dead-filter check did not run"
    sa "rpmlint.toml lists its filters" "$(num rpmlint-config.toml '^Filters = \[')" "1"
    end_row "G-RPM-4 rpmlint.toml lists filters (dead-filter check skipped: no host python3)"
  fi
fi

sec "G-RPM-5  C11's mechanism, measured on this toolchain (the fixture has no real ELF)"

sa "binutils is present and built the witness ELF" "$(num witness-as.txt '^0$')" "1"
sa "and the witness really carries a DT_NEEDED (the hazard is in the file, not in the story)" \
  "$(num witness-objdump.txt 'NEEDED.*libavcodec\.so\.60')" "1"
sa "the switch ON turns that DT_NEEDED into an automatic requirement" \
  "$(subdep witness-yes.requires.txt libavcodec.so.60)" "1"
sa "the switch OFF produces no such requirement" \
  "$(lit witness-no.requires.txt libavcodec.so.60)" "0"
sa "and both witness builds succeeded" "$(rc witness-no)$(rc witness-yes)" "00"
end_row "G-RPM-5 C11 witness: the sonotype is absent under AutoReqProv: no"

sa "the launcher (a #!/usr/bin/sh script, autoreq left ON) DOES get the auto interp require" \
  "$(depauto deptypes-launcher.txt /usr/bin/sh)" "1"
sa "while the runtime's requirement set has no auto entry at all (C11's deviation is effective)" \
  "$(depauto deptypes-runtime.txt)" "0"
sa "the sweep covers every file under the staged root" \
  "$(cnt payload-elf.txt)" "$(cnt staged-root-files.txt)"
sa "and not one of them has a dynamic section: 0 DT_NEEDED for rpmbuild's generator to require" \
  "$(num payload-elf.txt ' 0$')" "$(cnt staged-root-files.txt)"
sa "only the two guest stubs carry the ELF magic, and no host ELF stand-in does" \
  "$(lit payload-elf.txt 'write 177ELF')$(lit payload-elf.txt 'libguest.bin 177ELF')" "11"
sa "so AutoReqProv: yes could not change one requirement here -- that half of C11 is the witness above" \
  "$(lit payload-elf.txt '177ELF')" "2"
sa "and no unpackaged file was ever left behind by the build" \
  "$(lit build.log 'Installed (but unpackaged)')" "0"
end_row "G-RPM-5 the auto-reqprov sensor is live on this toolchain (launcher interp)"

sa "both spellings of the %post body built" "$(rc escape-escaped)$(rc escape-bare)" "00"
sa "and %%a and %a reach the scriptlet as the SAME bytes (rpm leaves an undefined macro alone)" \
  "$(if [ -s "$O/escape-escaped.scriptlet.txt" ] && cmp -s "$O/escape-escaped.scriptlet.txt" "$O/escape-bare.scriptlet.txt"; then echo same; else echo differs; fi)" "same"
sa "with the literal %a still in the scriptlet (the escape is what makes it literal)" \
  "$(lit escape-bare.scriptlet.txt '%a')" "1"
sa "while a DEFINED macro (%{_bindir}) in the same scriptlet IS expanded (escaping is not dead code)" \
  "$(lit scripts-runtime.txt '%{_bindir}')" "0"
end_row "G-RPM-5 the %a mutation of TASKS.md T4 is inert on this toolchain"

# ================================================================================================
sec "SUMMARY"
printf '  %d rows, %d passed, %d failed' "$rows" "$pass" "$fail"
if [ "$skips" = 0 ]; then printf '\n'; else printf ', %d skipped\n' "$skips"; fi
if [ "$fail" != 0 ]; then
  printf '\n%sFAILED%s -- %d row(s) red. A red row here is a red gate: fix the object, not the row.\n' "$C_ER" "$C_0" "$fail" >&2
  exit 1
fi

# ================================================================================================
# NEGATIVE CONTROLS. Each one breaks the OBJECT under test in the private copy, re-runs this whole
# battery, and asserts that the row it names goes RED -- and that the break itself was not a no-op
# (a mutation that changes nothing proves nothing). A control run never sweeps (recursion guard).
if [ -n "$CONTROLS" ]; then
  [ -n "$QUIET" ] || printf '\n%snote%s control sweep skipped (T4_GATES_NO_CONTROLS / T4_GATES_BREAK)\n' "$C_SK" "$C_0"
  exit 0
fi

sec "NEGATIVE CONTROLS  (T4_GATES_BREAK=<name>, T4_GATES_CONTROLS='$CONTROL_NAMES')"
WANT=${T4_GATES_CONTROLS:-all}
ctl_ok=0
ctl_bad=0
for name in $CONTROL_NAMES; do
  case " $WANT " in
    " all " | *" $name "*) : ;;
    *) continue ;;
  esac
  row=$(ctl_row "$name")
  log=$WORK/ctl-$name.log
  T4_GATES_BREAK=$name T4_GATES_NO_CONTROLS=1 T4_GATES_QUIET=1 bash "$0" > "$log" 2>&1
  child_rc=$?
  if grep -q 'BREAK-NOOP\|BREAK-UNKNOWN' "$log"; then
    ctl_bad=$((ctl_bad+1)); no "control $name: the mutation itself is broken (see the log above)"
  elif [ "$child_rc" = 0 ]; then
    ctl_bad=$((ctl_bad+1)); no "control $name: the battery still passed with the object broken"
  elif ! grep -qF "FAIL $row" "$log"; then
    ctl_bad=$((ctl_bad+1)); no "control $name: '$row' did not go red"
  else
    ctl_ok=$((ctl_ok+1)); ok "control $name: '$row' went red"
  fi
done
printf '  %d control(s) killed their row, %d did not\n' "$ctl_ok" "$ctl_bad"
if [ "$ctl_bad" != 0 ]; then
  printf '\n%sFAILED%s -- %d control(s) did not kill their row: a gate without a control is a ghost row.\n' "$C_ER" "$C_0" "$ctl_bad" >&2
  exit 1
fi