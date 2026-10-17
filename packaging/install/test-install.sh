#!/usr/bin/env bash
# packaging/install/test-install.sh -- the INSTALL half of G-INSTALL (the positive gate the T10
# review found missing: INFO-1, ruling R6). The refusal half is test-nonroot.sh; this half runs the
# tarball path for real, in a throwaway container, and asserts what the user ends up with.
#
#   docker run --rm -v "$PWD":/repo -w /repo ubuntu:24.04 \
#     bash packaging/install/test-install.sh packaging/install/darling-lol-install.sh
#
# Manifest mode. The real artifact is a ~589 MB x86_64 tree and this gate does NOT need it: it
# builds a tiny fixture archive with the /usr shape assert_install checks. What is therefore NOT
# provable here (it needs the real artifact, on x86_64) is listed at the bottom: the fixture's
# `usr/bin/darling` is a shell stub, so `darling --help` cannot prove the real ELF runs.
#
# 🚨 ARCH. `detect_arch` refuses anything but x86_64, and this box is arm64 with no qemu (a
# `--platform linux/amd64` container dies "exec format error", measured). So the gate puts a
# one-line `uname` shim FIRST on PATH that reports x86_64 -- a gate input, exactly like
# OS_RELEASE_FIXTURE is for the distro half, and NOT a mutation of the shipped script: the
# installer under test is byte-identical. Row `arch-refusal` additionally proves the UNshimmed
# installer still refuses this machine's real arch. On a real x86_64 runner the shim is a no-op and
# `arch-refusal` is skipped (it would be asserting the opposite of the truth).
#
# Every row has a mutant that makes it red: see run-mutations.sh (the grid) and the report.
set -eu

INSTALLER=${1:-dist/darling-lol-install.sh}
DOC=${INSTALL_DOC:-docs/PACKAGING.md}
STATE=/var/lib/darling-lol/tar-installed-files.txt
REALPATH_SAFE=/usr/bin:/bin

[ -f "$INSTALLER" ] || { echo "SKIP: $INSTALLER does not exist (pass the installer path as \$1)"; exit 77; }
[ -f "$DOC" ] || { echo "SKIP: $DOC does not exist (set INSTALL_DOC)"; exit 77; }
[ "$(id -u)" -eq 0 ] || { echo "SKIP: install and removal need root (run in ubuntu:24.04 via docker)"; exit 77; }
for c in tar sh sed awk grep stat find rm rmdir diff; do
  command -v "$c" >/dev/null || { echo "SKIP: $c missing"; exit 77; }
done

# A container is the only place this gate may run: it writes /usr/bin/darling. Refuse to run on a
# host that already carries a darling install (the assertion "no unrelated path removed" would be
# meaningless, and the removal block would delete someone's runtime).
if [ -e /usr/bin/darling ] || [ -e /usr/libexec/darling ]; then
  echo "SKIP: /usr already carries a darling install; run this in a throwaway container"; exit 77
fi

W=$(mktemp -d "${TMPDIR:-/tmp}/dlol-install-gate.XXXXXX")
trap 'rm -rf "$W"' EXIT INT TERM

fail=0
ok()  { printf 'OK   %s\n' "$1"; }
bad() { printf 'FAIL %s: %s\n' "$1" "$2"; fail=1; }

# ---------------------------------------------------------------------------------------------
# The fixture: a /usr tree whose shape is exactly what assert_install checks. Every path here is
# asserted by the installer downstream (usr/bin/darling 4755 root:root, the real mldr under
# $PREFIX/libexec/darling/usr/libexec/darling, $PREFIX/libexec/darling/System, the binfmt drop-in
# naming an interpreter that exists, and a `darling` on PATH that answers --help).
mkfixture_tree() { # mkfixture_tree DIR
  _r=$1
  mkdir -p "$_r/usr/bin" "$_r/usr/libexec/darling/usr/libexec/darling" \
           "$_r/usr/libexec/darling/System/Library/CoreServices" \
           "$_r/usr/libexec/darling/private/tmp" \
           "$_r/usr/lib/binfmt.d" "$_r/usr/lib/darling-lol/tools" "$_r/usr/share/doc/darling-lol"
  printf '#!/bin/sh\n[ "${1:-}" = --help ] || exit 0\necho "darling (fixture)"\n' > "$_r/usr/bin/darling"
  chmod 4755 "$_r/usr/bin/darling"
  printf '#!/bin/sh\nexit 0\n' > "$_r/usr/bin/darlingserver"; chmod 0755 "$_r/usr/bin/darlingserver"
  printf '#!/bin/sh\nexit 0\n' > "$_r/usr/bin/darling-lol";  chmod 0755 "$_r/usr/bin/darling-lol"
  printf '#!/bin/sh\nexit 0\n' > "$_r/usr/libexec/darling/usr/libexec/darling/mldr"
  chmod 0755 "$_r/usr/libexec/darling/usr/libexec/darling/mldr"
  printf 'guest\n' > "$_r/usr/libexec/darling/System/Library/CoreServices/SystemVersion.plist"
  printf '# fixture launcher template\n@GUEST_HOME@\n' > "$_r/usr/lib/darling-lol/tools/config.in"
  # field 7 is the interpreter the installer asserts is executable
  printf ':darling:M::cffaedfe::/usr/libexec/darling/usr/libexec/darling/mldr:\n' \
    > "$_r/usr/lib/binfmt.d/darling.conf"
  # usr/libexec/darling/private/tmp is left EMPTY on purpose: empty dirs are members too
  # (stage.sh lists them), and the removal has to take them away.
}

# Stage + archive exactly the way packaging/common/build-tar.sh does: the member list is "every
# non-directory plus every EMPTY directory", relative, sorted, --no-recursion, root-owned. That is
# what makes `tar -tf | head -1` a statement about the archive's prefix.
mkfixture_tar() { # mkfixture_tar ROOT OUT
  _r=$1 _out=$2
  ( cd "$_r" && find . \( ! -type d -o -type d -empty \) -printf '%P\n' ) | LC_ALL=C sort > "$W/members"
  tar --no-recursion --owner=0 --group=0 --numeric-owner -czf "$_out" -C "$_r" -T "$W/members"
}
members_abs() { sed 's|/$||; s|^/*|/|' "$1" | LC_ALL=C sort; }

# The legacy decoy: a /usr/local tree under the v0.1.0-era name. The installer must NEVER select
# it (R1), and the fixture makes that assertable by execution: extracting it would land
# /usr/local/bin/darling, which the /usr prefix check refuses.
mkdecoy_tar() { # mkdecoy_tar OUT
  _d=$W/decoy; rm -rf "$_d"; mkdir -p "$_d/usr/local/bin"
  printf '#!/bin/sh\nexit 0\n' > "$_d/usr/local/bin/darling"; chmod 4755 "$_d/usr/local/bin/darling"
  tar --no-recursion --owner=0 --group=0 --numeric-owner -czf "$1" -C "$_d" usr/local/bin/darling
}

# The uname shim (see the header). One file, x86_64 for -m, the real uname for anything else.
mkdir -p "$W/shim"
printf '#!/bin/sh\n[ "${1:-}" = -m ] && { echo x86_64; exit 0; }\nexec %s "$@"\n' \
  "$(command -v uname)" > "$W/shim/uname"
chmod 0755 "$W/shim/uname"
run_installer() { # run_installer ARGS... -- the shipped installer, x86_64 seam, ubuntu fixture
  PATH="$W/shim:$PATH" OS_RELEASE_FIXTURE=packaging/install/testdata/os-release/ubuntu \
    bash "$INSTALLER" "$@"
}

# ---------------------------------------------------------------------------------------------
# Build the fixture assets.
assets=$W/assets; root=$W/root; mkdir -p "$assets"
mkfixture_tree "$root"
asset=$assets/darling-lol-v0.1.2-linux-x86_64.tar.gz
mkfixture_tar "$root" "$asset"
mkdecoy_tar "$assets/darling-lol-linux-x86_64-v0.1.2-base-runtime.tar.gz"
( cd "$assets" && sha256sum darling-lol-v0.1.2-linux-x86_64.tar.gz > SHA256SUMS )
members_first_abs=$(cd "$assets" && tar -tf darling-lol-v0.1.2-linux-x86_64.tar.gz | head -1)

# baseline witnesses (the sentinels are created FIRST, so the snapshot includes them: the /usr
# comparison then asserts both "the tree is gone" and "the unrelated paths survived")
mkdir -p /usr/share/lol-gate-sentinel-dir; : > /usr/share/lol-gate-sentinel-dir/keep
: > /var/lib/lol-gate-sentinel
snap_usr=$W/usr.before;       snap_varlib=$W/varlib.before
find /usr -printf '%p %m %u:%g\n' | LC_ALL=C sort > "$snap_usr"
find /var/lib -printf '%p %m %u:%g\n' | LC_ALL=C sort > "$snap_varlib"

# ---- row arch-refusal: with NO shim, this machine's real arch must be refused ------------------
# On x86_64 the refusal is not the truth, so the row is skipped there.
case "$(uname -m)" in
  x86_64|amd64) printf 'SKIP arch-refusal: this runner is x86_64 (the seam is a no-op here)\n' ;;
  *)
    set +e
    out=$(PATH="$REALPATH_SAFE" OS_RELEASE_FIXTURE=packaging/install/testdata/os-release/ubuntu \
          bash "$INSTALLER" --method tar --version v0.1.2 --asset-dir "$assets" 2>&1)
    rc=$?
    set -e
    if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'x86_64 assets only'; then
      ok arch-refusal
    else
      bad arch-refusal "rc=$rc; expected a refusal naming the x86_64 assets"
    fi ;;
esac

# ---- row prefix-refusal: --prefix with --method tar is refused, in the dry run too ---------------
# LIBEXEC_PATH is compiled in, so the tar path cannot be relocated: the refusal has to come BEFORE
# anything is announced, or "installed" turns into a broken runtime at mount("overlay").
set +e
out=$(run_installer --method tar --version v0.1.2 --asset-dir "$assets" --prefix /usr/local --dry-run 2>&1)
rc=$?
set -e
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'must be /usr' \
   && ! printf '%s' "$out" | grep -q 'prefix=/usr/local'; then
  ok prefix-refusal
else
  bad prefix-refusal "rc=$rc; --prefix with --method tar must be refused, and nothing may be announced: $(printf '%s' "$out" | tail -2 | tr '\n' ' ')"
fi

# ---- row url-version: the release URL names the CLI --version, not os-release's VERSION ----------
# 🚨 the review's E12/E13, measured in T10: sourcing /etc/os-release defines VERSION ("24.04.5 LTS
# (Noble Numbat)"), so before the fix the download URL was built from the DISTRIBUTION's VERSION and
# the "required on the stable channel" guard could never fire (a clobbered value is non-empty).
# --detect-only exits before the URL is built, so 2b structurally cannot see this (INFO-1): the row
# below is the only in-tree place the clobber can turn red.
set +e
out=$(run_installer --method tar --version v0.1.2 --asset-dir "$assets" --dry-run 2>&1)
rc=$?
set -e
url_problems=""
[ "$rc" -eq 0 ] || url_problems="$url_problems rc=$rc"
printf '%s' "$out" | grep -qE '/download/v0\.1\.2$' \
  || url_problems="$url_problems the-URL-does-not-end-in-/download/v0.1.2"
printf '%s' "$out" | grep -qE 'Numbat|24\.04\.5' \
  && url_problems="$url_problems os-release-VERSION-clobbered-the-CLI-tag"
if [ -z "$url_problems" ]; then
  ok url-version
else
  bad url-version "$url_problems: $(printf '%s' "$out" | grep 'assets would come from' | tr '\n' ' ')"
fi

# ---- row dry-run: --dry-run prints prefix=/usr and writes NOTHING -------------------------------
set +e
out=$(run_installer --method tar --version v0.1.2 --asset-dir "$assets" --dry-run 2>&1)
rc=$?
set -e
declared_prefix=$(printf '%s' "$out" | sed -n 's/.*method=tar prefix=\([^ ]*\).*/\1/p' | head -1)
usr_after_dry=$(find /usr -printf '%p %m %u:%g\n' | LC_ALL=C sort)
dry_problems=""
[ "$rc" -eq 0 ] || dry_problems="$dry_problems rc=$rc"
[ "$declared_prefix" = /usr ] || dry_problems="$dry_problems prefix='$declared_prefix' (want /usr)"
[ -e "$STATE" ] && dry_problems="$dry_problems state-file-written"
[ -e /usr/bin/darling ] && dry_problems="$dry_problems /usr/bin/darling-installed"
[ "$usr_after_dry" = "$(cat "$snap_usr")" ] || dry_problems="$dry_problems /usr-changed"
if [ -z "$dry_problems" ]; then
  ok dry-run
else
  bad dry-run "$dry_problems"
fi

# ---- row prefix-cross-check: the prefix the installer demands == the asset's own prefix (R6) ---
# The installer's prefix is read from its OWN dry-run output; the archive's prefix from the first
# member of the asset its resolver picks. This is the row that turns a future prefix/name
# divergence red before 589 MB are extracted. It compares the TAR PATH's prefix: --dry-run for
# --method tar goes through set_tar_prefix(), the same function install_tar() uses (the mutation
# battery's mx_prefix_usrlocal is what forced that single source -- before it, the row read the
# global default and stayed green while install_tar drifted).
case "$members_first_abs" in
  usr/local/*) archive_prefix=/usr/local ;;
  usr/*)       archive_prefix=/usr ;;
  *)           archive_prefix="/${members_first_abs%%/*}" ;;
esac
if [ "$declared_prefix" = "$archive_prefix" ]; then
  ok prefix-cross-check
else
  bad prefix-cross-check "installer demands '$declared_prefix', the asset's first member '$members_first_abs' is a '$archive_prefix' tree"
fi

# ---- the install (with the decoy present, so the resolver has a wrong-but-plausible choice) -----
set +e
out=$(run_installer --method tar --version v0.1.2 --asset-dir "$assets" 2>&1)
rc=$?
set -e
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -qF 'post-install verification OK (setuid 4755, mldr, guest tree, binfmt, darling --help)'; then
  ok install
else
  bad install "rc=$rc; expected 0 and the post-install OK literal. Output: $(printf '%s' "$out" | tail -4 | tr '\n' ' ')"
fi
if printf '%s' "$out" | grep -qF 'checksums OK'; then :; else
  bad install "SHA256SUMS was not verified"
fi

# ---- row setuid: the mode survives the extract (T8/C3) ------------------------------------------
mode=$(stat -c '%a' /usr/bin/darling 2>/dev/null || echo missing)
own=$(stat -c '%U:%G' /usr/bin/darling 2>/dev/null || echo missing)
if [ "$mode" = 4755 ] && [ "$own" = root:root ]; then
  ok setuid
else
  bad setuid "/usr/bin/darling is mode=$mode owner=$own, expected 4755 root:root"
fi

# ---- row state-file: it matches the members exactly, and cannot collide with the tree -----------
members_abs "$W/members" > "$W/members.want"
if [ -r "$STATE" ]; then
  members_abs "$STATE" > "$W/state.got"
  if diff -q "$W/members.want" "$W/state.got" >/dev/null; then
    ok state-file
  else
    bad state-file "the state file does not match the archive members: $(diff "$W/members.want" "$W/state.got" | head -3 | tr '\n' ' ')"
  fi
  if grep -qxF "$STATE" "$W/state.got"; then
    bad state-file "the state file path is itself an archive member"
  fi
else
  bad state-file "$STATE was not written"
fi
# the tree really landed (not just the state file)
if [ -e /usr/bin/darling-lol ] && [ -d /usr/libexec/darling/System ]; then :; else
  bad install "the tree is not on disk after the install"
fi

# ---- row remove-state: the DOCUMENTED recipe empties the tree, verbatim -------------------------
run_doc_removal() { # run_doc_removal CWD -- the block between the two markers in $DOC, as root
  sed -n '/^# G-TAR-UNINSTALL-BEGIN$/,/^# G-TAR-UNINSTALL-END$/p' "$DOC" > "$W/remove.sh"
  [ -s "$W/remove.sh" ] || { echo "FAIL remove-recipe: no marked block in $DOC"; fail=1; return 0; }
  ( cd "$1" && sh "$W/remove.sh" )
}
leftovers() { # leftovers -- member paths that still exist
  while IFS= read -r p; do
    if [ -e "$p" ] || [ -L "$p" ]; then printf '%s\n' "$p"; fi
  done < "$W/members.want"
  return 0
}
if run_doc_removal "$W" 2>"$W/rm.err"; then
  l=$(leftovers)
  if [ -n "$l" ]; then
    bad remove-state "leftovers after the documented removal: $(printf '%s' "$l" | head -3 | tr '\n' ' ')"
  elif ! diff -q "$snap_usr" <(find /usr -printf '%p %m %u:%g\n' | LC_ALL=C sort) >/dev/null; then
    bad remove-state "/usr is not back to its pre-install state: $(diff "$snap_usr" <(find /usr -printf '%p %m %u:%g\n' | LC_ALL=C sort) | head -4 | tr '\n' ' ')"
  elif ! diff -q "$snap_varlib" <(find /var/lib -printf '%p %m %u:%g\n' | LC_ALL=C sort) >/dev/null; then
    bad remove-state "/var/lib changed: $(diff "$snap_varlib" <(find /var/lib -printf '%p %m %u:%g\n' | LC_ALL=C sort) | head -4 | tr '\n' ' ')"
  elif [ ! -e /usr/share/lol-gate-sentinel-dir/keep ] || [ ! -e /var/lib/lol-gate-sentinel ]; then
    bad remove-state "the removal took an unrelated path (a sentinel is gone)"
  else
    ok remove-state
  fi
else
  bad remove-state "the documented removal exited non-zero: $(head -2 "$W/rm.err" | tr '\n' ' ')"
fi

# ---- row remove-fallback: no state file -> the tarball's own member list ------------------------
# Re-install, delete the installer's record, and run the same block from a directory holding only
# the tarball: it must build the list with `tar -tzf` and remove the tree all the same.
only=$W/only; mkdir -p "$only"; cp "$asset" "$only/"
set +e
run_installer --method tar --version v0.1.2 --asset-dir "$assets" >/dev/null 2>&1
set -e
rm -f "$STATE"
if run_doc_removal "$only" 2>"$W/rm2.err"; then
  l=$(leftovers)
  if [ -n "$l" ]; then
    bad remove-fallback "leftovers after the fallback removal: $(printf '%s' "$l" | head -3 | tr '\n' ' ')"
  elif ! diff -q "$snap_usr" <(find /usr -printf '%p %m %u:%g\n' | LC_ALL=C sort) >/dev/null; then
    bad remove-fallback "/usr is not back to its pre-install state"
  else
    ok remove-fallback
  fi
else
  bad remove-fallback "the fallback removal exited non-zero: $(head -2 "$W/rm2.err" | tr '\n' ' ')"
fi

# ---- row no-decoy: a directory holding ONLY the legacy pair must be refused ---------------------
onlydecoy=$W/onlydecoy; mkdir -p "$onlydecoy"
cp "$assets/darling-lol-linux-x86_64-v0.1.2-base-runtime.tar.gz" "$onlydecoy/"
cp "$assets/SHA256SUMS" "$onlydecoy/"   # sums the version-named asset, which is not here
set +e
out=$(run_installer --method tar --version v0.1.2 --asset-dir "$onlydecoy" 2>&1)
rc=$?
set -e
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'legacy /usr/local pair'; then
  ok no-decoy
else
  bad no-decoy "rc=$rc; a -base-runtime-only directory must be refused as the legacy /usr/local pair (the resolver may not select it): $(printf '%s' "$out" | tail -2 | tr '\n' ' ')"
fi

rm -rf /usr/share/lol-gate-sentinel-dir /var/lib/lol-gate-sentinel

if [ "$fail" = 0 ]; then
  echo "G-INSTALL-3/4: OK (install + state file + documented removal + setuid 4755 + prefix cross-check + legacy decoy refused)"
else
  echo "G-INSTALL-3/4: FAILED"
fi
exit "$fail"
