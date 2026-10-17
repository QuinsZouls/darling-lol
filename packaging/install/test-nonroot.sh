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
# 🚨 A SKIP exits 77, which is NOT a pass: the caller must treat it as a failure (rule 7 in
# TASKS.md). The gate is meaningless without an unprivileged uid, so pretending otherwise would be
# a green-looking no-op -- the worst outcome for a gate.
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
    tag="--method $m${extra:+ $extra}"
    [ "$rc" -eq 1 ] || { echo "G-INSTALL-7[$tag]: exit=$rc, expected 1"; fail=1; }
    # 🚨 the two message arms below changed shape with the 2026-10-16 ruling (the pointer's target
    #      and the non-support sentence): the old ones named a document the ruling deleted.
    printf '%s' "$out" | grep -q 'PACKAGING\.md' \
      || { echo "G-INSTALL-7[$tag]: message does not point at docs/PACKAGING.md"; fail=1; }
    printf '%s' "$out" | grep -q 'Nothing has been downloaded, unpacked or modified' \
      || { echo "G-INSTALL-7[$tag]: message does not state that nothing was touched"; fail=1; }
    printf '%s' "$out" | grep -q 'Installing without root is not supported' \
      || { echo "G-INSTALL-7[$tag]: message does not say that installing without root is unsupported"; fail=1; }
    # $HOME must be EMPTY apart from the tmp dir we created: no ~/.local/share/darling-lol, no
    # partial ~/.darling, no downloaded asset.
    leftover=$(find "$HOME_AFTER" -mindepth 1 -maxdepth 1 ! -name tmp -print 2>/dev/null)
    if [ -n "$leftover" ]; then
      echo "G-INSTALL-7[$tag]: the installer wrote into \$HOME as a non-root user:"
      printf '%s\n' "$leftover" | sed 's/^/    /'; fail=1
    fi
    if [ -n "$(find "$HOME_AFTER/tmp" -mindepth 1 -print 2>/dev/null)" ]; then
      echo "G-INSTALL-7[$tag]: the installer wrote into \$TMPDIR before refusing"; fail=1
    fi
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
for hf in "--prefix $HOME_AFTER/x" "--prefix $HOME_AFTER/x --method tar"; do
  reset_home
  set +e
  # shellcheck disable=SC2086  # $hf is a deliberate word list of flags
  out=$(as_uid "$HOME_AFTER" $hf 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || { echo "G-INSTALL-7[$hf]: exit=$rc, expected 1 (require_root) -- nothing may install into \$HOME as a non-root user"; fail=1; }
  leftover=$(find "$HOME_AFTER" -mindepth 1 -maxdepth 1 ! -name tmp -print 2>/dev/null)
  if [ -n "$leftover" ]; then
    echo "G-INSTALL-7[$hf]: wrote into \$HOME as a non-root user:"
    printf '%s\n' "$leftover" | sed 's/^/    /'; fail=1
  fi
done

# ---- (iii) positive: documentation and read-only detection stay usable unprivileged. Without
#      this the gate would also pass for a script that simply always exits 1.
for a in --help --detect-only; do
  set +e
  as_uid "$HOME_AFTER" "$a" >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || { echo "G-INSTALL-7: '$a' must succeed unprivileged (rc=$rc)"; fail=1; }
done
# 🚨 rev 5: the "--help must not advertise <the deleted flag>" arm was removed with the flag it
#      guarded. What --help must SAY is asserted by G-INSTALL-2a instead (PLAN §19.1), which is a
#      local gate and not part of this harness.

rm -rf "$HOME_AFTER"
if [ "$fail" = 0 ]; then
  echo "G-INSTALL-7: OK (10 refusals + 2 hostile flags clean, --help/--detect-only work unprivileged)"
fi
exit "$fail"
