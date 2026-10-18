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
#   T4_RPM_IMAGE=<image>      default `fedora:41`, which is BARE (no rpm, no rpmspec, no rpmlint --
#                             measured). The battery therefore provisions the gate image ONCE and
#                             reuses the tag for the (1 + N controls) container runs; an explicit
#                             T4_RPM_IMAGE is used as it is and refused if it has no toolchain. The
#                             recipe it builds (the T4 report used this image):
#
#       docker build -t darling-rpm-gates:fc41 - <<'EOF'
#       FROM fedora:41
#       RUN dnf -y install rpm-build rpmlint xz diffutils binutils zstd && dnf clean all
#       EOF
#       T4_RPM_IMAGE=darling-rpm-gates:fc41 bash packaging/testdata/run-rpm-gates.sh
#
#                             binutils is what the G-RPM-5 witness needs (as/ld/objdump); the
#                             fedora:41 tag satisfies it through rpm-build's own dependencies.
#                             zstd is named EXPLICITLY (it also arrives transitively: rpm-build
#                             Requires: zstd) because the builder now writes Source0 with `zstd`
#                             -- C50/R1: the `.tar.zst` name is a promise about the BYTES -- and
#                             the image must never be the thing that silently decides otherwise.
#   T4_GATES_BREAK=<name>     negative-control hook: break the OBJECT under test and re-run (see
#                             the bottom of this file). Unset in a normal run.
#   T4_GATES_CONTROLS=<spec>  `all` (default) or a space-separated subset of the control names.
#                             Matching is TOKEN-EXACT (`all` is the literal word; otherwise a control
#                             is selected only when its whole name appears as one word of the spec),
#                             so an element that spells no control is IGNORED, not reported. The
#                             resolved list is what the sweep runs AND what the skip account counts,
#                             and it is printed in the sweep's own header: read THAT, not the spec.
#                             A spec that selects no control at all is REFUSED before any summary
#                             (stderr + rc 2) -- an empty sweep is not a green sweep.
#   T4_GATES_NO_CONTROLS=1    do not run the control sweep. The gate rows are unchanged; the sweep
#                             is the proof they can go red, so it is ON by default. A sweep that
#                             does not run is REPORTED and counted as skipped (`N skipped` in the
#                             summary plus one named SKIP per control), never folded into `passed`
#                             and never fatal: nothing in CI runs this battery (grep -rn testdata
#                             .github/ -> no match), so no input is *expected* here and there is no
#                             equivalent of run-deb-gates.sh's T3_GATES_REQUIRE_DOCKER to mirror.
#   T4_GATES_QUIET=1          print only the rows that are not PASS (what the sweep reads). A SKIP
#                             is not a PASS, so the skip and UNMEASURED lines and every summary
#                             count still print.
#   T4_GATES_EXPECT_ROWS=<n>  the number of VERDICT rows this run must produce (default 37: PLAN
#                             10's T4 gate table). `rows` is asserted `== pass + fail` (the totals are
#                             consistent) and `== this` (the run is COMPLETE): deleting one `end_row`
#                             lowers `rows` and `pass` together, so consistency alone cannot see a row
#                             that left the transcript -- the pin can. A degraded environment must
#                             still account for every row (as a verdict, a SKIP or an UNMEASURED
#                             line), which is why this number does not move across the images this
#                             battery supports.
#   T4_GATES_ALLOW_UNMEASURED=1
#                             accept a gate row that could not be measured. By DEFAULT an UNMEASURED
#                             row is FATAL (rc 1): an image without python3 cannot measure G-RPM-4's
#                             filter analysis, and "the tool is missing" must not read as "green".
#                             Set this to accept that gap on purpose (a T4_RPM_IMAGE with no python3).
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
witness-autoreq escape-inert payload-elf payload-xz changelog-clock buildinfo-payload \
file-listed-twice launcher-manifest"
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
    payload-xz)       echo "G-RPM-2 Source0 is real zstd under the .tar.zst name (C50/R1)" ;;
    changelog-clock)  echo "G-RPM-1 the %changelog pins the package's source date (SOURCE_DATE_EPOCH), not the clock" ;;
    buildinfo-payload) echo "G-RPM-2 BUILD-INFO.txt's rpm-payload equals the spec's pin (w19T.zstdio)" ;;
    file-listed-twice) echo "G-RPM-2 one entry per path: the %attr lines replace the plain entries (0 'File listed twice')" ;;
    launcher-manifest) echo "G-RPM-2 the launcher rpm owns exactly its staged paths plus the two %doc files" ;;
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
# One value, defined once, used by the host render, the container and every row that names a
# version (see the two sites that read it). It is the tag PLAN's fixture convention carried as a
# literal in build-rpm.sh until T6 moved the literal here -- packaging/common/ holds no version.
FIXTURE_TAG=${T4_FIXTURE_TAG:-v0.1.0}
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
# Every row ends in exactly one of four states. PASS, FAIL, or -- when its precondition is not met --
# SKIP, which is COUNTED and NAMED (run-deb-gates.sh is the model for `skips`) and never folded into
# `pass`; UNMEASURED is the fourth, for a row whose own work did not run and which therefore must not
# be counted as a PASS (the no-python3 branch of G-RPM-4 below). `rows` is the number of rows that
# produced a verdict, so `rows == pass + fail`, asserted at the summary -- `chk` used to leave `rows`
# alone, and the summary read "29 rows, 37 passed": a counter without a definition.
rows=0; pass=0; fail=0; skips=0; unmeas=0
ROWFAIL=0
# control-row counters (the NEGATIVE CONTROLS section, below the summary): ctl_no prints a FAIL and
# counts a control that did not kill its row, without touching `pass`/`fail` -- the gate rows'
# verdict is printed by the summary, and a control failure must not rewrite a reported number.
ctl_ok=0; ctl_bad=0; ctl_rows=0
ok()   { pass=$((pass+1)); [ -n "$QUIET" ] || printf '  %sPASS%s %s\n' "$C_OK" "$C_0" "$1"; }
no()   { fail=$((fail+1)); printf '  %sFAIL%s %s\n' "$C_ER" "$C_0" "$1"; }
ctl_no() { ctl_bad=$((ctl_bad+1)); printf '  %sFAIL%s %s\n' "$C_ER" "$C_0" "$1"; }
sk()   { skips=$((skips+1)); printf '  %sSKIP%s %s\n' "$C_SK" "$C_0" "$1"; }
unmeasured() { unmeas=$((unmeas+1)); printf '  %sUNMEASURED%s %s\n' "$C_SK" "$C_0" "$1"; }
chk() { # chk LABEL GOT WANT -- a one-assertion row
  rows=$((rows+1))
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
cntn() { # cntn FILE -- cnt() as a NUMBER: 0 when the file is absent, so arithmetic cannot abort.
  # Measured: with an artifact missing, the `missing` WORD reached `$(( ))`, the unset variable made
  # `set -u` kill the whole table (line 869, the bare-image run) and the remaining rows were never
  # reported -- a harness that cannot print the row that says "artifact missing" hides the diagnosis.
  _c=$(cnt "$1")
  case $_c in ''|*[!0-9]*) echo 0 ;; *) echo "$_c" ;; esac
}
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
interpdep() { # interpdep FILE -- 1 when an auto-injected row is THE launcher's script interp require
  # MENOR-5: match the NAME as a whole path, so both the payload's own shebang spelling (`/bin/sh`)
  # and a usrmerged build root's normalised one (`/usr/bin/sh`, what Fedora's rpmbuild injects here)
  # are accepted. `subdep FILE /bin/sh` cannot do this: it tests `index($1, s) > 0`, i.e. a SUBSTRING
  # NOT AT OFFSET 0 -- so the exact name `/bin/sh` scores 0 and the row would go red with a
  # misleading "sensor is not live" message on a non-usrmerged root.
  if [ -f "$O/$1" ]; then
    awk -F'|' '$1 ~ /^\/(usr\/)?bin\/sh$/ && $2 ~ /(^|,)auto($|,)/ { c++ } END { print c+0 }' "$O/$1"
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

# The image must carry the rpm toolchain: a bare `fedora:41` has neither rpmbuild, rpmspec nor
# rpmlint (measured), and the measurement run would then collect nothing while 19+ rows went red for
# a missing PACKAGE rather than for the object under test. So the battery provisions its gate image
# ONCE, from the recipe in this file's header, and every later run reuses the tag.
image_ready() { # image_ready IMAGE -- the tools the container half reads
  "$DOCKER" run --rm --entrypoint sh "$1" -c \
    'command -v rpmbuild >/dev/null 2>&1 && command -v rpmspec >/dev/null 2>&1 \
       && command -v rpmlint >/dev/null 2>&1 && command -v zstd >/dev/null 2>&1' >/dev/null 2>&1
}
if [ -n "${T4_RPM_IMAGE:-}" ]; then
  # An explicit choice is never second-guessed: it is provisioned, or the run stops here.
  if ! image_ready "$IMAGE"; then
    printf '\n%sFATAL%s T4_RPM_IMAGE=%s carries no rpmbuild/rpmspec/rpmlint/zstd, so the measurement\n' \
      "$C_ER" "$C_0" "$IMAGE" >&2
    printf '       run would collect nothing. Point it at a provisioned image (see the header).\n' >&2
    exit 1
  fi
elif image_ready "$IMAGE"; then
  : # a fedora:41 that already has them (someone provisioned it): use it as it is
elif image_ready darling-rpm-gates:fc41; then
  printf '%snote%s %s is bare: using the prebuilt gate image darling-rpm-gates:fc41\n' \
    "$C_B" "$C_0" "$IMAGE"
  IMAGE=darling-rpm-gates:fc41
else
  printf '%snote%s %s is bare: building darling-rpm-gates:fc41 once (dnf -y install ...)\n' \
    "$C_B" "$C_0" "$IMAGE"
  cat > "$WORK/gate-image.Dockerfile" <<DOCKERFILE
FROM $IMAGE
RUN dnf -y install rpm-build rpmlint xz diffutils binutils zstd \
  && dnf clean all
DOCKERFILE
  if ! "$DOCKER" build -t darling-rpm-gates:fc41 -f "$WORK/gate-image.Dockerfile" "$WORK" >&2; then
    printf '\n%sFATAL%s could not provision the gate image (network? dnf?): nothing was measured.\n' \
      "$C_ER" "$C_0" >&2
    exit 1
  fi
  IMAGE=darling-rpm-gates:fc41
fi
chk "the image carries rpmbuild, rpmspec, rpmlint and zstd" \
  "$(image_ready "$IMAGE" && echo yes)" "yes"

# The shipped render, on THIS box, with no rpm toolchain at all: run before the container so a box
# with no rpm still proves what CI will ship -- and prove the shipped arch is x86_64 while the
# fixture is free to be rewritten. --render-only stops after step 7 (specs + sources, no rpmbuild).
mkdir -p "$O" "$HO" "$HOSTDIST"
# SOURCE_DATE_EPOCH pins the %changelog date (C54) so the shipped render is a literal rather than
# "whatever day the gate ran", exactly like the container's own shipped render -- the two are
# compared byte-for-byte below. The fixture tag is pinned for both, in the one place this harness
# keeps it (FIXTURE_TAG): the builders derive their own default from the checkout, and this copy of
# packaging/ has no .git, so an unpinned side would render the 0.0.0 development form.
( cd "$SRC" && DARLING_PKG_DIST="$HOSTDIST" SOURCE_DATE_EPOCH=1700000000 \
    TAG="$FIXTURE_TAG" RPM_FIXTURE_TAG="$FIXTURE_TAG" \
    sh packaging/common/build-rpm.sh fixture --render-only ) \
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
for t in rpmbuild rpmspec rpmlint as ld objdump zstd; do
  if command -v "$t" >/dev/null 2>&1; then "$t" --version 2>&1 | head -1 > "$OUT/tool-$t.txt"
  else echo absent > "$OUT/tool-$t.txt"; fi
done
# The %changelog date the battery pins for the shipped renders (SOURCE_DATE_EPOCH=1700000000).
# Collected here, in the same clock/TZ context as the build, so the host row compares two values
# produced by the same rules rather than by the reader's local `date`.
date -u -d @1700000000 '+%a %b %d %Y' > "$OUT/pin-date.txt" 2>/dev/null \
  || printf 'no-gnu-date\n' > "$OUT/pin-date.txt"

# The fixture must be buildable HERE: the shipped runtime spec pins ExclusiveArch x86_64 and
# rpmbuild refuses a foreign arch outright. The knob is fixture-only (build-rpm.sh ignores it for a
# TAG build), it rewrites exactly one line, and the battery asserts the shipped render separately.
arch=$(uname -m)
case $arch in x86_64) fixarch= ;; *) fixarch=$arch ;; esac
printf '%s\n' "${fixarch:--}" > "$OUT/fixture-arch.txt"
export RPM_FIXTURE_ARCH=$fixarch

# The fixture tag: the harness owns the literal, build-rpm.sh derives its own default
# (pkg-version.sh -> git describe, and this copy of packaging/ has no .git). Pinned here for the
# same reason run-deb-gates.sh pins TAG=v0.1.0 -- so the rows below assert an exact version, and so
# the host render-only run above and this container's runs render the SAME bytes.
export RPM_FIXTURE_TAG="$FIXTURE_TAG"

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
  attr-weaken)  break_one "$SRC/packaging/common/build-rpm.sh" 's#^usr/bin/darling|4755$#usr/bin/darling|0755#; s#^usr/bin/darlingserver|0755$#usr/bin/darlingserver|0644#' ;;
  token-inline) break_one "$SRC/packaging/rpm/darling-lol.spec.in" 's|^@RPM_REQUIRES@$|Requires:       @RPM_REQUIRES@|' ;;
  launcher-autoreq) break_one "$SRC/packaging/rpm/darling-lol-launcher.spec.in" 's|^Name:           darling-lol-launcher$|Name:           darling-lol-launcher\nAutoReqProv:    no|' ;;
  deps-drop)    break_one "$SRC/packaging/common/deps.rpm.fc41" '/^fuse-libs$/d' ;;
  comment-macro) break_one "$SRC/packaging/rpm/darling-lol.spec.in" 's/%%{_docdir}/%{_docdir}/' ;;
  arch-spelling) break_one "$SRC/packaging/rpm/darling-lol.spec.in" 's/^ExclusiveArch:  x86_64$/BuildArch:      x86_64/' ;;
  stage-break)  break_one "$SRC/packaging/common/stage.sh" '/^#!/a exit 9' ;;
  payload-elf)  break_one "$SRC/packaging/testdata/mkprefixfixture.sh" \
                  's|> "$_g/usr/lib/libguest.bin"$|> /dev/null; cp /usr/bin/rpm "$_g/usr/lib/libguest.bin"|' ;;
  witness-autoreq) ;; # not a source mutation: it un-sets the witness's own switch, below
  payload-xz)   break_one "$SRC/packaging/common/build-rpm.sh" \
                  "s|-I 'zstd -19 -T0' -cf|-cJf|g; s|28b52ffd ]|\${_magic} ]|" ;;
  changelog-clock) break_one "$SRC/packaging/common/build-rpm.sh" 's|SOURCE_DATE_EPOCH:-}|NEVER_SET}|' ;;
  buildinfo-payload) break_one "$SRC/packaging/common/build-rpm.sh" \
                  "s|RPM_PAYLOAD=\"\$rpm_payload\"|RPM_PAYLOAD=\"w19T.zstd\"|" ;;
  file-listed-twice) break_one "$SRC/packaging/rpm/darling-lol.spec.in" \
                  's|^%defattr(-,root,root,-)$|%defattr(-,root,root,-)\n/usr/lib/binfmt.d/darling.conf|' ;;
  launcher-manifest) break_one "$SRC/packaging/rpm/darling-lol-launcher.spec.in" \
                  's|^%files -f %{SOURCE1}$|%files|' ;;
  *) echo "BREAK-UNKNOWN: $BRK"; exit 4 ;;
esac

# --- 1. the production path: fixture = mkfixture.sh -> stage.sh -> render.sh -> rpmbuild ---------
cd /work
export DARLING_PKG_DIST="$DIST"
# The %changelog date is pinned for every fixture build here, not left to the day the gate runs:
# C54's date is taken from SOURCE_DATE_EPOCH when it is set, so pinning it makes the rendered spec
# a literal AND makes the built spec byte-comparable with the shipped one (the arch knob may touch
# exactly one line, and the date is not that line).
export SOURCE_DATE_EPOCH=1700000000
sh "$SRC/packaging/common/build-rpm.sh" fixture > "$OUT/build.log" 2>&1
echo $? > "$OUT/build.rc"

# --- 1b. the zstd guard: with zstd unreachable the builder must REFUSE, not fall back to xz -----
# A PATH built out of symlinks to the tools the builder needs, minus zstd: everything else works,
# so the only thing that can make this run fail is the compressor. The row asserts the FATAL text
# AND the nonzero rc, i.e. that the refusal is the guard's and not a random missing binary.
mkdir -p /work/nozstd
for _t in dirname cat grep sed awk tr cmp comm sort diff cp mv rm mkdir find tar stat date od \
          printf head wc uname install expr dirname sha256sum; do
  _p=$(command -v "$_t" 2>/dev/null) && ln -sf "$_p" "/work/nozstd/$_t" 2>/dev/null
done
env PATH=/work/nozstd DARLING_PKG_DIST=/work/nozstd-dist /bin/sh "$SRC/packaging/common/build-rpm.sh" \
    fixture --render-only > "$OUT/nozstd.log" 2>&1
echo $? > "$OUT/nozstd.rc"
printf '%s\n' "$(command -v zstd 2>/dev/null || echo none)" > "$OUT/zstd-path.txt"

# --- 2. the same render with the knob OFF: what CI ships, provable here with no rpmbuild --------
# SOURCE_DATE_EPOCH is pinned so the %changelog date in the shipped render is a literal rather than
# whatever day the gate ran -- and so the host's render-only run (same pin) is byte-comparable.
RPM_FIXTURE_ARCH= DARLING_PKG_DIST=/work/shipped SOURCE_DATE_EPOCH=1700000000 \
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

# --- 3b. Source0's BYTES, measured: the `.tar.zst` name is a promise about the compression -------
# The two readers that trust the name -- `zstd -t` and `tar --zstd -tf` -- are exactly the ones an
# xz payload (magic fd377a585a00) takes down (`tar -Jtf` instead reads ONLY xz: measured, rc=2 on a
# real zstd tar). Collected here, asserted on the host, so the gate cannot accept a name lie.
: > "$OUT/tar-magic.txt"
: > "$OUT/zstd-test.log"
: > "$OUT/tar-zstd-list.txt"
zstd_rc=0
tarzstd_rc=0
for t in "$DIST"/pkg/*-root.tar.zst; do
  [ -e "$t" ] || continue
  printf '%s %s\n' "${t##*/}" "$(od -An -tx1 -N4 "$t" | tr -d ' \n')" >> "$OUT/tar-magic.txt"
  zstd -t "$t" >> "$OUT/zstd-test.log" 2>&1 || zstd_rc=1
  tar --zstd -tf "$t" >> "$OUT/tar-zstd-list.txt" 2>> "$OUT/zstd-test.log" || tarzstd_rc=1
done
echo $zstd_rc > "$OUT/zstd-test.rc"
echo $tarzstd_rc > "$OUT/tar-zstd-consumer.rc"
cp "$DIST/pkg/darling-lol-BUILD-INFO.txt" "$OUT/BUILD-INFO.txt" 2>/dev/null || :

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

# The per-filter analysis runs IN HERE, not on the host: the container is where the config and the
# no-config output are, and it always carries python3 (the host may not -- MENOR-6, where the
# strongest G-RPM-4 assertion used to collapse to a grep while the row kept its "load-bearing"
# name). `filters.rc` tells the host whether the analysis ran at all.
if command -v python3 >/dev/null 2>&1 && [ -s "$OUT/rpmlint-nocfg.txt" ]; then
  python3 - "$OUT/rpmlint-config.toml" "$OUT/rpmlint-nocfg.txt" > "$OUT/filters.txt" 2>&1 <<'PY'
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
  echo $? > "$OUT/filters.rc"
else
  echo "no-python3" > "$OUT/filters.txt"
  echo 127 > "$OUT/filters.rc"
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
# This row's verdict is printed by `ok`/`no` directly (not through `chk`/`end_row`), so it has to count
# its own row here: the invariant the summary asserts is `rows == pass + fail`, and a row verdict that
# does not count `rows` is the very defect this file fixes. Measured -- before this line the fixed file
# read `FAIL the row counter is torn: rows=36 != pass+fail=37` on a plain run (after/rpm-default.txt).
rows=$((rows+1))
if ! "$DOCKER" run --rm -v "$WORK:/work" -v "$SRC:/src" \
     -e "T4_GATES_BREAK=$BREAK" -e "T4_HOST_UID=$(id -u)" -e "T4_HOST_GID=$(id -g)" \
     -e "FIXTURE_TAG=$FIXTURE_TAG" \
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
         dump-runtime.txt list-runtime.txt list-launcher.txt dump-launcher.txt reqnames-runtime.txt \
         deptypes-runtime.txt \
         filecaps-runtime.txt recommends-runtime.txt installed-mode.txt witness-yes.requires.txt \
         BUILD-INFO.txt tar-magic.txt zstd-test.rc filters.txt; do
  [ -s "$O/$f" ] || uncollected="$uncollected $f"
done
chk "G-RPM-0 the run collected every artifact the rows below read" "${uncollected:-none}" "none"
# The honest residual (MENOR-4): `requires-runtime.txt` (`rpm -qp --requires`) is still collected and
# not read by a row. It is deliberately left that way -- it is the SAME query as reqnames-runtime.txt
# (`--qf '[%{REQUIRENAME}\n]'`), differing only by the rpmlib version constraints, and the reviewed
# list carries no version operator at all (deps.rpm.fc41 is 27 unversioned names). Any row comparing
# the two would be a tautology on a single `rpm -qp`, i.e. a ghost row by construction: no control
# could redden one side without the other. The requirement CONTENT is asserted from reqnames (exact
# set, 30 unique + 4 rpmlib) and from the render's own Requires: line in G-RPM-1/G-RPM-3.
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

sa "the shipped runtime spec carries a %changelog entry (C54: it is what gives rpm a source date)" \
  "$(num spec-shipped-runtime.txt '^%changelog$')" "1"
sa "the shipped launcher spec carries one too (both packages need it)" \
  "$(num spec-shipped-launcher.txt '^%changelog$')" "1"
sa "and its date is pinned from SOURCE_DATE_EPOCH, not from the clock ($(val pin-date.txt))" \
  "$(lit spec-shipped-runtime.txt "$(val pin-date.txt)")" "1"
sa "with the package's own version in the entry ($(val rpm-runtime.txt))" \
  "$(num spec-shipped-runtime.txt '^\* .* darling-lol maintainers - 0\.1\.0-1\.lol\.fc41$')" "1"
sa "so rpmbuild has a date to take: no 'changelog has no entries' warning (C54)" \
  "$(lit build.log 'changelog has no entries')" "0"
sa "and rpmlint no longer has an E: no-changelogname-tag to filter (the filter is deleted, R2)" \
  "$(lit rpmlint-config.toml "'no-changelogname-tag',")" "0"
end_row "G-RPM-1 the %changelog pins the package's source date (SOURCE_DATE_EPOCH), not the clock"

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

# Source0's BYTES: the `.tar.zst` name is a promise (C50/R1). The measured spell is `tar -I zstd`
# -- it writes real zstd AND reads both flavours -- while `-J` is xz and `-Jtf` reads ONLY xz
# (measured: rc=2 `xz: File format not recognized` on a real zstd tar). So the name stays and the
# bytes are forced to match it: never a silent xz fallback, and the two name-trusting readers below
# (`zstd -t`, `tar --zstd`) are exactly what an xz payload takes down.
sa "both Source0 tars start with the zstd magic 28b52ffd, not xz's fd377a585a00" \
  "$(num tar-magic.txt '^darling-lol-[0-9.]+-root\.tar\.zst 28b52ffd$')$(num tar-magic.txt '^darling-lol-launcher-[0-9.]+-root\.tar\.zst 28b52ffd$')" "11"
sa "and no Source0 tar carries the xz magic (the name lie the gate exists to catch)" \
  "$(num tar-magic.txt 'fd377a585a00')" "0"
sa "zstd -t validates both payloads (the reader that trusts the name)" "$(rc zstd-test)" "0"
sa "and a real zstd consumer reads them: tar --zstd lists $(cnt tar-zstd-list.txt) members" \
  "$(if [ "$(rc tar-zstd-consumer)" = 0 ] && [ "$(cnt tar-zstd-list.txt)" -gt 0 ]; then echo ok; else echo "rc=$(rc tar-zstd-consumer) members=$(cnt tar-zstd-list.txt)"; fi)" "ok"
sa "the spec unpacks Source0 with -I zstd -f, the ONE spelling measured to read both flavours" \
  "$(lit spec-runtime.txt 'tar -xp --numeric-owner -I zstd -f %{SOURCE0} -C %{buildroot}')$(lit spec-launcher.txt 'tar -xp --numeric-owner -I zstd -f %{SOURCE0} -C %{buildroot}')" "11"
sa "and no xz spelling (-J / -cJ) survives on either %install command line" \
  "$(num spec-runtime.txt '^tar .* -J')$(num spec-launcher.txt '^tar .* -J')" "00"
end_row "G-RPM-2 Source0 is real zstd under the .tar.zst name (C50/R1)"

sa "the packaged BUILD-INFO.txt pins the rpmio spelling the spec pins (R5, the T4 -> T1 edge)" \
  "$(num BUILD-INFO.txt '^rpm-payload: w19T\.zstdio$')" "1"
sa "and not the plan's w19T.zstd, which rpmbuild rejects with 'Unknown payload compression'" \
  "$(num BUILD-INFO.txt '^rpm-payload: w19T\.zstd$')" "0"
sa "and the two sites agree character for character, so neither can rot alone" \
  "$(sed -n 's/^rpm-payload: //p' "$O/BUILD-INFO.txt")" \
  "$(sed -n 's/^%global _binary_payload //p' "$O/spec-shipped-runtime.txt" | head -1)" "w19T.zstdio"
end_row "G-RPM-2 BUILD-INFO.txt's rpm-payload equals the spec's pin (w19T.zstdio)"

# %files -f <list>: the generated list is stage.sh's quoted paths PLUS the hardened paths' %attr
# lines, and the two halves are asserted separately. The %attr line REPLACES the path's plain entry
# (C52: appending it instead is what rpm reports as `warning: File listed twice`), so the path half
# must be byte-identical to what stage.sh wrote, minus the launcher's paths, minus the %dir block's
# paths, and minus the hardened paths that hand their entry to an %attr line.
grep -v '^%attr(' "$O/stage-darling-lol-filelist.txt" > "$WORK/fl.paths"
sed -n 's/^%attr([^)]*) \(".*"\)$/\1/p' "$O/stage-darling-lol-filelist.txt" > "$WORK/fl.attrs.quoted"
sed 's/^"//; s/"$//; s|^/||' "$WORK/fl.paths"        | LC_ALL=C sort > "$WORK/fl.stripped"
sed 's/^"//; s/"$//; s|^/||' "$WORK/fl.attrs.quoted" | LC_ALL=C sort > "$WORK/fl.attrs.stripped"
{ cat "$WORK/fl.stripped"; cat "$WORK/fl.attrs.stripped"; } | LC_ALL=C sort > "$WORK/fl.owned.stripped"
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
sa "every owned runtime path is a byte-identical copy of a stage.sh line (no re-quoting)" \
  "$(LC_ALL=C comm -23 "$WORK/fl.owned.stripped" "$WORK/quoted.stripped" | wc -l | tr -d ' ')" "0"
sa "and the owned set is exactly files.runtime minus files.emptydirs" \
  "$( { cat "$WORK/fl.owned.stripped"; cat "$WORK/emptydirs.stripped"; } | LC_ALL=C sort | LC_ALL=C comm -3 - "$WORK/fr.stripped" | wc -l | tr -d ' ')" "0"
sa "and it is 18 owned paths: 20 runtime paths minus the 2 empty dirs" \
  "$(wc -l < "$WORK/fl.owned.stripped" | tr -d ' ')$(cnt stage-files.runtime)" "1820"
sa "every plain path line is quoted (the only quoting that survives the space paths)" \
  "$(awk '!/^".*"$/' "$WORK/fl.paths" | wc -l | tr -d ' ')" "0"
sa "the launcher list is stage.sh's files.launcher, copied as-is" \
  "$(cmp -s "$O/stage-files.launcher" "$O/stage-darling-lol-launcher-filelist.txt" && echo same || echo differs)" "same"
sa "the two packages' owned paths are disjoint (C18: no path is owned twice)" \
  "$(LC_ALL=C comm -12 "$WORK/fl.owned.stripped" "$WORK/launcher.stripped" | wc -l | tr -d ' ')" "0"
sa "the runtime rpm owns exactly the staged paths plus the two %doc files %install adds" \
  "$(LC_ALL=C comm -3 "$WORK/list.expected" "$WORK/list.actual" | wc -l | tr -d ' ')" "0"
end_row "the runtime %files list is stage.sh's quoted list, byte-for-byte"

# C52/R3, one row of its own: the %attr lines are the hardened paths' ONLY entry, so the generated
# list stays one entry per path. Appending them next to the plain paths is what rpm reports as
# `warning: File listed twice` (measured on rpm 4.20.1: 3 distinct paths, 3 warnings) -- and a
# duplicate is a WARNING with rc=0, so without this row a future append-style regression would be
# silent. The row's control re-adds a duplicate to the spec and must turn it red.
sa "the generated list carries the hardened paths as %attr lines (C52)" \
  "$(wc -l < "$WORK/fl.attrs.quoted" | tr -d ' ')" "3"
sa "and each %attr path is one of files.runtime's own (a %attr for an absent path is a hard error)" \
  "$(LC_ALL=C comm -23 "$WORK/fl.attrs.stripped" "$WORK/fr.stripped" | wc -l | tr -d ' ')" "0"
sa "the %attr lines REPLACE the plain entries, they do not repeat them (one entry per path)" \
  "$(LC_ALL=C comm -12 "$WORK/fl.stripped" "$WORK/fl.attrs.stripped" | wc -l | tr -d ' ')" "0"
sa "and rpm agrees: 0 'File listed twice' anywhere in the build (C52 cannot regress silently)" \
  "$(lit build.log 'File listed twice')" "0"
end_row "G-RPM-2 one entry per path: the %attr lines replace the plain entries (0 'File listed twice')"

# MENOR-4: the launcher's OWN manifest was collected but never read -- its owned set was verified
# only indirectly (its filelist copy plus the builder's invariant). This is the row that would
# notice a %files-vs--f mistake in the launcher spec, and it makes the launcher symmetric with the
# runtime, which gets five query rows.
sed 's|^/||' "$O/list-launcher.txt" | LC_ALL=C sort > "$WORK/ll.actual"
{ sed 's|^/||' "$O/stage-files.launcher"
  printf '%s\n' usr/share/doc/darling-lol-launcher/copyright usr/share/doc/darling-lol-launcher/BUILD-INFO.txt
} | LC_ALL=C sort > "$WORK/ll.expected"
sa "the launcher rpm owns exactly its staged paths plus the two %doc files %install adds" \
  "$(LC_ALL=C comm -3 "$WORK/ll.expected" "$WORK/ll.actual" | wc -l | tr -d ' ')" "0"
sa "and no runtime path leaked into it (the split is one path, one owner)" \
  "$(LC_ALL=C comm -12 "$WORK/launcher.stripped" "$WORK/fr.stripped" | wc -l | tr -d ' ')" "0"
# MENOR-4, second half: `dump-launcher.txt` was collected and never read either (its only other
# reader was its own collection line). These two assertions make it load-bearing, and unlike
# `list-launcher.txt` they look at the PAYLOAD METADATA rather than the file list: the launcher spec
# has no %attr block, so every mode that survives is the one Source0 carried -- and a launcher rpm
# that owns nothing (the `launcher-manifest` control's `%files` in place of `%files -f`) cannot
# satisfy either count. No literal count: both sides are the staged manifest's own size plus the two
# %doc files %install adds, so T1 growing the launcher's file set cannot redden these by accident.
sa "the launcher's payload metadata covers every path the package owns (staged + the two %doc files)" \
  "$(cnt dump-launcher.txt)" "$(( $(cntn stage-files.launcher) + 2 ))"
sa "and every one of those modes is 0644 or 0755: this spec has no hardened path, so Source0's own modes stand" \
  "$(num dump-launcher.txt ' (0100644|0100755) ')" "$(( $(cntn stage-files.launcher) + 2 ))"
end_row "G-RPM-2 the launcher rpm owns exactly its staged paths plus the two %doc files"

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
  # rpmlint is absent from this image: the three G-RPM-4 rows below did not run, and a single `sk`
  # line for three rows is the same lie in a smaller place (`skips` would count 1, the summary would
  # be green, and two rows would have no trace at all). Each row gets its own named UNMEASURED line,
  # so the summary's own `N row(s) UNMEASURED` is an account of exactly what is missing -- and an
  # unmeasured row is fatal unless the gap is accepted with T4_GATES_ALLOW_UNMEASURED=1.
  unmeasured "G-RPM-4 rpmlint -c: rc=0, 0 errors (NOT measured: rpmlint is not in $IMAGE)"
  unmeasured "G-RPM-4 the config is the difference between errors-on and 0 errors (NOT measured: rpmlint is not in $IMAGE)"
  unmeasured "G-RPM-4 every filter is load-bearing (NOT measured: rpmlint is not in $IMAGE)"
else
  sa "rpmlint -c exits 0" "$(rc rpmlint-cfg)" "0"
  sa "with 0 errors (warnings are tolerated by policy, PLAN 9.6's rule; their count is not invariant)" \
    "$(lit rpmlint-cfg.txt ' 0 errors, ')" "1"
  sa "and the two packages really were checked" \
    "$(lit rpmlint-cfg.txt '2 packages and 0 specfiles checked')" "1"
  sa "no E: line survives" "$(lit rpmlint-cfg.txt ': E: ')" "0"
  end_row "G-RPM-4 rpmlint -c: rc=0, 0 errors"

  # The literal error count is deliberately NOT asserted: it is a function of T1's list content
  # (MENOR-2 measured that a one-line deps.txt edit reddened a "26 errors" row although nothing
  # about rpmlint or the config had changed). The behaviour that matters -- errors without the
  # config, none with it -- is asserted instead, and the config's own content guard is `filters=7`.
  sa "without the config rpmlint reports errors (not 0) and exits 64 -- the config is load-bearing" \
    "$(rc rpmlint-nocfg)$(num rpmlint-nocfg.txt ' 0 errors, ')" "640"
  sa "and PLAN 10.3's literal --file does NOT load this TOML (same shape: rc 64, errors)" \
    "$(rc rpmlint-file)$(num rpmlint-file.txt ' 0 errors, ')" "640"
  sa "while with the config the same two packages report 0 errors and exit 0" \
    "$(rc rpmlint-cfg)$(num rpmlint-cfg.txt ' 0 errors, ')" "01"
  end_row "G-RPM-4 the config is the difference between errors-on and 0 errors (--file cannot load it)"

  if [ "$(rc filters)" = 0 ]; then
    # the analysis ran in the container (there is no host-python3 dependency any more, MENOR-6);
    # every filter must still match something and together they must explain every error.
    sa "the config carries 7 filters, one reason each (the of-record list, R2)" "$(num filters.txt '^filters=7$')" "1"
    sa "no dead filter (each matches >=1 message of the no-config run)" "$(num filters.txt '^dead=0$')" "1"
    sa "and the filters explain every error of the no-config run (0 unexplained)" "$(num filters.txt '^unexplained=0$')" "1"
    sa "the no-config run does report errors for the config to explain" "$(num filters.txt '^errors=[1-9][0-9]*$')" "1"
    end_row "G-RPM-4 every filter is load-bearing (7 filters explain every no-config error, none dead)"
  else
    # The row below is measurable WITHOUT python3: it is a host-side grep on the config copied out of
    # the packaging tree (`cp $SRC/packaging/rpm/rpmlint.toml $OUT/rpmlint-config.toml` above), so the
    # environment's degradation does not take it away. It used to be an `end_row` whose own LABEL said
    # "skipped" while its verdict landed in `passed` -- a PASS on a row that did not run, shape A1.
    # The label was the lie, so the row STAYS and the label is what changed: deleting the row instead
    # left the no-python3 transcript with one row FEWER than the supported image and no trace of it
    # anywhere -- the class, one level down, inside the fix of the class. The invariant this restores:
    # when the environment degrades, NO row may silently leave the transcript; every row of the normal
    # run is still accounted for as a verdict, a SKIP or an UNMEASURED line (and `rows`, pinned to
    # T4_GATES_EXPECT_ROWS, stays the same as the supported image's 37).
    sa "rpmlint.toml lists its filters" "$(num rpmlint-config.toml '^Filters = \[')" "1"
    end_row "G-RPM-4 rpmlint.toml lists filters"
    sk "the image had no python3: the per-filter analysis did not run ($IMAGE)"
    # The row below used to be an `end_row` whose own label said "skipped" while its verdict landed
    # in `passed`: a row that was never measured, counted as a measured one. It is reported as
    # UNMEASURED -- its own line, outside `passed`, outside `rows` -- because that is the whole point
    # of the class: a green total may never cover work that did not happen.
    unmeasured "G-RPM-4 every filter is load-bearing (NOT measured: the analysis needs python3 in $IMAGE)"
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

sa "the launcher (a #!/bin/sh script, autoreq left ON) DOES get the auto interp require" \
  "$(interpdep deptypes-launcher.txt)" "1"
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
# A disabled sweep is decided BEFORE the summary: its rows are rows of this battery and have to reach
# the summary's `skipped` field. A bare `note` (what this used to be) let the whole NEGATIVE CONTROLS
# section vanish from every total -- measured: `T4_GATES_NO_CONTROLS=1 T4_GATES_QUIET=1` printed
# `29 rows, 37 passed, 0 failed` with `grep -ci 'control\|skip'` = 0 over the transcript.
#
# The sweep's row list is resolved ONCE (T4_GATES_CONTROLS=all|subset) so that the sweep and its skip
# accounting iterate the same list: `K skipped` is then the same K as the controls that would have run.
sweep_rows=
for name in $CONTROL_NAMES; do
  case " ${T4_GATES_CONTROLS:-all} " in
    " all " | *" $name "*) sweep_rows="$sweep_rows $name" ;;
  esac
done
# An empty resolved list is not "no controls to run": it is an unaccountable sweep -- a typo in
# T4_GATES_CONTROLS, or a CONTROL_NAMES that lost its rows -- and the summary would then read
# "0 control(s) killed their row, 0 did not": green, with the whole proof absent. Refused (stderr +
# rc 2) before ANY summary is printed, the way the T4_GATES_BREAK name check refuses an unknown
# control -- but note WHERE this sits: the name check is near the top of this file, BEFORE the
# measurement phase, while this one is AFTER it (the gate rows above are rows of the same run), so a
# spec of pure typos has already paid for its container run when it is refused. The resolved list is
# printed in the sweep's own header: that, and not the spec, is what an operator must read.
if [ -z "$sweep_rows" ]; then
  printf 'run-rpm-gates: the control list is empty: T4_GATES_CONTROLS=%s selected no control (--list-controls)\n' \
    "${T4_GATES_CONTROLS:-all}" >&2
  exit 2
fi
sweep_skipped=0
if [ -n "$CONTROLS" ]; then
  sweep_skipped=1
  sweep_n=0
  skips0=$skips
  for name in $sweep_rows; do
    sweep_n=$((sweep_n + 1))
    sk "NEGATIVE CONTROLS $name (the sweep is off: T4_GATES_NO_CONTROLS / T4_GATES_BREAK)"
  done
  # The `skipped` field has to be the sweep's REAL row count, so it is asserted: a constant in place
  # of the counter is the same lie in a new place. Asserted as a DELTA, because the run's other skip
  # site (the python3-absent row) legitimately contributes to `skips` too -- the rpmlint-absent
  # branch does NOT: its three rows are `unmeasured`, a counter of their own.
  [ "$((skips - skips0))" = "$sweep_n" ] \
    || no "the skip counter is torn: $((skips - skips0)) SKIPped for $sweep_n control row(s)"
fi

sec "SUMMARY"
# `rows` is one unambiguous thing (a row that produced a verdict): assert it here, so the summary can
# never read "fewer rows than passed" (29 rows, 37 passed -- what `chk` not counting `rows` produced).
[ "$rows" = "$((pass + fail))" ] \
  || no "the row counter is torn: rows=$rows != pass+fail=$((pass + fail))"
# ... and assert that the run is COMPLETE, not only self-consistent. Deleting one whole row (an
# `end_row` moved under an `if`) lowers `rows` and `pass` together: the line above stays satisfied and
# the summary stays green over a transcript that lost a row. The expected number is a property of this
# battery's contract with PLAN 10's T4 table, so it is pinned -- and it is the SAME number on every
# image that gets here (the python3-absent row is a verdict row of its own, and an unmeasured row is
# reported outside `rows`).
[ "$rows" = "${T4_GATES_EXPECT_ROWS:-37}" ] \
  || no "the run did not account for every gate row: rows=$rows, expected ${T4_GATES_EXPECT_ROWS:-37} (T4_GATES_EXPECT_ROWS)"
printf '  %d rows: %d passed, %d failed, %d skipped\n' "$rows" "$pass" "$fail" "$skips"
[ "$skips" = 0 ] \
  || printf '  %s%d row(s) SKIPped: SKIP is not PASS%s\n' "$C_SK" "$skips" "$C_0"
[ "$unmeas" = 0 ] \
  || printf '  %s%d row(s) UNMEASURED: an unmeasured row is not a PASS%s\n' "$C_SK" "$unmeas" "$C_0"
if [ "$fail" != 0 ]; then
  printf '\n%sFAILED%s -- %d row(s) red. A red row here is a red gate: fix the object, not the row.\n' "$C_ER" "$C_0" "$fail" >&2
  exit 1
fi
# A row that never ran is not a PASS -- and it is not a silent exit 0 either: a battery that cannot
# MEASURE a gate row must not call the run green (the no-python3 image is that case, not a knob).
# An image that legitimately cannot carry the analysis says so out loud: T4_GATES_ALLOW_UNMEASURED=1.
if [ "$unmeas" != 0 ] && [ -z "${T4_GATES_ALLOW_UNMEASURED:-}" ]; then
  printf '\n%sFAILED%s -- %d gate row(s) were never measured (%s): install the tool, or set T4_GATES_ALLOW_UNMEASURED=1 to accept the gap on purpose.\n' \
    "$C_ER" "$C_0" "$unmeas" "$IMAGE" >&2
  exit 1
fi
[ "$sweep_skipped" = 0 ] || exit 0

# ================================================================================================
# NEGATIVE CONTROLS. Each one breaks the OBJECT under test in the private copy, re-runs this whole
# battery, and asserts that the row it names goes RED -- and that the break itself was not a no-op
# (a mutation that changes nothing proves nothing). A control run never sweeps (recursion guard).
sec "NEGATIVE CONTROLS  (T4_GATES_BREAK=<name>, T4_GATES_CONTROLS='$sweep_rows')"
for name in $sweep_rows; do
  ctl_rows=$((ctl_rows + 1))
  row=$(ctl_row "$name")
  log=$WORK/ctl-$name.log
  T4_GATES_BREAK=$name T4_GATES_NO_CONTROLS=1 T4_GATES_QUIET=1 bash "$0" > "$log" 2>&1
  child_rc=$?
  if grep -q 'BREAK-NOOP\|BREAK-UNKNOWN' "$log"; then
    ctl_no "control $name: the mutation itself is broken (see the log above)"
  elif [ "$child_rc" = 0 ]; then
    ctl_no "control $name: the battery still passed with the object broken"
  elif ! grep -qF "FAIL $row" "$log"; then
    ctl_no "control $name: '$row' did not go red"
  else
    ctl_ok=$((ctl_ok+1))
    [ -n "$QUIET" ] || printf '  %sPASS%s control %-16s -> %s went red\n' "$C_OK" "$C_0" "$name" "$row"
  fi
done
# The sweep's own total is asserted the same way as the gate rows': k controls were selected, so
# ctl_ok + ctl_bad must be k. A control row that vanishes is exactly the defect this file fixes.
if [ "$((ctl_ok + ctl_bad))" != "$ctl_rows" ]; then
  printf '  %sFAIL%s the sweep counter is torn: %d of %d control(s) reported\n' \
    "$C_ER" "$C_0" "$((ctl_ok + ctl_bad))" "$ctl_rows"
  printf '\n%sFAILED%s -- the control sweep cannot account for its own rows.\n' "$C_ER" "$C_0" >&2
  exit 1
fi
printf '  %d control(s) killed their row, %d did not\n' "$ctl_ok" "$ctl_bad"
if [ "$ctl_bad" != 0 ]; then
  printf '\n%sFAILED%s -- %d control(s) did not kill their row: a gate without a control is a ghost row.\n' "$C_ER" "$C_0" "$ctl_bad" >&2
  exit 1
fi
