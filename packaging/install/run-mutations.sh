#!/usr/bin/env bash
# packaging/install/run-mutations.sh -- the SELF-TEST of the two §16 gates:
#
#   packaging/install/test-detect.sh   G-INSTALL-2b  (distro detection over the 7 in-tree fixtures)
#   packaging/install/test-install.sh  G-INSTALL-3/4 (the tarball install, its state file, the
#                                                     documented removal, setuid, the prefix check)
#
# Why it exists. A gate whose rows are never shown to fail is an assertion, not a measurement: the
# T10 review's INFO-1 is exactly that failure mode (two mutants of the shipped installer passed every
# gate in the repo without a single red row). So for each row of each gate this script applies ONE
# small, plausible edit -- to the shipped installer, or, for the two removal rows, to the documented
# recipe in docs/PACKAGING.md -- runs the gate against the mutant, and asserts BOTH
#   (a) the gate exits non-zero, and
#   (b) the row that is supposed to catch this class of defect is among the rows that went red.
# A mutant that leaves a gate GREEN is a hole in that gate. The grid at the end prints, for every
# mutant, exactly which rows went red.
#
#   ./packaging/install/run-mutations.sh                 # everything (needs docker for 3/4)
#   GATE_IMAGE=ubuntu:24.04 ./packaging/install/run-mutations.sh
#   ./packaging/install/run-mutations.sh --detect-only   # G-INSTALL-2b only: no docker, no root
#
# 🚨 ARCH / IMAGE. G-INSTALL-2b is machine-independent and runs natively here (it is the unprivileged
# half). G-INSTALL-3/4 installs a fixture tree and needs a throwaway container as root, and its
# fixture is x86_64, so the gate carries its own `uname` shim (see its header) -- which makes this
# whole battery work on an arm64 box: `arch-refusal` is the only row that needs the REAL arch, and its
# mutant replacement (mx_arch_accept) is exactly the mutation that makes it red. On x86_64 the gate
# SKIPs that row and its mutant reports WEAK; that is the single expected difference.
#
# Requires for the install half: docker, and the image below (pull it first).
set -u

REPO_ROOT=$(cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$REPO_ROOT"

GATE_DETECT=packaging/install/test-detect.sh
GATE_INSTALL=packaging/install/test-install.sh
INSTALLER=packaging/install/darling-lol-install.sh
DOC=docs/PACKAGING.md
FIXTURES=packaging/install/testdata/os-release
GATE_IMAGE=${GATE_IMAGE:-arm64v8/ubuntu:24.04}
ONLY=${1-}

for f in "$GATE_DETECT" "$GATE_INSTALL" "$INSTALLER" "$DOC"; do
  [ -f "$f" ] || { echo "FATAL: $f is missing" >&2; exit 2; }
done
[ -d "$FIXTURES" ] || { echo "FATAL: $FIXTURES is missing (the 7 os-release fixtures are the input)" >&2; exit 2; }

MUT=$(mktemp -d "${TMPDIR:-/tmp}/dlol-install-mutants.XXXXXX")
trap 'rm -rf "$MUT"' EXIT INT TERM
cp "$INSTALLER" "$MUT/installer.base"
cp "$DOC"       "$MUT/doc.base"

# --- the mutation primitive ----------------------------------------------------------------------
# mut_line FILE SUBSTR [REPL]  -- line-oriented, so a mutation cannot silently reformat the rest of
# the file. It asserts that EXACTLY ONE line contains SUBSTR: a mutation that no longer applies (the
# shipped script moved on) must fail the battery loudly instead of quietly testing the pristine file.
mut_line() {
  local f=$1 needle=$2 repl=${3-} tmp=$1.mut
  # `sub` is an awk builtin name: the variable is `needle` (an -v sub=... is a hard awk error).
  if ! awk -v needle="$needle" -v repl="$repl" -v has_repl="${3+set}" '
      { if (index($0, needle)) {
          n++
          if (has_repl == "") next                                   # no replacement: drop the line
          i = index($0, needle); $0 = substr($0, 1, i-1) repl substr($0, i+length(needle))
        }
        print }
      END { if (n != 1) { printf "MUTATION-MISS(%d lines match): %s\n", n, needle > "/dev/stderr"; exit 3 } }' \
      "$f" > "$tmp"; then
    rm -f "$tmp"; return 3
  fi
  mv "$tmp" "$f"
}

# --- the runners ----------------------------------------------------------------------------------
OUT=""; RC=0
gate_detect() { # gate_detect INSTALLER_PATH [FIXTURE_DIR]  -- native: the gate needs no privilege
  set +e
  OUT=$(FIXTURE_DIR="${2-}" bash "$GATE_DETECT" "$1" 2>&1); RC=$?
  set -e
  return 0
}
gate_install() { # gate_install INSTALLER_PATH [DOC_PATH]  -- throwaway container, as root
  local doc=${2-} extra=()
  [ -n "$doc" ] && extra=(-e "INSTALL_DOC=$doc")
  set +e
  OUT=$(docker run --rm -v "$REPO_ROOT":/repo -v "$MUT":/mut -w /repo "${extra[@]}" \
        --entrypoint bash "$GATE_IMAGE" "$GATE_INSTALL" "$1" 2>&1)
  RC=$?
  set -e
  return 0
}
reds_of() { printf '%s' "$OUT" | awk '/^FAIL /{sub(/:$/,"",$2); printf "%s ", $2}'; }

RESULTS=$MUT/results.txt
: > "$RESULTS"
PASS=0; FAILN=0

# expect NAME EXPECTED_ROWS(space-separated; "" = none, i.e. the control)
expect() {
  local name=$1 want=$2 reds missing="" verdict
  reds=$(reds_of)
  for r in $want; do
    case " $reds " in *" $r "*) ;; *) missing="$missing $r" ;; esac
  done
  if printf '%s' "$OUT" | grep -q 'MUTATION-MISS'; then
    verdict="MUTATION-MISS"
  elif [ "$RC" -eq 77 ] || printf '%s' "$OUT" | grep -q '^SKIP'; then
    verdict="SKIPPED"
  elif [ -z "$want" ]; then
    if [ "$RC" -eq 0 ] && [ -z "$reds" ]; then verdict=CONTROL-OK; else verdict="CONTROL-BROKEN(rc=$RC red=$reds)"; fi
  elif [ "$RC" -eq 0 ]; then
    verdict="GATE-BLIND(rc=0: the gate stayed green)"
  elif [ -n "$missing" ]; then
    verdict="WEAK(red=$reds; but not:$missing)"
  else
    verdict="CAUGHT(red=$reds)"
  fi
  case "$verdict" in
    CONTROL-OK|CAUGHT*) PASS=$((PASS+1)) ;;
    *) FAILN=$((FAILN+1)) ;;
  esac
  printf '%-24s %-62s %s\n' "$name" "$verdict" "$(printf '%s' "$OUT" | tail -1)"
  printf '%s\t%s\n' "$name" "$verdict" >> "$RESULTS"
}

echo "== §16 gate mutation battery -- image $GATE_IMAGE =="
echo "installer=$(sha256sum "$INSTALLER" | cut -c1-12) doc=$(sha256sum "$DOC" | cut -c1-12)"
echo

if [ "$ONLY" != "--install-only" ]; then
  echo "-- G-INSTALL-2b ($GATE_DETECT, native) ---------------------------------------------------"
  # control: the unmutated installer must be GREEN (a battery whose control is red measures nothing)
  gate_detect "$INSTALLER"
  expect control-2b ""

  # 1. steamos: the C24 regression. "Tidying" the ID_LIKE token to the distribution's own name
  #    (`*archlinux*`) rejects the Steam Deck. Only this gate sees it (G-INSTALL-7 stays green); it
  #    was the reviewer's nr9 and, before the fixtures travelled with the commit, unreachable.
  cp "$MUT/installer.base" "$MUT/mx_archlinux_token.sh"
  mut_line "$MUT/mx_archlinux_token.sh" '*arch*)  FAMILY=arch; RELEASE=rolling' '*archlinux*) FAMILY=arch; RELEASE=rolling' \
    && { gate_detect "$MUT/mx_archlinux_token.sh"; expect mx_archlinux_token "steamos" "$MUT/mx_archlinux_token.sh"; }

  # 2. alpine: the refusal arm becomes a family assignment, so a distribution this installer has no
  #    package for is silently detected instead of being told to use --method tar.
  cp "$MUT/installer.base" "$MUT/mx_alpine_detects.sh"
  mut_line "$MUT/mx_alpine_detects.sh" '*) die "unsupported distribution' '*) FAMILY=deb; RELEASE=bookworm; : die "unsupported distribution' \
    && { gate_detect "$MUT/mx_alpine_detects.sh"; expect mx_alpine_detects "alpine-refusal" "$MUT/mx_alpine_detects.sh"; }

  # 3. the fixtures themselves: this is a TREE mutation, not an installer one. Pull one fixture out of
  #    the directory the gate reads and the gate must go red -- that is the whole point of MAJOR-4
  #    (the pre-review battery reconstructed the fixtures ad hoc, so nothing in the tree consumed
  #    them, and a fixture that stops travelling with the commit was invisible).
  rm -rf "$MUT/os-release-pruned"; cp -r "$FIXTURES" "$MUT/os-release-pruned"
  rm -f "$MUT/os-release-pruned/steamos"
  gate_detect "$INSTALLER" "$MUT/os-release-pruned"
  expect mx_fixture_dropped "fixtures-present steamos" "$INSTALLER" "$MUT/os-release-pruned"
fi

if [ "$ONLY" != "--detect-only" ]; then
  echo "-- G-INSTALL-3/4 ($GATE_INSTALL, $GATE_IMAGE) -------------------------------------------"
  gate_install "$INSTALLER"
  expect control "" "$INSTALLER"

  # 1. arch-refusal: detect_arch accepts anything (the `x86_64|amd64)` arm is widened to `*)`), so an
  #    arm64 box would take the x86_64 tree and fail later, at mount("overlay"), instead of up front.
  cp "$MUT/installer.base" "$MUT/mx_arch_accept.sh"
  mut_line "$MUT/mx_arch_accept.sh" 'x86_64|amd64) ARCH=x86_64' '*) ARCH=x86_64' \
    && { gate_install /mut/mx_arch_accept.sh; expect mx_arch_accept "arch-refusal" /mut/mx_arch_accept.sh; }

  # 2. dry-run: --dry-run falls through into the install (the `exit 0` that ends the dry-run branch is
  #    gone). The row asserts the side effect, not just the printed prefix.
  cp "$MUT/installer.base" "$MUT/mx_dryrun_falls_through.sh"
  mut_line "$MUT/mx_dryrun_falls_through.sh" 'say "dry run: re-run without --dry-run to install."' \
    'say "dry run: re-run without --dry-run to install." #'
  mut_line "$MUT/mx_dryrun_falls_through.sh" '  exit 0' '  :' \
    && { gate_install /mut/mx_dryrun_falls_through.sh; expect mx_dryrun_falls_through "dry-run" /mut/mx_dryrun_falls_through.sh; }

  # 3. prefix-cross-check: the tar path's prefix drifts to /usr/local while the asset it resolves is
  #    still the /usr tree (the INFO-4 failure mode: 589 MB extracted, then assert_install against the
  #    wrong tree). Implemented as a CONSISTENT drift (set_tar_prefix hard-assigns the legacy prefix,
  #    and its guard accepts it) so the drift reaches the cross-check instead of being caught by the
  #    guard alone -- a mutant that only narrowed one of the two would red the rows for "the dry run
  #    died", not for "the announced prefix differs from the archive's". This mutant is also why
  #    set_tar_prefix() exists: while --dry-run printed the GLOBAL default, the cross-check row stayed
  #    green under exactly this mutation, i.e. the row did not test what it claimed to test.
  cp "$MUT/installer.base" "$MUT/mx_prefix_usrlocal.sh"
  mut_line "$MUT/mx_prefix_usrlocal.sh" 'PREFIX=${PREFIX:-/usr}' 'PREFIX=/usr/local'
  mut_line "$MUT/mx_prefix_usrlocal.sh" '[ "$PREFIX" = /usr ] || die' '[ "$PREFIX" = /usr/local ] || die' \
    && { gate_install /mut/mx_prefix_usrlocal.sh; expect mx_prefix_usrlocal "prefix-refusal dry-run prefix-cross-check" /mut/mx_prefix_usrlocal.sh; }

  # 3b. url-version: the CLI tag stops being restored after /etc/os-release is sourced, so the
  #     download URL is built from the DISTRIBUTION's VERSION ("24.04.5 LTS (Noble Numbat)") and the
  #     "stable channel needs --version" guard can never fire. The review's E12/E13 class (INFO-1):
  #     it lives in this gate because --detect-only exits before the URL is built.
  cp "$MUT/installer.base" "$MUT/mx_version_clobber.sh"
  mut_line "$MUT/mx_version_clobber.sh" 'VERSION=$cli_version' \
    && { gate_install /mut/mx_version_clobber.sh; expect mx_version_clobber "url-version" /mut/mx_version_clobber.sh; }

  # 4. install (the resolver): the versioned asset name drifts (e.g. a release renames the tarball) and
  #    the resolver falls back to the generic glob, where the fixture dir holds TWO matches -- the
  #    fixture tarball and the legacy decoy. Silence here is what the review's R1 found: the fallback
  #    must never be guessed between, so the install row has to go red.
  cp "$MUT/installer.base" "$MUT/mx_asset_glob_generic.sh"
  mut_line "$MUT/mx_asset_glob_generic.sh" "for pat in 'darling-lol-*-linux-x86_64.tar.gz'" "for pat in 'darling-lol-*-nomatchver.tar.gz'"
  mut_line "$MUT/mx_asset_glob_generic.sh" "'darling-lol-*-linux-x86_64.tar.zst' \\" "'darling-lol-*-nomatchver.tar.zst' \\" \
    && { gate_install /mut/mx_asset_glob_generic.sh; expect mx_asset_glob_generic "install" /mut/mx_asset_glob_generic.sh; }

  # 5. setuid: the extraction loses the mode (the review's C3 class: the setuid bit disappears without
  #    anyone noticing). Modelled by chmod-ing 0755 right after the extract.
  cp "$MUT/installer.base" "$MUT/mx_chmod_0755.sh"
  mut_line "$MUT/mx_chmod_0755.sh" 'tar -xp --numeric-owner --no-same-owner -f "$TARBALL" -C /' \
    'tar -xp --numeric-owner --no-same-owner -f "$TARBALL" -C / ; chmod 0755 "$PREFIX/bin/darling"' \
    && { gate_install /mut/mx_chmod_0755.sh; expect mx_chmod_0755 "install setuid" /mut/mx_chmod_0755.sh; }

  # 6. state-file: the member record is not written (or is written from the wrong source), so the
  #    documented removal has nothing to trust -- R2/MAJOR-1.
  cp "$MUT/installer.base" "$MUT/mx_no_state_write.sh"
  mut_line "$MUT/mx_no_state_write.sh" '> "$STATE_FILE.tmp" && mv' ': # state write removed' \
    && { gate_install /mut/mx_no_state_write.sh; expect mx_no_state_write "state-file remove-state" /mut/mx_no_state_write.sh; }

  # 7. no-decoy: the by-name refusal of the legacy /usr/local pair is disabled (turned into a no-op
  #    `:`), so a directory holding only the v0.1.0-era pair is no longer refused by the intended
  #    message. This is the review's R1 regression, measured.
  cp "$MUT/installer.base" "$MUT/mx_allow_legacy_pair.sh"
  mut_line "$MUT/mx_allow_legacy_pair.sh" 'die "$ASSET_DIR holds the legacy' ': disabled "$ASSET_DIR holds the legacy' \
    && { gate_install /mut/mx_allow_legacy_pair.sh; expect mx_allow_legacy_pair "no-decoy" /mut/mx_allow_legacy_pair.sh; }

  # 8/9. the DOCUMENTED removal (rows remove-state / remove-fallback): both rows execute the recipe
  #      between the G-TAR-UNINSTALL markers, so their mutants edit the RECIPE, not the installer --
  #      the rows are only worth anything if a wrong recipe makes them red.
  cp "$MUT/doc.base" "$MUT/doc_varlib_left.sh"
  mut_line "$MUT/doc_varlib_left.sh" 'rm -rf /var/lib/darling-lol' ': # leftover on purpose' \
    && { gate_install "$INSTALLER" /mut/doc_varlib_left.sh; expect mx_doc_leaves_varlib "remove-state" "$INSTALLER" /mut/doc_varlib_left.sh; }

  cp "$MUT/doc.base" "$MUT/doc_fallback_glob_wrong.sh"
  mut_line "$MUT/doc_fallback_glob_wrong.sh" 'tar -tzf darling-lol-*-linux-x86_64.tar.gz' 'tar -tzf darling-lol-*-linux-x86_64.tar.zst' \
    && { gate_install "$INSTALLER" /mut/doc_fallback_glob_wrong.sh; expect mx_doc_fallback_glob "remove-fallback" "$INSTALLER" /mut/doc_fallback_glob_wrong.sh; }
fi

# --- grid -----------------------------------------------------------------------------------------
echo
echo "== grid: mutant -> rows that went red =="
sort -k1,1 "$RESULTS" | while IFS=$'\t' read -r name verdict; do
  printf '  %-24s %s\n' "$name" "$verdict"
done
echo
echo "PASS=$PASS FAIL=$FAILN  (a FAIL means either the gate is blind to that defect, or a row is not measured)"
[ "$FAILN" -eq 0 ] || exit 1
echo "§16 gates: every row of both gates is measured"
