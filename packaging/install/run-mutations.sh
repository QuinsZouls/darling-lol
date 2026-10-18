#!/usr/bin/env bash
# packaging/install/run-mutations.sh -- the SELF-TEST of the three §16 install gates:
#
#   packaging/install/test-detect.sh   G-INSTALL-2b  (distro detection over the 7 in-tree fixtures)
#   packaging/install/test-install.sh  G-INSTALL-3/4 (the tarball install, its state file, the
#                                                     documented removal, setuid, the prefix check)
#   packaging/install/test-nonroot.sh  G-INSTALL-7  (the non-root negative control: 10 refusals +
#                                                     2 hostile --prefix cases + 2 positives)
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
# TWO MUTANT CLASSES (review salvedad C3):
#   * class A mutates the ARTEFACT under test -- the shipped installer, or the documented recipe --
#     and asks the question a gate exists to answer: "would this gate notice this defect at all?"
#   * class B mutates the GATE ITSELF, which is what class A structurally cannot reach. G-INSTALL-7
#     counts its own cases and PINS their totals (row `noroot-rows`); a pinned number that is never
#     shown to move is one more unmeasured assertion, so the only way to demonstrate that the pin is
#     load-bearing is to move the gate's case list and watch `noroot-rows` react. Each of the four
#     `mx_noroot_drop_*` mutants deletes one case (so each of the pin's three `-ge` statements (the
#     floor), and the --dry-run sub-list, is measured by its own mutant), and `mx_noroot_add_method`
#     does the opposite: it ADDS a 6th method and must leave the gate GREEN (the pin is a floor:
#     extra coverage is not a defect), while moving the count to 12. That mutant is also the future
#     detector for anyone flipping the pin back to `-eq` (measured: with `-eq` it turns the gate red,
#     and this check then fails the battery).
#
# 🚨 WHAT `noroot-rows` CANNOT SEE, and what covers it instead. The floor catches a case that
# DISAPPEARED; it is blind to a SWAP that keeps a half's count flat (renaming `pacman` to `zypper`
# still counts 10). That direction is covered by the class-A mutant's expected row SET (below),
# which pins the ten refusal row NAMES. The hostile/positive names are covered by nothing -- those
# halves are counted only (recorded as a known limit in the report, not an accident).
#
# 🚨 `expect` TAKES TWO ARGUMENTS: NAME and EXPECTED_ROWS (a space-separated list of row names).
#   * `row`  = that row MUST be red (this is what makes a mutant CAUGHT, and what makes a WEAK
#              verdict when one of the expected names did not go red).
#   * `!row` = that row must NOT be red. Used on the class-A mutant for the two positive rows,
#              which exit before `require_root` and therefore can never be red for the mutation's
#              own reason: a red set that contains them means the ENVIRONMENT redded everything
#              (B2), not that the mutation was caught. A call site without any `!` behaves exactly
#              as before.
#
# 🚨 TWO PRECONDITIONS ARE MEASURED, NOT ASSUMED (B2):
#   * `gate_noroot` runs `chmod -R a+rX "$MUT"` before every run. `mktemp -d` makes the tree 0700
#     *and* `mut_line`'s `awk >`/`cp` honour the caller's umask, so without it (or under `umask
#     077`) every `/mut/*.sh` is unreadable by the uid G-INSTALL-7 drops into, EVERY case dies with
#     rc 126 and the one artefact-side mutant ("CAUGHT", all 14 rows red) is a lie.
#   * before the gate runs, the same container drops to uid 65431 and reads the two scripts by
#     name. If either is unreadable it prints `FAIL mount-not-readable: <path> ...` and exits 1
#     WITHOUT running the gate: the one `chmod` line above is therefore load-bearing and its
#     removal is a battery FAIL, not a silently different red set.
#
# 🚨 A DRIFTED NEEDLE IS A BATTERY FAIL (R1). Every check is `mut_line ... && { gate; expect; } ||
# mutation_miss NAME NEEDLE`, so a needle that no longer applies makes the battery fail by name
# (verdict `MUTATION-MISS`) instead of skipping the `expect` call and silently deleting the check
# from the roster (`mut_line` already printed MUTATION-MISS, but it wrote to stderr and the `&&`
# skipped the verdict -- measured: PASS 4 -> 3 with rc 0 at HEAD). The `MUTATION-MISS` branch of
# `expect` is reachable now and counts as a FAIL.
#
#   ./packaging/install/run-mutations.sh                 # everything (needs docker for 3/4 and 7)
#   GATE_IMAGE=ubuntu:24.04 ./packaging/install/run-mutations.sh
#   ./packaging/install/run-mutations.sh --detect-only   # G-INSTALL-2b only: no docker, no root
#   ./packaging/install/run-mutations.sh --install-only  # G-INSTALL-3/4 only (docker, as root)
#   ./packaging/install/run-mutations.sh --noroot-only   # G-INSTALL-7 only (docker, as root)
#
# 🚨 ARCH / IMAGE. G-INSTALL-2b is machine-independent and runs natively here (it is the unprivileged
# half). G-INSTALL-3/4 installs a fixture tree and needs a throwaway container as root, and its
# fixture is x86_64, so the gate carries its own `uname` shim (see its header) -- which makes this
# whole battery work on an arm64 box: `arch-refusal` is the only row that needs the REAL arch, and its
# mutant replacement (mx_arch_accept) is exactly the mutation that makes it red. On x86_64 the gate
# SKIPs that row and its mutant reports WEAK; that is the single expected difference.
# G-INSTALL-7 also needs the container as ROOT (it creates an unprivileged uid and then drops into it
# with setpriv itself), so the image must carry util-linux (`setpriv`) and passwd (`useradd`/
# `groupadd`); ubuntu:24.04 has both, and needs no network.
#
# Requires for the install halves: docker, and the image below (pull it first).
set -u

# 🚨 022, explicitly: the mutant files are written with `awk >` and `cp`, which both honour the
# caller's umask, and they have to be readable by the unprivileged uid G-INSTALL-7 drops into.
# A caller running `( umask 077; packaging/install/run-mutations.sh )` would otherwise make every
# /mut/*.sh 0600 and re-open the false-CAUGHT that B2 is about (measured). gate_noroot also chmods
# the tree before every run AND measures the precondition; this line makes the default path right
# by construction instead of by luck.
umask 022

REPO_ROOT=$(cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$REPO_ROOT"

GATE_DETECT=packaging/install/test-detect.sh
GATE_INSTALL=packaging/install/test-install.sh
GATE_NOROOT=packaging/install/test-nonroot.sh
INSTALLER=packaging/install/darling-lol-install.sh
DOC=docs/PACKAGING.md
FIXTURES=packaging/install/testdata/os-release
GATE_IMAGE=${GATE_IMAGE:-arm64v8/ubuntu:24.04}
ONLY=${1-}

# The 10 refusal rows the class-A mutant must turn red, spelled out: one per method x {plain,
# --dry-run}. The assertion is on the SET, not on "some row", because these are the rows a
# require_root bypass has to break (each case asserts the exit code, the docs pointer and the two
# literal sentences, and the row is red when ANY of them stops holding).
NOROOT_REFUSAL_ROWS="noroot-refusal-auto noroot-refusal-auto-dryrun \
noroot-refusal-apt noroot-refusal-apt-dryrun \
noroot-refusal-dnf noroot-refusal-dnf-dryrun \
noroot-refusal-pacman noroot-refusal-pacman-dryrun \
noroot-refusal-tar noroot-refusal-tar-dryrun"

# The two POSITIVE rows, NEGATED, for the class-A mutant: `--help`/`--detect-only` exit BEFORE
# require_root, so the mutation cannot legitimately red them -- if they are red anyway, the
# environment failed (an unreadable /mut tree reds all 14 rows) and the verdict must say WRONG-REDS
# instead of CAUGHT. Only these two: on an arch where the weakened installer gets past detect_arch,
# the hostile rows may red for reasons that are still the mutation's fault.
NOROOT_NEGATED_POSITIVE_ROWS="!noroot-positive-help !noroot-positive-detect-only"

for f in "$GATE_DETECT" "$GATE_INSTALL" "$GATE_NOROOT" "$INSTALLER" "$DOC"; do
  [ -f "$f" ] || { echo "FATAL: $f is missing" >&2; exit 2; }
done
[ -d "$FIXTURES" ] || { echo "FATAL: $FIXTURES is missing (the 7 os-release fixtures are the input)" >&2; exit 2; }

MUT=$(mktemp -d "${TMPDIR:-/tmp}/dlol-install-mutants.XXXXXX")
trap 'rm -rf "$MUT"' EXIT INT TERM
# 🚨 $MUT must be TRAVERSABLE AND READABLE by the unprivileged uid G-INSTALL-7 drops into (65431):
# mktemp -d makes the DIRECTORY 0700 (the container cannot traverse it), and the mutant FILES
# inherit the caller's umask (see `umask 022` above). Both halves of that precondition are closed
# explicitly in `gate_noroot` -- `chmod -R a+rX "$MUT"` before every run -- and are MEASURED there
# (the `mount-not-readable` probe), which is also what makes that one chmod line load-bearing.
# Deliberately not here: the tree keeps growing as mutants are written, so a one-shot chmod at this
# point fixes only the three base copies, which is exactly how the original `chmod 0755 "$MUT"`
# stayed incomplete under `umask 077` (measured). `a+rX` leaks nothing: this tree holds only copies
# of files that are already in the repo.
cp "$INSTALLER" "$MUT/installer.base"
cp "$DOC"       "$MUT/doc.base"
# class B mutates the GATE, so it needs the gate's own pristine bytes: mutating the file in the
# working tree would edit what we are measuring (and would leave the tree dirty).
cp "$GATE_NOROOT" "$MUT/noroot.base"

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
gate_noroot() { # gate_noroot GATE_PATH [INSTALLER_PATH]  -- throwaway container, AS ROOT.
                # G-INSTALL-7 creates the unprivileged uid and then drops into it itself with
                # `setpriv`, so the container must be root; the gate's own SKIP/exit 77 is what
                # protects a box where that is impossible.
  local gate=$1 inst=${2-$INSTALLER}
  # 🚨 THE PRECONDITION (B2), measured before any verdict is read. Nothing the gate must read as
  # uid 65431 may be unreadable: if it is, EVERY case dies with rc 126 and a class-A mutant shows
  # up as "CAUGHT(red=all 14 rows)" without the mutation having done anything. `chmod -R a+rX`
  # closes both halves of it (the directory mktemp -d made 0700, and the mutant files written under
  # the caller's umask), and the probe below MEASURES it -- a deleted/incomplete chmod is then a
  # battery FAIL with a named row (`mount-not-readable`) instead of a plausible-looking red set.
  # The probe and the gate share ONE container (a separate probe run per check would double the
  # container count for no extra information); on success the probe is silent.
  chmod -R a+rX "$MUT" 2>/dev/null || true
  set +e
  OUT=$(docker run --rm -v "$REPO_ROOT":/repo -v "$MUT":/mut -w /repo --entrypoint bash \
        "$GATE_IMAGE" -c '
          for p in "$@"; do
            setpriv --reuid=65431 --regid=65431 --clear-groups head -c0 "$p" >/dev/null 2>&1 && continue
            printf "FAIL mount-not-readable: %s is not readable by uid 65431; the /mut tree must be a+rX (gate_noroot chmods it before every run), or every case dies with rc 126 and this mutant looks CAUGHT for the wrong reason\n" "$p"
            exit 1
          done
          exec bash "$1" "$2"' _ "$gate" "$inst" 2>&1)
  RC=$?
  set -e
  return 0
}
reds_of() { printf '%s' "$OUT" | awk '/^FAIL /{sub(/:$/,"",$2); printf "%s ", $2}'; }

RESULTS=$MUT/results.txt
: > "$RESULTS"
PASS=0; FAILN=0; CONTROLS=0; MUTANTS=0; CHECKS=0

# expect NAME EXPECTED_ROWS
#   EXPECTED_ROWS is a space-separated list: `row` = MUST be red, `!row` = must NOT be red. The
#   negated token exists for the class-A mutant, whose two positive rows exit before `require_root`
#   and so can never be red for the mutation's own reason: a red set containing them means the
#   ENVIRONMENT failed, not that the mutation was caught. A call with no `!` produces the same
#   verdicts and counters it produced before the token existed (verified by a before/after diff).
#   Every check reaches this function exactly once (a drifted needle goes through `mutation_miss`
#   below), so the roster cannot shrink silently; CHECKS is printed in the summary.
expect() {
  local name=$1 want="" tok reds missing="" unexpected="" verdict
  reds=$(reds_of)
  for tok in ${2-}; do
    case "$tok" in
      '!'*) case " $reds " in *" ${tok#!} "*) unexpected="$unexpected ${tok#!}" ;; esac ;;
      *)    want="$want $tok" ;;
    esac
  done
  for r in $want; do
    case " $reds " in *" $r "*) ;; *) missing="$missing $r" ;; esac
  done
  if printf '%s' "$OUT" | grep -q 'MUTATION-MISS'; then
    verdict="MUTATION-MISS"
  elif [ "$RC" -eq 77 ] || printf '%s' "$OUT" | grep -q '^SKIP'; then
    verdict="SKIPPED"
  elif [ -n "$unexpected" ]; then
    # BEFORE WEAK/CAUGHT on purpose: a red set that contains a row which cannot legitimately be red
    # must never read as a caught mutation (both of those verdicts would).
    verdict="WRONG-REDS(rc=$RC; must not be red:$unexpected red=$reds)"
  elif [ -z "$want" ]; then
    if [ "$RC" -eq 0 ] && [ -z "$reds" ]; then verdict=CONTROL-OK; else verdict="CONTROL-BROKEN(rc=$RC red=$reds)"; fi
  elif [ "$RC" -eq 0 ]; then
    verdict="GATE-BLIND(rc=0: the gate stayed green)"
  elif [ -n "$missing" ]; then
    verdict="WEAK(red=$reds; but not:$missing)"
  else
    verdict="CAUGHT(red=$reds)"
  fi
  CHECKS=$((CHECKS+1))
  case "$verdict" in
    CONTROL-OK) PASS=$((PASS+1)); CONTROLS=$((CONTROLS+1)) ;;
    CAUGHT*)    PASS=$((PASS+1)); MUTANTS=$((MUTANTS+1)) ;;
    *) FAILN=$((FAILN+1)) ;;
  esac
  printf '%-24s %-62s %s\n' "$name" "$verdict" "$(printf '%s' "$OUT" | tail -1)"
  printf '%s\t%s\n' "$name" "$verdict" >> "$RESULTS"
  return 0   # `mut_line ... && { gate; expect; } || mutation_miss ...` relies on this being 0
}

# mutation_miss MUTANT NEEDLE -- a needle that no longer applies must FAIL the battery BY NAME
# (naming the mutant and the needle) instead of quietly deleting the check from the roster (R1).
# It goes through `expect` so the row is counted and printed in the grid; the previously
# unreachable `MUTATION-MISS` branch is now exactly the verdict a drifted needle gets, and it is a
# FAIL rather than a pass.
mutation_miss() {
  OUT="FAIL $1: mut_line does not apply any more (MUTATION-MISS): $2"
  RC=1
  expect "$1" ""
}

echo "== §16 gate mutation battery -- image $GATE_IMAGE =="
echo "installer=$(sha256sum "$INSTALLER" | cut -c1-12) doc=$(sha256sum "$DOC" | cut -c1-12) noroot-gate=$(sha256sum "$GATE_NOROOT" | cut -c1-12)"
echo

if [ "$ONLY" != "--install-only" ] && [ "$ONLY" != "--noroot-only" ]; then
  echo "-- G-INSTALL-2b ($GATE_DETECT, native) ---------------------------------------------------"
  # control: the unmutated installer must be GREEN (a battery whose control is red measures nothing)
  gate_detect "$INSTALLER"
  expect control-2b ""

  # 1. steamos: the C24 regression. "Tidying" the ID_LIKE token to the distribution's own name
  #    (`*archlinux*`) rejects the Steam Deck. Only this gate sees it (G-INSTALL-7 stays green); it
  #    was the reviewer's nr9 and, before the fixtures travelled with the commit, unreachable.
  cp "$MUT/installer.base" "$MUT/mx_archlinux_token.sh"
  mut_line "$MUT/mx_archlinux_token.sh" '*arch*)  FAMILY=arch; RELEASE=rolling' '*archlinux*) FAMILY=arch; RELEASE=rolling' \
    && { gate_detect "$MUT/mx_archlinux_token.sh"; expect mx_archlinux_token "steamos"; } \
    || mutation_miss mx_archlinux_token '*arch*)  FAMILY=arch; RELEASE=rolling'

  # 2. alpine: the refusal arm becomes a family assignment, so a distribution this installer has no
  #    package for is silently detected instead of being told to use --method tar.
  cp "$MUT/installer.base" "$MUT/mx_alpine_detects.sh"
  mut_line "$MUT/mx_alpine_detects.sh" '*) die "unsupported distribution' '*) FAMILY=deb; RELEASE=bookworm; : die "unsupported distribution' \
    && { gate_detect "$MUT/mx_alpine_detects.sh"; expect mx_alpine_detects "alpine-refusal"; } \
    || mutation_miss mx_alpine_detects '*) die "unsupported distribution'

  # 3. the fixtures themselves: this is a TREE mutation, not an installer one. Pull one fixture out of
  #    the directory the gate reads and the gate must go red -- that is the whole point of MAJOR-4
  #    (the pre-review battery reconstructed the fixtures ad hoc, so nothing in the tree consumed
  #    them, and a fixture that stops travelling with the commit was invisible).
  rm -rf "$MUT/os-release-pruned"; cp -r "$FIXTURES" "$MUT/os-release-pruned"
  rm -f "$MUT/os-release-pruned/steamos"
  # (no mut_line here: this one is a TREE mutation, so there is no needle to drift)
  gate_detect "$INSTALLER" "$MUT/os-release-pruned"
  expect mx_fixture_dropped "fixtures-present steamos"
fi

if [ "$ONLY" != "--detect-only" ] && [ "$ONLY" != "--noroot-only" ]; then
  echo "-- G-INSTALL-3/4 ($GATE_INSTALL, $GATE_IMAGE) -------------------------------------------"
  gate_install "$INSTALLER"
  expect control ""

  # 1. arch-refusal: detect_arch accepts anything (the `x86_64|amd64)` arm is widened to `*)`), so an
  #    arm64 box would take the x86_64 tree and fail later, at mount("overlay"), instead of up front.
  cp "$MUT/installer.base" "$MUT/mx_arch_accept.sh"
  mut_line "$MUT/mx_arch_accept.sh" 'x86_64|amd64) ARCH=x86_64' '*) ARCH=x86_64' \
    && { gate_install /mut/mx_arch_accept.sh; expect mx_arch_accept "arch-refusal"; } \
    || mutation_miss mx_arch_accept 'x86_64|amd64) ARCH=x86_64'

  # 2. dry-run: --dry-run falls through into the install (the `exit 0` that ends the dry-run branch is
  #    gone). The row asserts the side effect, not just the printed prefix.
  cp "$MUT/installer.base" "$MUT/mx_dryrun_falls_through.sh"
  mut_line "$MUT/mx_dryrun_falls_through.sh" 'say "dry run: re-run without --dry-run to install."' \
    'say "dry run: re-run without --dry-run to install." #' \
    || mutation_miss mx_dryrun_falls_through 'say "dry run: re-run without --dry-run to install."'
  mut_line "$MUT/mx_dryrun_falls_through.sh" '  exit 0' '  :' \
    && { gate_install /mut/mx_dryrun_falls_through.sh; expect mx_dryrun_falls_through "dry-run"; } \
    || mutation_miss mx_dryrun_falls_through '  exit 0'

  # 3. prefix-cross-check: the tar path's prefix drifts to /usr/local while the asset it resolves is
  #    still the /usr tree (the INFO-4 failure mode: 589 MB extracted, then assert_install against the
  #    wrong tree). Implemented as a CONSISTENT drift (set_tar_prefix hard-assigns the legacy prefix,
  #    and its guard accepts it) so the drift reaches the cross-check instead of being caught by the
  #    guard alone -- a mutant that only narrowed one of the two would red the rows for "the dry run
  #    died", not for "the announced prefix differs from the archive's". This mutant is also why
  #    set_tar_prefix() exists: while --dry-run printed the GLOBAL default, the cross-check row stayed
  #    green under exactly this mutation, i.e. the row did not test what it claimed to test.
  cp "$MUT/installer.base" "$MUT/mx_prefix_usrlocal.sh"
  mut_line "$MUT/mx_prefix_usrlocal.sh" 'PREFIX=${PREFIX:-/usr}' 'PREFIX=/usr/local' \
    || mutation_miss mx_prefix_usrlocal 'PREFIX=${PREFIX:-/usr}'
  mut_line "$MUT/mx_prefix_usrlocal.sh" '[ "$PREFIX" = /usr ] || die' '[ "$PREFIX" = /usr/local ] || die' \
    && { gate_install /mut/mx_prefix_usrlocal.sh; expect mx_prefix_usrlocal "prefix-refusal dry-run prefix-cross-check"; } \
    || mutation_miss mx_prefix_usrlocal '[ "$PREFIX" = /usr ] || die'

  # 3b. url-version: the CLI tag stops being restored after /etc/os-release is sourced, so the
  #     download URL is built from the DISTRIBUTION's VERSION ("24.04.5 LTS (Noble Numbat)") and the
  #     "stable channel needs --version" guard can never fire. The review's E12/E13 class (INFO-1):
  #     it lives in this gate because --detect-only exits before the URL is built.
  cp "$MUT/installer.base" "$MUT/mx_version_clobber.sh"
  mut_line "$MUT/mx_version_clobber.sh" 'VERSION=$cli_version' \
    && { gate_install /mut/mx_version_clobber.sh; expect mx_version_clobber "url-version"; } \
    || mutation_miss mx_version_clobber 'VERSION=$cli_version'

  # 4. install (the resolver): the versioned asset name drifts (e.g. a release renames the tarball) and
  #    the resolver falls back to the generic glob, where the fixture dir holds TWO matches -- the
  #    fixture tarball and the legacy decoy. Silence here is what the review's R1 found: the fallback
  #    must never be guessed between, so the install row has to go red.
  cp "$MUT/installer.base" "$MUT/mx_asset_glob_generic.sh"
  mut_line "$MUT/mx_asset_glob_generic.sh" "for pat in 'darling-lol-*-linux-x86_64.tar.gz'" "for pat in 'darling-lol-*-nomatchver.tar.gz'" \
    || mutation_miss mx_asset_glob_generic "for pat in 'darling-lol-*-linux-x86_64.tar.gz'"
  mut_line "$MUT/mx_asset_glob_generic.sh" "'darling-lol-*-linux-x86_64.tar.zst' \\" "'darling-lol-*-nomatchver.tar.zst' \\" \
    && { gate_install /mut/mx_asset_glob_generic.sh; expect mx_asset_glob_generic "install"; } \
    || mutation_miss mx_asset_glob_generic "'darling-lol-*-linux-x86_64.tar.zst' \\"

  # 5. setuid: the extraction loses the mode (the review's C3 class: the setuid bit disappears without
  #    anyone noticing). Modelled by chmod-ing 0755 right after the extract.
  cp "$MUT/installer.base" "$MUT/mx_chmod_0755.sh"
  mut_line "$MUT/mx_chmod_0755.sh" 'tar -xp --numeric-owner --no-same-owner -f "$TARBALL" -C /' \
    'tar -xp --numeric-owner --no-same-owner -f "$TARBALL" -C / ; chmod 0755 "$PREFIX/bin/darling"' \
    && { gate_install /mut/mx_chmod_0755.sh; expect mx_chmod_0755 "install setuid"; } \
    || mutation_miss mx_chmod_0755 'tar -xp --numeric-owner --no-same-owner -f "$TARBALL" -C /'

  # 6. state-file: the member record is not written (or is written from the wrong source), so the
  #    documented removal has nothing to trust -- R2/MAJOR-1.
  cp "$MUT/installer.base" "$MUT/mx_no_state_write.sh"
  mut_line "$MUT/mx_no_state_write.sh" '> "$STATE_FILE.tmp" && mv' ': # state write removed' \
    && { gate_install /mut/mx_no_state_write.sh; expect mx_no_state_write "state-file remove-state"; } \
    || mutation_miss mx_no_state_write '> "$STATE_FILE.tmp" && mv'

  # 7. no-decoy: the by-name refusal of the legacy /usr/local pair is disabled (turned into a no-op
  #    `:`), so a directory holding only the v0.1.0-era pair is no longer refused by the intended
  #    message. This is the review's R1 regression, measured.
  cp "$MUT/installer.base" "$MUT/mx_allow_legacy_pair.sh"
  mut_line "$MUT/mx_allow_legacy_pair.sh" 'die "$ASSET_DIR holds the legacy' ': disabled "$ASSET_DIR holds the legacy' \
    && { gate_install /mut/mx_allow_legacy_pair.sh; expect mx_allow_legacy_pair "no-decoy"; } \
    || mutation_miss mx_allow_legacy_pair 'die "$ASSET_DIR holds the legacy'

  # 8/9. the DOCUMENTED removal (rows remove-state / remove-fallback): both rows execute the recipe
  #      between the G-TAR-UNINSTALL markers, so their mutants edit the RECIPE, not the installer --
  #      the rows are only worth anything if a wrong recipe makes them red.
  cp "$MUT/doc.base" "$MUT/doc_varlib_left.sh"
  mut_line "$MUT/doc_varlib_left.sh" 'rm -rf /var/lib/darling-lol' ': # leftover on purpose' \
    && { gate_install "$INSTALLER" /mut/doc_varlib_left.sh; expect mx_doc_leaves_varlib "remove-state"; } \
    || mutation_miss mx_doc_leaves_varlib 'rm -rf /var/lib/darling-lol'

  cp "$MUT/doc.base" "$MUT/doc_fallback_glob_wrong.sh"
  mut_line "$MUT/doc_fallback_glob_wrong.sh" 'tar -tzf darling-lol-*-linux-x86_64.tar.gz' 'tar -tzf darling-lol-*-linux-x86_64.tar.zst' \
    && { gate_install "$INSTALLER" /mut/doc_fallback_glob_wrong.sh; expect mx_doc_fallback_glob "remove-fallback"; } \
    || mutation_miss mx_doc_fallback_glob 'tar -tzf darling-lol-*-linux-x86_64.tar.gz'
fi

if [ "$ONLY" != "--detect-only" ] && [ "$ONLY" != "--install-only" ]; then
  echo "-- G-INSTALL-7 ($GATE_NOROOT, $GATE_IMAGE, as root) ---------------------------------------"
  # control: the unmutated gate must be GREEN, and green with the numbers it prints -- the gate's
  # own summary is derived from its counters, so a control here also asserts that the counts are
  # still at least 10/2/2 (row `noroot-rows` would be the one to go red).
  gate_noroot "$GATE_NOROOT"
  expect control-noroot ""

  # ---- class A: the ARTEFACT (the shipped installer). require_root is the precondition every
  #      refusal row asserts; weakened, the 10 refusal rows must all go red. This is the mutation
  #      that proves the gate can fail at all -- before C3, no mutant touched test-nonroot.sh, so
  #      nothing in the tree had ever shown a G-INSTALL-7 row to be capable of failing.
  #      The two `!` tokens are the B2-3 guard: `--help`/`--detect-only` exit BEFORE require_root,
  #      so they cannot be red for this mutation's own reason -- if they are red the ENVIRONMENT
  #      failed (an unreadable /mut tree makes every case die with rc 126) and the verdict must not
  #      be CAUGHT. Only those two: the hostile rows may legitimately red on another arch, where the
  #      weakened installer gets past detect_arch and then dies with a different status.
  cp "$MUT/installer.base" "$MUT/mx_root_never_refuses.sh"
  mut_line "$MUT/mx_root_never_refuses.sh" \
    'if [ "${EUID:-$(id -u)}" -eq 0 ]; then return 0; fi' 'if :; then return 0; fi' \
    && { gate_noroot "$GATE_NOROOT" /mut/mx_root_never_refuses.sh
         expect mx_root_never_refuses "$NOROOT_REFUSAL_ROWS $NOROOT_NEGATED_POSITIVE_ROWS"
       } \
    || mutation_miss mx_root_never_refuses 'if [ "${EUID:-$(id -u)}" -eq 0 ]; then return 0; fi'

  # ---- class B: the GATE's own case list, i.e. its counted-and-pinned totals. Four mutants DELETE
  #      one case each (the refusal half twice -- the method list and the --dry-run list -- then the
  #      hostile half and the positive half), and the pin (`noroot-rows`) is the row that has to
  #      notice, so each of the pin's three `-ge` statements (the floor) is measured by its own
  #      mutant. The fifth one ADDS a case and must stay green: the pin is a FLOOR, so the ADD
  #      direction is measured too, and that mutant is the detector for anyone flipping the pin back
  #      to `-eq` (measured: it then fails the battery).
  #      Without these, the pin would be one more assertion nobody ever showed to move -- the exact
  #      defect C3 reported for the OK line.
  cp "$MUT/noroot.base" "$MUT/mx_noroot_drop_method.sh"
  mut_line "$MUT/mx_noroot_drop_method.sh" 'for m in auto apt dnf pacman tar; do' 'for m in auto apt dnf tar; do' \
    && { gate_noroot /mut/mx_noroot_drop_method.sh; expect mx_noroot_drop_method "noroot-rows"; } \
    || mutation_miss mx_noroot_drop_method 'for m in auto apt dnf pacman tar; do'

  cp "$MUT/noroot.base" "$MUT/mx_noroot_drop_dryrun.sh"
  mut_line "$MUT/mx_noroot_drop_dryrun.sh" 'for extra in "" "--dry-run"; do' 'for extra in ""; do' \
    && { gate_noroot /mut/mx_noroot_drop_dryrun.sh; expect mx_noroot_drop_dryrun "noroot-rows"; } \
    || mutation_miss mx_noroot_drop_dryrun 'for extra in "" "--dry-run"; do'

  cp "$MUT/noroot.base" "$MUT/mx_noroot_drop_hostile.sh"
  mut_line "$MUT/mx_noroot_drop_hostile.sh" 'hostile_case noroot-hostile-prefix-tar' \
    && { gate_noroot /mut/mx_noroot_drop_hostile.sh; expect mx_noroot_drop_hostile "noroot-rows"; } \
    || mutation_miss mx_noroot_drop_hostile 'hostile_case noroot-hostile-prefix-tar'

  cp "$MUT/noroot.base" "$MUT/mx_noroot_drop_positive.sh"
  mut_line "$MUT/mx_noroot_drop_positive.sh" 'for a in --help --detect-only; do' 'for a in --help; do' \
    && { gate_noroot /mut/mx_noroot_drop_positive.sh; expect mx_noroot_drop_positive "noroot-rows"; } \
    || mutation_miss mx_noroot_drop_positive 'for a in --help --detect-only; do'

  # the ADD direction: a 6th method is MORE coverage, so the floor must stay green and the count is
  # legitimately 12. This check has an EMPTY expectation on purpose (CONTROL-OK is the expected
  # verdict); `expect` can never turn a non-empty red set into a pass with an empty expectation --
  # that arm is CONTROL-BROKEN -- so a gate that reds here still fails the battery.
  cp "$MUT/noroot.base" "$MUT/mx_noroot_add_method.sh"
  mut_line "$MUT/mx_noroot_add_method.sh" 'for m in auto apt dnf pacman tar; do' 'for m in auto apt dnf pacman tar zypper; do' \
    && { gate_noroot /mut/mx_noroot_add_method.sh; expect mx_noroot_add_method ""; } \
    || mutation_miss mx_noroot_add_method 'for m in auto apt dnf pacman tar; do'
fi

# --- grid -----------------------------------------------------------------------------------------
echo
echo "== grid: mutant -> rows that went red =="
sort -k1,1 "$RESULTS" | while IFS=$'\t' read -r name verdict; do
  printf '  %-24s %s\n' "$name" "$verdict"
done
echo
echo "PASS=$PASS FAIL=$FAILN CHECKS=$CHECKS  (a FAIL means either the gate is blind to that defect, or a row is not measured)"
[ "$FAILN" -eq 0 ] || exit 1
echo "§16 gates (2b + 3/4 + 7): $CONTROLS green controls, $MUTANTS mutants caught, $FAILN failed, $CHECKS checks run"
echo "  -- class A = the artefact (the shipped installer, or the documented recipe)"
echo "  -- class B = G-INSTALL-7's own case list: 4 mutants DELETE one case each (the pin must red),"
echo "     1 ADDS a case and must stay green, because the pin is a floor (extra coverage is not a defect)"
