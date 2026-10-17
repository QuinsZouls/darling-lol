#!/bin/sh
# packaging/common/build-tar.sh -- the release tarballs and SHA256SUMS (PLAN 12, TASKS.md T6).
#
# Three artifacts, all from the T1 staging tree, all with the one convention this task exists to
# keep (TASKS.md T6's gate block):
#
#   darling-lol-<ver>-linux-x86_64.tar.zst   PLAN 12.1: de-absolutise the list (C43-a), then
#                                            `tar --no-recursion --owner=0 --group=0
#                                            --numeric-owner -I 'zstd -19 -T0'`
#   darling-lol-<ver>-linux-x86_64.tar.gz    the pre-existing asset, still produced from the same
#                                            tree with the same --no-recursion fix (continuity, and
#                                            install.sh's fallback for hosts without zstd)
#   SHA256SUMS                               PLAN 12.2: every asset, relative paths, so
#                                            `sha256sum -c SHA256SUMS` works in a download dir
#
# The two flags that carry the whole risk:
#   --no-recursion   C2. files.all already lists every directory explicitly (3555 of them in the
#                    v0.1.0 manifest), so recursing duplicates members and creates the 146663
#                    self-referential hard links EVIDENCE measured. The `uniq -d` gate is what
#                    holds this: without the flag the duplicate count stops being 0.
#   sed 's|^/||'     C43-a. files.all holds ABSOLUTE paths and `-C` does NOT apply to absolute -T
#                    entries: tar stats them from /. Measured on the plan's own recipe: rc=2,
#                    9 x "Cannot stat", and an archive holding the BUILD HOST's /usr, /usr/bin,
#                    /usr/libexec, /usr/share, /usr/share/doc -- with the host's mtimes and zero
#                    payload members. On a runner that has a previous install, the published
#                    .tar.zst ships the host's file instead of the staged one, and `set -eu` alone
#                    does not stop it (the count arm and the name arm both do).
#
# The reply to "is it really zstd?" is the same one build-rpm.sh (C50/R1) and this builder give for
# their own artifacts: the builder reads back its own magic bytes and refuses to publish a name the
# bytes do not support. There is no xz fallback -- a .tar.zst holding xz is invisible to every
# reader that trusts the name.
#
# usage: build-tar.sh {fixture|TAG}
#   fixture     build from packaging/testdata/mkfixture.sh's tree (TASKS.md T6's gate block names
#               $DIST/fix.tar.zst and $DIST/fix.tar.gz), through the SAME code path.
#   TAG         package $DIST/pkg/root, which scripts/build-packaging.sh + stage.sh produced.
#
# Environment:
#   DARLING_PKG_DIST   absolute dist/ directory (default: <repo>/dist).
#   TAR_FIXTURE_TAG    the tag fixture mode versions itself with; default: the exported TAG,
#                      else the checkout's own version (pkg-version.sh -> git describe).
#   TAG                version tag (production mode), passed explicitly to nothing that could
#                      inherit it from the checkout.
set -eu

dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo=$(CDPATH='' cd -- "$dir/../.." && pwd)
prog=build-tar

fatal() { echo "$prog: FATAL $*" >&2; exit 1; }
note() { echo "$prog: $*"; }

[ "$#" -eq 1 ] || fatal "usage: sh packaging/common/build-tar.sh {fixture|TAG}"
case $1 in
  -h | --help)
    sed -n '2,33p' "$0"
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

command -v tar >/dev/null 2>&1 || fatal "tar not found on PATH"
# The name is a promise about the bytes (C50/R1, PLAN 12.1). No fallback compressor: an xz payload
# under a .zst name is invisible to every reader that trusts the name.
command -v zstd >/dev/null 2>&1 || fatal "zstd not found on PATH.
  The release tarball is '.tar.zst' and PLAN 12.1 pins 'zstd -19 -T0' (EVIDENCE 7.3: 92 572 857 B
  vs 145 062 479 B for the published .tar.gz). Refusing rather than falling back to xz.
  Install zstd and re-run."

if [ "$arg" = fixture ]; then
  # The fixture tag is what the run was given (TAR_FIXTURE_TAG, else the exported TAG that
  # build-all.sh sets) and otherwise the checkout's own version -- the same single derivation the
  # production path uses (pkg-version.sh -> git describe). packaging/common/ never carries a
  # literal version (G-STATIC); a git-less copy still renders the 0.0.0 dev form.
  tag=${TAR_FIXTURE_TAG:-${TAG:-$(sh "$dir/pkg-version.sh")}}
  mode=fixture
  zst_out=$dist/fix.tar.zst
  gz_out=$dist/fix.tar.gz
else
  tag=$arg
  mode=production
  zst_out=
  gz_out=
fi

if [ "$mode" = fixture ]; then
  note "fixture mode: staging the hostile-shape tree with packaging/testdata/mkfixture.sh"
  sh "$repo/packaging/testdata/mkfixture.sh" "$pkg"
  sh "$dir/stage.sh" "$pkg/root" "$pkg"
else
  [ -d "$pkg/root" ] || fatal "$pkg/root is missing.
  Run scripts/build-packaging.sh (it needs x86-64) and then packaging/common/stage.sh, or use
  the 'fixture' mode."
fi
[ -s "$pkg/files.all" ] || fatal "$pkg/files.all is missing or empty: stage.sh did not produce it"

ver=$(sh "$dir/pkg-version.sh" "$tag") || fatal "'$tag' is not a version tag and not a commit hash"
if [ -z "$zst_out" ]; then
  zst_out=$dist/darling-lol-${ver}-linux-x86_64.tar.zst
  gz_out=$dist/darling-lol-${ver}-linux-x86_64.tar.gz
fi

tmp=$pkg/tar-tmp
rm -rf "$tmp"
mkdir -p "$tmp"

# --- 1. the asset set ---------------------------------------------------------------------------
# One list, in §12.2's order. A RELEASE run requires every family it does NOT own: §12.2 warns that
# one absent glob makes the step fail, and a release that quietly ships three of four formats is the
# exact failure this task exists to prevent.
#
# The two tarballs are NOT in the required list, in either mode: they are this script's own output,
# so requiring them before they exist is a circular check (measured: `build-tar.sh fixture` after a
# full build-all died with "no asset in ... matches 'fix.tar.zst'"). They are appended to the list
# AFTER check_archive has proven them, and the complete release shape -- tarballs included -- is
# asserted by build-all.sh's verification step, which runs once everything exists.
#
# Fixture mode requires nothing: it is the per-builder run (T6's gate block also calls
# `build-arch.sh fixture` on its own), so its siblings may legitimately be absent. Its patterns are
# still collected, so `build-all.sh fixture` sums the whole hostile-shape set.
#
# `darling-lol-install.sh` is required in RELEASE mode: it is the asset install.sh is fetched as,
# and it refuses to install without SHA256SUMS (§16.4). It is produced by T10's render, i.e. by a
# step that runs before packaging, so its absence here is a broken pipeline and not an empty dir.
case "$mode" in
  production)
    required_patterns='darling-lol_*.deb darling-lol-launcher_*.deb darling-lol-*.rpm
      darling-lol-launcher-*.rpm *.pkg.tar.zst darling-lol-install.sh BUILD-INFO-packages.txt'
    optional_patterns=''
    ;;
  fixture)
    required_patterns=''
    optional_patterns='fix.deb fix-launcher.deb darling-lol-*.rpm darling-lol-launcher-*.rpm
      fix.pkg.tar.zst fix-launcher.pkg.tar.zst fix.tar.zst fix.tar.gz darling-lol-install.sh
      BUILD-INFO-packages.txt'
    ;;
esac

assets=
add_assets() { # add_assets REQUIRED(0|1) PATTERNS...
  _req=$1
  shift
  for _pat in "$@"; do
    _matched=0
    for _f in "$dist"/$_pat; do
      [ -f "$_f" ] || continue
      _matched=1
      case " $assets " in
        *" ${_f##*/} "*) : ;;
        *) assets="$assets ${_f##*/}" ;;
      esac
    done
    if [ "$_matched" = 0 ] && [ "$_req" = 1 ]; then
      fatal "no asset in $dist matches '$_pat': the release is incomplete (PLAN 12.2).
  A missing family is a broken release, not an empty directory."
    fi
  done
}

# shellcheck disable=SC2086  # the pattern lists are unquoted on purpose: they ARE word lists.
add_assets 0 $optional_patterns
# shellcheck disable=SC2086
add_assets 1 $required_patterns

# --- 2. the member list, de-absolutised (C43-a) -------------------------------------------------
sed 's|^/||' "$pkg/files.all" > "$tmp/files.all.rel"
grep -q '^/' "$tmp/files.all.rel" && fatal "the de-absolutised list still holds an absolute path"
[ -s "$tmp/files.all.rel" ] || fatal "$pkg/files.all is empty"
expected_members=$(wc -l < "$tmp/files.all.rel" | tr -d ' ')

check_archive() { # check_archive FILE MAGIC READER FORMAT
  _a=$1
  _magic=$2
  _reader=$3
  _fmt=$4
  [ -s "$_a" ] || fatal "$_a is empty"
  # The MAGIC, not the suffix: the name is a promise about the BYTES (C50/R1), and an archive whose
  # bytes are another compressor is invisible to every reader that trusts the suffix. The first two
  # bytes are enough for both (zstd 28b5, gzip 1f8b) -- gzip's third/fourth bytes vary with the
  # mtime/flags it chose, and unpacking a whole header to prove the format is not this task.
  _m=$(od -An -tx1 -N2 "$_a" | tr -d ' \n')
  [ "$_m" = "$_magic" ] || fatal "$_a is NOT $_fmt: magic '$_m', want '$_magic'.
  PLAN 12.1 pins the compressor per format and this builder has no fallback."
  # Read back through the compressor explicitly (the plan's own spell: `zstdcat ... | tar -tvf -`),
  # never by suffix sniffing, so a reader that cannot decompress fails here instead of printing an
  # empty member list that the count arm would then blame on the wrong thing.
  $_reader "$_a" | tar -tf - > "$tmp/members"
  _n=$(wc -l < "$tmp/members" | tr -d ' ')
  [ "$_n" = "$expected_members" ] || fatal "$_a has $_n members, files.all lists $expected_members.
  The count arm is what catches an archive built from the HOST's /usr instead of the payload: an
  absolute -T entry is stat'ed from / (C43-a, measured rc=2 and 5 host directories)."
  # C2: a recursed directory shows up as a duplicate member (and as a self-referential hard link).
  _dup=$(sed 's|/$||' "$tmp/members" | LC_ALL=C sort | uniq -d | wc -l | tr -d ' ')
  [ "$_dup" = 0 ] || fatal "$_a has $_dup duplicate member(s) (C2: --no-recursion is what keeps
  files.all's directory entries from being recursed into):
$(sed 's|/$||' "$tmp/members" | LC_ALL=C sort | uniq -d | head -5)"
  # The name arm: a count alone passes on the host's five directories.
  sed 's|/$||' "$tmp/members" | LC_ALL=C sort -u > "$tmp/members.norm"
  LC_ALL=C sort "$tmp/files.all.rel" > "$tmp/expected.norm"
  if ! cmp -s "$tmp/expected.norm" "$tmp/members.norm"; then
    fatal "$_a does not hold the staged tree: $(diff -u "$tmp/expected.norm" "$tmp/members.norm" | head -10)"
  fi
  grep -q '^/' "$tmp/members" && fatal "$_a holds absolute member name(s)"
  note "wrote $_a ($(wc -c < "$_a") bytes, $_n members, 0 duplicates)"
}

# --- 3. the tarballs ---------------------------------------------------------------------------
# `-C` + a RELATIVE -T list, --no-recursion, root-owned numeric entries: PLAN 12.1's corrected
# form, byte for byte.
tar --no-recursion --owner=0 --group=0 --numeric-owner -I 'zstd -19 -T0' \
  -cf "$zst_out" -C "$pkg/root" -T "$tmp/files.all.rel"
check_archive "$zst_out" 28b5 zstdcat zstd
zstd -t -q "$zst_out" || fatal "$zst_out fails its own integrity check"

# The .tar.gz stays (PLAN 12.1): same tree, same --no-recursion fix, gzip instead of zstd.
# `-z` and not `-I gzip -9n`: this asset replaces the published one and keeps its reader
# (`tar -xzf`) and its compressor, which is the continuity PLAN 12.1 asks for.
tar --no-recursion --owner=0 --group=0 --numeric-owner -z \
  -cf "$gz_out" -C "$pkg/root" -T "$tmp/files.all.rel"
check_archive "$gz_out" 1f8b 'gzip -dc' gzip

# The setuid bit survives the tar member (PLAN 13.1: the Arch and tar mechanisms are the tar mode
# itself; -p is what keeps it on EXTRACT, C3). Assert it on the artifact, not on the tree.
root_mode=$(stat -c '%a' "$pkg/root/usr/bin/darling" 2>/dev/null || echo missing)
[ "$root_mode" = 4755 ] || fatal "$pkg/root/usr/bin/darling is mode $root_mode, expected 4755"
zstdcat "$zst_out" | tar -tvf - | grep -q '^-rwsr-xr-x 0/0 .* usr/bin/darling$' || fatal \
"$zst_out does not carry usr/bin/darling as -rwsr-xr-x root/root (PLAN 13.1)"

# --- 4. SHA256SUMS (PLAN 12.2) ------------------------------------------------------------------
# The two tarballs joined the set here: they did not exist when the other families were collected,
# and check_archive above has now proven them (magic, member count, member names, 0 duplicates).
for _f in "$zst_out" "$gz_out"; do
  case " $assets " in
    *" ${_f##*/} "*) : ;;
    *) assets="$assets ${_f##*/}" ;;
  esac
done
# Relative paths, one file, every asset: `sha256sum -c SHA256SUMS` must work in a download dir.
[ -n "$assets" ] || fatal "no asset to sum"
# shellcheck disable=SC2086  # $assets is a word list of relative names this script built.
( cd "$dist" && rm -f SHA256SUMS && sha256sum $assets > SHA256SUMS )
grep -q '/' "$dist/SHA256SUMS" && fatal "SHA256SUMS holds a path, not a bare asset name: sha256sum -c only
works from the download directory if every name is relative."
( cd "$dist" && sha256sum -c SHA256SUMS > "$tmp/verify.txt" 2>&1 ) || fatal "SHA256SUMS does not verify:
$(cat "$tmp/verify.txt")"
note "wrote $dist/SHA256SUMS ($(wc -l < "$dist/SHA256SUMS" | tr -d ' ') assets, $(grep -c ': OK$' "$tmp/verify.txt") verified)"
note "done: $ver (tag $tag)"
