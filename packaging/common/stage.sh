#!/bin/sh
# Builds dist/pkg/root/ (the DESTDIR staging tree) plus the three derived file lists that the
# deb, rpm and Arch builders all read. Run AFTER scripts/build-packaging.sh + cmake --install.
#
# Everything downstream of this script is metadata: if the staging tree and these lists are
# right, the four formats cannot disagree with each other.
set -eu
root=${1:-dist/pkg/root}
out=${2:-dist/pkg}
mkdir -p "$out"

# 1. Sanity: the prefix must be /usr and nothing may have leaked into /usr/local.
[ -d "$root/usr/libexec/darling" ] || { echo "stage: $root/usr/libexec/darling missing" >&2; exit 1; }
if [ -e "$root/usr/local" ]; then
  echo "stage: FATAL $root/usr/local exists -- the packaging build used the wrong prefix" >&2
  find "$root/usr/local" -maxdepth 3 | head -20 >&2
  exit 1
fi
# 1b. (the CONTENT sweep is step 3b -- it needs files.all, so it cannot run here. See step 3b for
#     why a directory check is not enough: 366 payload files contain the bytes 'usr/local' and 363
#     of them are guest macOS content that must NOT be rewritten. C19/C22, PLAN 4.1.)

# 2. The setuid bit must already be in the staging tree (cmake installed it as root).
# shellcheck disable=SC2043  # single-entry list on purpose: it documents the one setuid host file.
for f in usr/bin/darling; do
  m=$(stat -c '%a' "$root/$f")
  [ "$m" = 4755 ] || { echo "stage: FATAL $f is $m, expected 4755" >&2; exit 1; }
done

# 3. File lists. `find -printf '"/%P"\n'` is upstream's own generator (rpm/darling.spec:273) and
#    is the ONLY form that survives the payload's 53 space-paths and 2189 '%'-paths -- do not add
#    perl escaping on top, double-quoting silently corrupts the list (EVIDENCE 7.2).
( cd "$root" && find . \( ! -type d -o -type d -empty \) -printf '/%P\n' )  | LC_ALL=C sort > "$out/files.all"
( cd "$root" && find . \( ! -type d -o -type d -empty \) -printf '"/%P"\n' ) | LC_ALL=C sort > "$out/files.quoted"
( cd "$root" && find . -type d -empty -printf '/%P\n' )                     | LC_ALL=C sort > "$out/files.emptydirs"

# 3b. G-PREFIX-1: the CONTENT sweep for /usr/local (PLAN 4.1). Driven from files.all, never from a
#     recursive walk: the payload ships usr/libexec/darling/Volumes/DarlingEmulatedDrive -> / and
#     `grep -R` follows it out of the tree and greps the HOST (C19 -- measured 11m28s, 20.8 MB of
#     hits, 682 of 686 reported files outside the staging tree). It asserts three things a
#     directory check cannot: no unexplained host-side text reference, LIBEXEC_PATH=/usr/libexec/
#     darling compiled into all three host ELFs, and the guest-side literals STILL PRESENT (so a
#     well-meaning `sed` over the tree fails the build instead of shipping a broken guest).
sh "$(dirname "$0")/check-prefix.sh" "$root" "$out/files.all"

# 4. The launcher package's own list (it is built from the repo, not from cmake).
#    🚨 usr/lib/darling-lol MUST be here. Omitting it (as an earlier draft of this plan did, C18)
#    puts the 190 templates in files.runtime instead, so BOTH packages claim the same paths and
#    dpkg/rpm/pacman refuse to install the pair.
#    🚨 FIX (T1): `-printf '/%P\n'` removes the *starting point* (the launcher prefix itself), so
#    it emitted `/`, `/tools/config.in`, `/README.md` -- paths that own nothing. `%p` is the path
#    as given to find, which is exactly the package-relative path once `cd "$root"`. Verified
#    against `find .` in the same tree (see packaging/testdata/mkfixture.sh).
: > "$out/files.launcher"
for p in usr/bin/darling-lol usr/lib/darling-lol usr/share/doc/darling-lol; do
  [ -e "$root/$p" ] && { ( cd "$root" && find "$p" \( ! -type d -o -type d -empty \) -printf '/%p\n' ) >> "$out/files.launcher"; }
done
LC_ALL=C sort -o "$out/files.launcher" "$out/files.launcher"

# 5. Runtime package list = everything minus the launcher's.
LC_ALL=C comm -23 "$out/files.all" "$out/files.launcher" > "$out/files.runtime"

# 6. Counts + installed size, for control/PKGINFO and for the drift gate G-PKG-1.
wc -l < "$out/files.runtime"  > "$out/count.runtime"
wc -l < "$out/files.launcher" > "$out/count.launcher"
du -sk "$root"                | awk '{print $1}' > "$out/installed-size-kib"

# 7. Drift detector against the published /usr/local manifest (EVIDENCE C1/G-PKG-1).
if [ -f "$out/reference-installed-files.txt" ]; then
  sed 's|^/usr/local/|/usr/|' "$out/reference-installed-files.txt" | LC_ALL=C sort > "$out/ref.norm"
  LC_ALL=C diff -u "$out/ref.norm" "$out/files.all" > "$out/prefix-diff.txt" || true
  echo "stage: $(wc -l < "$out/prefix-diff.txt") diff lines vs the /usr/local reference"
fi
echo "stage: $(wc -l < "$out/files.runtime") runtime paths, $(cat "$out/installed-size-kib") KiB installed"
