#!/usr/bin/env bash
# packaging/install/test-nonroot.sh -- G-INSTALL-7, the non-root negative control (PLAN §16.9).
#
# Runs locally (needs one `setpriv`, i.e. root or a container) and in CI inside ubuntu:24.04:
#
#   bash packaging/install/test-nonroot.sh packaging/install/darling-lol-install.sh
#   docker run --rm -v "$PWD":/repo -w /repo ubuntu:24.04 \
#     bash packaging/install/test-nonroot.sh packaging/install/darling-lol-install.sh
#
# Three halves, and none of them is decoration:
#   (i)   refusal  -- 5 methods x {with, without --dry-run} = 10 cases, each asserted on the exit
#                     code, the docs pointer, the two literal sentences, and an untouched
#                     $HOME/$TMPDIR.
#   (ii)  hostile  -- 2 --prefix cases: no code path may write into $HOME as a non-root user,
#                     whatever flag claims to enable it (half (i) never passes --prefix, so it
#                     cannot see this).
#   (iii) positive -- --help and --detect-only must still work unprivileged, or the gate would
#                     also pass for a script that always exits 1.
#
# 🚨 COUNTED AND PINNED (review salvedad C3). The three halves are COUNTED -- one increment per
# case that actually ran -- and their totals are PINNED by the row `noroot-rows`, and the
# summary line prints those counters, never literals. Before this, the OK line was a literal
# string: a copy of this file with `pacman` (or the whole --dry-run loop) deleted printed the
# identical "10 refusals" line and exited 0, so the numbers were an assertion rather than a
# measurement.
# The pin is FAIL-ONLY, implemented as a FLOOR (`-ge PIN || bad`: fail only when the count is BELOW
# the pin): a case that is ADDED must not turn the gate red -- extra coverage is not a defect --
# while a case that DISAPPEARED must. Both directions are measured, not promised:
# run-mutations.sh's `mx_noroot_add_method` mutant adds a 6th method and expects the gate to stay
# GREEN with the count at 12, and the four `mx_noroot_drop_*` mutants each delete one case of one
# half and expect `noroot-rows` to go red.
# ⚠ The floor deliberately does NOT see a SWAP that keeps a half's count flat (renaming `pacman` to
# `zypper` still counts 10, and a pristine swapped gate prints the identical OK line). That
# direction is covered where the names live: the class-A mutant in run-mutations.sh asserts the
# ten refusal row NAMES, so a swap makes the harness report
# `missing = noroot-refusal-pacman noroot-refusal-pacman-dryrun` (WEAK) and fail the battery.
# Neither direction is covered by the hostiles/positives names -- those halves are counted only
# (recorded in the report as a known limit).
#
# 🚨 ROW PROTOCOL. Every failure is reported as `FAIL <row-name>: <message>`, the same convention as
# the two sibling gates (test-detect.sh: `bad()`, G-INSTALL-2b; test-install.sh: `bad()`,
# G-INSTALL-3/4), because packaging/install/run-mutations.sh parses exactly that shape (`reds_of()`)
# to assert that the row meant to catch a defect is among the rows that went red. WITHOUT it, a
# G-INSTALL-7 failure is invisible to the battery: no red row, no verdict, no measurement.
# ONE ROW PER CASE (the sub-assertions of a case are folded into its message), not one row per
# sub-assertion: the battery pins the row NAMES, and a per-sub-assertion scheme would make the
# expected red-row set depend on which sub-assertion happens to fire first -- i.e. on the machine's
# arch and on the installer's step order. The stable row names are:
#
#   noroot-refusal-<method>              methods: auto apt dnf pacman tar (5, without --dry-run)
#   noroot-refusal-<method>-dryrun       the same 5 with --dry-run
#   noroot-hostile-prefix                --prefix $HOME/x
#   noroot-hostile-prefix-tar            --prefix $HOME/x --method tar
#   noroot-positive-help                 --help works unprivileged
#   noroot-positive-detect-only          --detect-only works unprivileged
#   noroot-rows                          the pinned-total FLOOR assertion (>= 10/2/2, fail-only)
#
# 🚨 A SKIP exits 77, which is NOT a pass: the caller must treat it as a failure (rule 7 in
# TASKS.md). The gate is meaningless without an unprivileged uid, so pretending otherwise would be
# a green-looking no-op -- the worst outcome for a gate. run-mutations.sh classifies `rc 77`/`^SKIP`
# as SKIPPED, and a SKIPPED verdict is a battery FAIL.
#
# Hermetic: one private `mktemp -d`, nothing resolved from a shared path. The two emptiness
# assertions are the reason -- a leftover file in a shared /tmp would turn into a false green (if it
# looks like the installer's) or a false red (if the harness is blamed for it).
set -eu

SCRIPT=${1:-dist/darling-lol-install.sh}
uid=65431; gid=65431

[ -f "$SCRIPT" ] || { echo "SKIP: $SCRIPT does not exist (pass the installer path as \$1)"; exit 77; }

# A PATH with NO sudo at all: if the installer escalated implicitly it would fail differently, and
# the assertions below would not see our message. This is what makes "never calls sudo" testable
# rather than aspirational.
NOPRIV_PATH=/usr/bin:/bin
for c in setpriv env bash id mktemp ls grep find groupadd; do
  command -v "$c" >/dev/null || { echo "SKIP: $c missing"; exit 77; }
done

grep -q "^pkgtest:" /etc/passwd 2>/dev/null || {
  # the group must exist before `useradd -N -g <gid>`; without it useradd exits non-zero and the
  # harness would silently SKIP (measured in ubuntu:24.04).
  groupadd -g "$gid" pkgtest 2>/dev/null || true
  useradd -M -N -u "$uid" -g "$gid" pkgtest 2>/dev/null \
    || { echo "SKIP: cannot create an unprivileged uid here (need root or a container)"; exit 77; }
}

as_uid() {  # as_uid <homedir> <args...>
  local h=$1; shift
  setpriv --reuid="$uid" --regid="$gid" --clear-groups \
    env -i PATH="$NOPRIV_PATH" HOME="$h" USER=pkgtest LOGNAME=pkgtest TMPDIR="$h/tmp" \
    bash "$SCRIPT" "$@"
}

# A real user OWNS their $HOME; mktemp -d makes it root-owned, which would hide any write the
# installer attempts. chown it so the $HOME-untouched assertion is about the installer, not about
# the directory being unwritable.
HOME_AFTER=$(mktemp -d)
reset_home() { rm -rf "$HOME_AFTER"; mkdir -p "$HOME_AFTER/tmp"; chown -R "$uid:$gid" "$HOME_AFTER"; }
reset_home
fail=0

# ---- the row protocol, and the counters the summary is derived from.
#      n_* count CASES THAT RAN (one increment per loop iteration), never assertions: they are the
#      evidence that a loop body was entered at all.
n_refuse=0; n_hostile=0; n_positive=0
bad() { printf 'FAIL %s: %s\n' "$1" "$2"; fail=1; }

# cfail SUB_ASSERTION -- fold one failed sub-assertion into the CURRENT case's message, so ONE row
# per case is emitted (see the header: the battery pins the row names, not the sub-assertions).
problems=""
cfail() { problems="$problems $1;"; }
flush() { [ -z "$problems" ] || bad "$1" "[$2] $problems"; }  # flush ROW TAG
leftover_in_home() { find "$HOME_AFTER" -mindepth 1 -maxdepth 1 ! -name tmp -print 2>/dev/null; }

# ---- (i) refusal: every --method, WITH and WITHOUT --dry-run, must refuse identically.
#      --dry-run is asserted too: a dry run that hides the root precondition would make this
#      whole gate vacuous (EVIDENCE C25).
for m in auto apt dnf pacman tar; do
  for extra in "" "--dry-run"; do
    reset_home
    set +e
    # shellcheck disable=SC2086  # $extra is a deliberate word list (empty, or --dry-run)
    out=$(as_uid "$HOME_AFTER" --method "$m" $extra 2>&1)
    rc=$?
    set -e
    n_refuse=$((n_refuse + 1))
    tag="--method $m${extra:+ $extra}"
    if [ -n "$extra" ]; then row="noroot-refusal-$m-dryrun"; else row="noroot-refusal-$m"; fi
    problems=""
    [ "$rc" -eq 1 ] || cfail "exit=$rc, expected 1"
    # 🚨 the two message arms below changed shape with the 2026-10-16 ruling (the pointer's target
    #      and the non-support sentence): the old ones named a document the ruling deleted.
    printf '%s' "$out" | grep -q 'PACKAGING\.md' \
      || cfail "message does not point at docs/PACKAGING.md"
    printf '%s' "$out" | grep -q 'Nothing has been downloaded, unpacked or modified' \
      || cfail "message does not state that nothing was touched"
    printf '%s' "$out" | grep -q 'Installing without root is not supported' \
      || cfail "message does not say that installing without root is unsupported"
    # $HOME must be EMPTY apart from the tmp dir we created: no ~/.local/share/darling-lol, no
    # partial ~/.darling, no downloaded asset.
    leftover=$(leftover_in_home)
    [ -z "$leftover" ] \
      || cfail "the installer wrote into \$HOME as a non-root user: $(printf '%s' "$leftover" | tr '\n' ' ')"
    [ -z "$(find "$HOME_AFTER/tmp" -mindepth 1 -print 2>/dev/null)" ] \
      || cfail "the installer wrote into \$TMPDIR before refusing"
    flush "$row" "$tag"
  done
done

# ---- (ii) hostile flags: NO code path may write into $HOME, whatever flag claims to enable it.
#      Found by mutation testing: a *working* $HOME install is invisible to loop (i), because that
#      loop never passes --prefix. The invariant asserted here is the one that actually matters --
#      "the installer never writes into $HOME as a non-root user" -- and it holds whether the flag
#      is unknown, refused, or implemented.
#      🚨 rev 5: this loop ran four cases. The two that passed a rootless flag were deleted with
#      the flag (2026-10-16 ruling, §23), and the mutant they existed to catch (NR2d) with them.
#      🚨 T10b/NIT-3: the exit status is pinned to 1, not "non-zero". Both flags die in require_root
#      (step 2 -- before resolve_prefix and before any --dry-run branch), so 1 is the only correct
#      status, and a mutant that gets out with 127 ("command not found") must be red here too instead
#      of being caught by loop (i) alone. It is still the $HOME invariant that this loop exists for.
hostile_case() {  # hostile_case ROW TAG ARGS...
  local row=$1 tag=$2; shift 2
  reset_home
  set +e
  out=$(as_uid "$HOME_AFTER" "$@" 2>&1)
  rc=$?
  set -e
  n_hostile=$((n_hostile + 1))
  problems=""
  [ "$rc" -eq 1 ] \
    || cfail "exit=$rc, expected 1 (require_root) -- nothing may install into \$HOME as a non-root user"
  leftover=$(leftover_in_home)
  [ -z "$leftover" ] \
    || cfail "wrote into \$HOME as a non-root user: $(printf '%s' "$leftover" | tr '\n' ' ')"
  flush "$row" "$tag"
}
hostile_case noroot-hostile-prefix     "--prefix $HOME_AFTER/x" --prefix "$HOME_AFTER/x"
hostile_case noroot-hostile-prefix-tar "--prefix $HOME_AFTER/x --method tar" --prefix "$HOME_AFTER/x" --method tar

# ---- (iii) positive: documentation and read-only detection stay usable unprivileged. Without
#      this the gate would also pass for a script that simply always exits 1.
for a in --help --detect-only; do
  set +e
  as_uid "$HOME_AFTER" "$a" >/dev/null 2>&1
  rc=$?
  set -e
  n_positive=$((n_positive + 1))
  [ "$rc" -eq 0 ] || bad "noroot-positive-${a#--}" "'$a' must succeed unprivileged (rc=$rc)"
done
# 🚨 rev 5: the "--help must not advertise <the deleted flag>" arm was removed with the flag it
#      guarded. What --help must SAY is asserted by G-INSTALL-2a instead (PLAN §19.1), which is a
#      local gate and not part of this harness.

# ---- the pin: each half's total, as a FLOOR (C3).
#      Three INDEPENDENT statements, not a `&&` chain: when someone empties a loop, ALL the counts
#      that moved must be reported in the same run (a short-circuit would hide the second one).
#      FLOOR, not equality: an ADDED case is not a defect and must not red the gate (the
#      `mx_noroot_add_method` mutant in run-mutations.sh keeps this honest), while a LOST case is
#      exactly the rot this row exists to catch. See the header for what the floor cannot see.
#      ⚠ `-ge`, i.e. "fail when the count is BELOW the pin" -- `-ge PIN || bad` is the floor shape;
#      `-lt PIN || bad` is its negation and reds a pristine gate (measured: it prints all three rows
#      on a 10/2/2 run), which is the very defect this row was written to remove.
[ "$n_refuse"   -ge 10 ] || bad noroot-rows "refusal cases executed = $n_refuse, pinned = at least 10"
[ "$n_hostile"  -ge  2 ] || bad noroot-rows "hostile-flag cases executed = $n_hostile, pinned = at least 2"
[ "$n_positive" -ge  2 ] || bad noroot-rows "positive cases executed = $n_positive, pinned = at least 2"

rm -rf "$HOME_AFTER"
if [ "$fail" = 0 ]; then
  echo "G-INSTALL-7: OK ($n_refuse refusals + $n_hostile hostile flags clean, $n_positive unprivileged positives --help/--detect-only)"
else
  echo "G-INSTALL-7: FAILED"
fi
exit "$fail"
