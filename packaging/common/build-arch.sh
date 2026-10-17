#!/bin/sh
# packaging/common/build-arch.sh -- the Arch Linux half of the distro-packaging build
# (PLAN 11 / 11.1-11.4, TASKS.md T6). Two packages, one staging tree (PLAN 5/D3):
#
#   darling-lol           the runtime (x86_64)          -> <ver>-x86_64.pkg.tar.zst
#   darling-lol-launcher  the wrapper + templates (any) -> <ver>-any.pkg.tar.zst
#
# makepkg is an Arch-only program and is absent on every other host (FACTS:150-152), so this
# script reproduces what makepkg does, with the two tools the plan names (PLAN 11: bsdtar + zstd):
#
#   .PKGINFO  rendered by packaging/common/render.sh from packaging/arch/PKGINFO.in; pkgver MUST
#             contain "-" or libalpm rejects the package (FACTS:145-149), so the guard below is a
#             build error, not a hope.
#   .MTREE    bsdtar's mtree writer with makepkg's EXACT option list (PLAN 11.2), `use-set`
#             included -- that is what records mode=4755 for /usr/bin/darling independently of the
#             tar member (G-ARCH-2). Generated, never skipped (PLAN 11.2 gives the two reasons).
#   .INSTALL  packaging/arch/INSTALL, the runtime's pacman hooks (PLAN 11.3). The launcher has
#             none, exactly like the .deb launcher and the noarch .rpm.
#   archive   `bsdtar -cf -` then `zstd -19 -T0`, with the member list fed through
#             `bsdtar --null -T` -- NEVER through shell word splitting: the payload carries 53
#             space-paths and 2189 %-paths and a word-split loses every one of them (PLAN 11.4
#             trap 2, G-ARCH-3).
#
# What the two packages share: ONE copy of the staged tree. What they do not share: the member
# list (stage.sh's files.runtime / files.launcher, so C18 holds -- no path in both packages), the
# .PKGINFO, the .MTREE (an mtree must describe the package's own file set) and the .INSTALL. The
# metadata files are written into the private copy per package, never into the staging tree.
#
# usage: build-arch.sh {fixture|TAG}
#   fixture      build packaging/testdata/mkfixture.sh's hostile-shape tree through the SAME code
#                path (mkfixture.sh -> stage.sh -> render.sh -> bsdtar/zstd). TASKS.md T6's gate
#                block names the artifacts $DIST/fix.pkg.tar.zst and $DIST/fix-launcher.pkg.tar.zst.
#   TAG          package $DIST/pkg/root, which scripts/build-packaging.sh + stage.sh produced.
#
# Environment:
#   DARLING_PKG_DIST  absolute dist/ directory (default: <repo>/dist) -- the variable
#                     scripts/build-packaging.sh and build-rpm.sh honour, so all share one layout.
#   TAG               version tag. Fixture mode reads ARCH_FIXTURE_TAG first, then TAG, and
#                     otherwise derives it from the checkout (pkg-version.sh -> git describe) --
#                     packaging/common/ carries no literal version. Passed to
#                     render.sh explicitly: a value inherited from the checkout is state this
#                     script does not own (TASKS rule 7/C35).
#   MAINTAINER        the FULL contact recorded as `packager` (default: the same phrase the deb
#                     and rpm builders use).
#
# Requires bsdtar (libarchive-tools) and zstd on PATH. Both are refused loudly, never emulated:
# an Arch package built without them is not an Arch package.
set -eu

dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)   # packaging/common
repo=$(CDPATH='' cd -- "$dir/../.." && pwd)          # repository root
prog=build-arch

fatal() { echo "$prog: FATAL $*" >&2; exit 1; }
note() { echo "$prog: $*"; }

# --- 1. arguments -------------------------------------------------------------------------------
[ "$#" -eq 1 ] || fatal "usage: sh packaging/common/build-arch.sh {fixture|TAG}"
case $1 in
  -h | --help)
    sed -n '2,44p' "$0"
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

# bsdtar is the archiver AND the .MTREE writer (PLAN 11.2/11.4); zstd is the compressor PLAN
# 12.1 pins. Neither has a fallback: GNU tar cannot write an mtree, and a `.pkg.tar.zst` that is
# not zstd is invisible to every reader that trusts the name.
command -v bsdtar >/dev/null 2>&1 || fatal "bsdtar not found on PATH (libarchive-tools).
  The Arch package and its .MTREE are both written by bsdtar (PLAN 11.2/11.4); makepkg is
  Arch-only and is deliberately NOT used. Install libarchive-tools and re-run."
command -v zstd >/dev/null 2>&1 || fatal "zstd not found on PATH.
  A .pkg.tar.zst whose bytes are not zstd is a lie no reader can see (PLAN 12.1), and this script
  has no fallback compressor on purpose. Install zstd and re-run."

# --- 2. the staged tree -------------------------------------------------------------------------
if [ "$arg" = fixture ]; then
  # The fixture tag is what the run was given (ARCH_FIXTURE_TAG, else the exported TAG that
  # build-all.sh sets) and otherwise the checkout's own version -- the same single derivation the
  # production path uses (pkg-version.sh -> git describe). packaging/common/ never carries a
  # literal version (G-STATIC); a git-less copy still renders the 0.0.0 dev form.
  tag=${ARCH_FIXTURE_TAG:-${TAG:-$(sh "$dir/pkg-version.sh")}}
  note "fixture mode: staging the hostile-shape tree with packaging/testdata/mkfixture.sh"
  sh "$repo/packaging/testdata/mkfixture.sh" "$pkg"
  sh "$dir/stage.sh" "$pkg/root" "$pkg"
  runtime_out=$dist/fix.pkg.tar.zst
  launcher_out=$dist/fix-launcher.pkg.tar.zst
else
  tag=$arg
  [ -d "$pkg/root" ] || fatal "$pkg/root is missing.
  Run scripts/build-packaging.sh (it needs x86-64) and then packaging/common/stage.sh, or use
  the 'fixture' mode."
  runtime_out=
  launcher_out=
fi
[ -d "$pkg/root" ] || fatal "$pkg/root is missing"
for f in files.runtime files.launcher; do
  [ -s "$pkg/$f" ] || fatal "$pkg/$f is missing or empty: stage.sh did not produce it"
done

# One derivation (pkg-version.sh), three renderings -- never a literal version here.
plain=$(sh "$dir/pkg-version.sh" "$tag") || fatal "'$tag' is not a version tag and not a commit hash"
archver=$(sh "$dir/pkg-version.sh" --arch "$tag")
case "$archver" in
  *-*) : ;;
  *) fatal "pkg-version.sh --arch rendered '$archver' with no '-'" ;;
esac
rel=${archver#"$plain"-}
[ "$rel" != "$archver" ] || fatal "cannot split the Arch rendering '$archver' into pkgver-$rel"
if [ -z "$runtime_out" ]; then
  runtime_out=$dist/darling-lol-${plain}-${rel}-x86_64.pkg.tar.zst
  launcher_out=$dist/darling-lol-launcher-${plain}-${rel}-any.pkg.tar.zst
fi

maintainer=${MAINTAINER:-darling-lol maintainers <darling-lol@users.noreply.github.com>}

work=$pkg/arch
root=$work/root
tmp=$work/tmp
rm -rf "$work"
mkdir -p "$tmp"
cp -a "$pkg/root/." "$root/"

# --- 3. helpers ---------------------------------------------------------------------------------
# kib_of_list FILE -- the installed size of the paths FILE names, in KiB, the unit stage.sh's
# installed-size-kib uses. Each list is summed on its own instead of sharing one `du -sk` of the
# staging tree: the two packages ship different file sets, and PLAN 11.1's `size =` field is
# per package. NUL-separated because the payload carries space-paths (EVIDENCE 7.2).
kib_of_list() {
  ( cd "$root" && sed 's|^/||' "$pkg/$1" | tr '\n' '\0' \
      | du -sk --files0-from=- -c 2>/dev/null | awk 'END { print $1 }' )
}

# The runtime's dependency lines must be exactly the reviewed list, one `depend =` per entry --
# render.sh owns that rendering (it is the same list the deb and rpm render), and the guard below
# asserts the count, so a template edit cannot silently drop a dependency (G-STATIC-5's arm).
dep_count=$(grep -cvE '^[[:space:]]*(#|$)' "$repo/packaging/common/deps.arch")
conf_count=$(grep -cvE '^[[:space:]]*(#|$)' "$repo/packaging/common/conflicts.txt")

check_pkginfo() { # check_pkginfo FILE NAME
  _f=$1
  _name=$2
  grep -q '^pkgname = ' "$_f" || fatal "$_name's .PKGINFO has no pkgname (libalpm requires one)"
  # PLAN 11.1 / FACTS:145-149: libalpm rejects a pkgver without a '-'. This is the one metadata
  # rule whose violation is an uninstallable package rather than an untidy one.
  grep -q '^pkgver = [^-]*-.*$' "$_f" || fatal "$_name's .PKGINFO pkgver does not contain '-' (libalpm rejects the package): $(sed -n 's/^pkgver = //p' "$_f")"
  grep -q '^arch = ' "$_f" || fatal "$_name's .PKGINFO has no arch"
  if [ "$_name" = darling-lol ]; then
    [ "$(grep -c '^depend = ' "$_f")" = "$dep_count" ] || fatal "$_name's .PKGINFO has $(grep -c '^depend = ' "$_f") depend lines, deps.arch has $dep_count"
    [ "$(grep -c '^conflict = ' "$_f")" = "$conf_count" ] || fatal "$_name's .PKGINFO has $(grep -c '^conflict = ' "$_f") conflict lines, conflicts.txt has $conf_count"
    grep -q '^optdepend = ffmpeg6: ' "$_f" || fatal "$_name's .PKGINFO has no ffmpeg6 optdepend (PLAN 8.2/R4: a hard depend would be satisfied while libavcodec.so.60 is not there)"
    [ "$(grep -c '^depend = ffmpeg6' "$_f")" = 0 ] || fatal "$_name's .PKGINFO hard-depends on ffmpeg6 (R4)"
  fi
}

# make_archive NAME MEMBER_LIST_NUL OUT -- `bsdtar -cf -` over the list, zstd-compressed, then
# verified: the name is a promise about the bytes, so the zstd magic and an integrity check are
# both asserted here rather than trusted -- and so is the ownership (see fakeroot note below).
make_archive() {
  _name=$1
  _list=$2
  _out=$3
  rm -f "$_out"
  # `--uid 0 --gid 0 --uname root --gname root` is makepkg's fakeroot made explicit. makepkg runs
  # its packaging step under fakeroot, so its members are root:root whatever user builds; this
  # builder is a plain user, and without the flags every member would record the BUILDER's uid and
  # `pacman -U` (which applies the member's owner) would install /usr/bin/darling owned by it --
  # setuid root on a binary the builder can rewrite. The guard below fails on any other owner.
  ( cd "$root" && bsdtar --uid 0 --gid 0 --uname root --gname root --null -T "$_list" -cf - ) \
    | zstd -19 -T0 -q -o "$_out"
  _magic=$(od -An -tx1 -N4 "$_out" | tr -d ' \n')
  [ "$_magic" = 28b52ffd ] || fatal "$_out is NOT zstd: magic '$_magic', want 28b52ffd"
  zstd -t -q "$_out" || fatal "$_out fails its own integrity check"
  # The listing columns of a package built here are `perms uid uname gname size …`, because the
  # four flags above are always passed -- so `0/root/root` is the exact owner triple. Dropping
  # `--uid/--gid` shows the builder's identity, and dropping the name flags changes the layout
  # itself; both mutations fail here.
  _owners=$(bsdtar -tvf "$_out" | awk 'NF > 4 { print $2 "/" $3 "/" $4 }' | LC_ALL=C sort -u | tr '\n' ' ')
  [ "$_owners" = "0/root/root " ] || fatal "$_out records owner(s) '$_owners' instead of 0/root/root"
  note "wrote $_out ($(wc -c < "$_out") bytes)"
}

# build_pkg NAME TEMPLATE LIST OUT RUNTIME(0|1) -- one package, end to end, over the shared tree.
# The metadata member order is the part libalpm reads while streaming (PLAN 11.4 trap 1) and it is
# file order, not sort order: .PKGINFO, then .MTREE, then .INSTALL for the runtime.
build_pkg() {
  _name=$1
  _tpl=$2
  _list=$3
  _out=$4
  _runtime=$5
  _kib=$(kib_of_list "$_list")
  [ -n "$_kib" ] || fatal "cannot measure the installed size of $_name ($_list)"

  # render.sh's token table is T1's and frozen, so the launcher's own Depend block is spliced in
  # here, at its marker line, exactly as build-rpm.sh splices @RPM_EMPTYDIRS@. render.sh refuses
  # to emit a leftover @TOKEN@, so a lost splice fails the build instead of shipping a marker.
  _spliced=$tmp/$_name.tpl
  if grep -qx '@ARCH_LAUNCHER_DEPENDS@' "$_tpl"; then
    {
      printf 'depend = %s\n' "darling-lol=$plain-$rel"
      printf 'depend = bash\n'
      printf 'depend = coreutils\n'
      printf 'depend = python\n'
    } > "$tmp/launcher.depends"
    awk -v f="$tmp/launcher.depends" '
      /^@ARCH_LAUNCHER_DEPENDS@$/ { while ((getline l < f) > 0) print l; close(f); next }
      { print }' "$_tpl" > "$_spliced"
    grep -qx '@ARCH_LAUNCHER_DEPENDS@' "$_spliced" && fatal "the launcher splice left its marker behind"
  else
    cp "$_tpl" "$_spliced"
  fi
  sh "$dir/render.sh" --family arch --tag "$tag" --maintainer "$maintainer" \
    --installed-size "$_kib" "$_spliced" > "$root/.PKGINFO"
  check_pkginfo "$root/.PKGINFO" "$_name"

  # The runtime's pacman hooks; the launcher has none (TASKS.md T6 acceptance; same asymmetry as
  # T3's launcher package and T4's noarch spec).
  if [ "$_runtime" = 1 ]; then
    install -m 0644 "$repo/packaging/arch/INSTALL" "$root/.INSTALL"
  else
    rm -f "$root/.INSTALL"
  fi

  # The member list, NUL-separated, metadata first. `sed 's|^/||'` first: stage.sh emits absolute
  # paths and bsdtar resolves -T entries from the cwd -- an absolute entry would be read from /,
  # i.e. the HOST's tree (PLAN 12.1's C43-a, the same idiom §11.4 already had).
  : > "$tmp/$_name.nul"
  printf '.PKGINFO\0' >> "$tmp/$_name.nul"
  printf '.MTREE\0' >> "$tmp/$_name.nul"
  [ "$_runtime" = 1 ] && printf '.INSTALL\0' >> "$tmp/$_name.nul"
  sed 's|^/||' "$pkg/$_list" | tr '\n' '\0' >> "$tmp/$_name.nul"

  # .MTREE (PLAN 11.2) with makepkg's exact option list. The INPUT is the package's own file set
  # rather than `find .`: this root is shared with the other package (C18 says the two may not
  # claim the same path), so an mtree over the whole root would describe files this package does
  # not own. `use-set` is what records mode=4755 (G-ARCH-2). The pipe form (`--files-from -`, not
  # bash's `< <(...)`) is C43-e: this file is `#!/bin/sh`, and the fenced recipe's process
  # substitution is a bashism (`sh -n` => rc=2, "redirection unexpected").
  #
  # `.MTREE` is removed from the input list because it is the file being written (makepkg's recipe
  # excludes it for the same reason) -- and because the list is the guard: with a silently-ignored
  # unknown member, a payload path missing from the staging root would vanish from `.MTREE` without
  # a word. Now bsdtar's rc is checked, so that cannot pass unnoticed.
  #
  # NOT piped through `gzip -c -f -n`, unlike §11.2's fence: (a) libalpm opens `.MTREE` with
  # `archive_read_support_filter_all()` + `..._format_all()`, so the compressed and the plain form
  # are read identically, and plain mtree is bsdtar's native output; (b) T6's own gate reads the
  # member as text (`bsdtar -xOf dist/fix.pkg.tar.zst .MTREE | grep ./usr/bin/darling`) -- measured
  # against the gz form that grep matches nothing, because the bytes are deflate, not mtree.
  #
  # `--uid 0 --gid 0 --uname root --gname root`: the records must agree with the members of the
  # archive (same fakeroot reason as make_archive), and it is what lets `use-set` merge them -- with
  # the builder's own uid the entry carries an explicit `uid=1000 gid=1000` instead.
  tr '\0' '\n' < "$tmp/$_name.nul" | grep -v '^\.MTREE$' | tr '\n' '\0' > "$tmp/$_name.mtree.nul"
  if ! bsdtar -cnf "$tmp/$_name.mtree.raw" --format=mtree \
      --options='!all,use-set,type,uid,gid,mode,time,size,sha256,link' \
      --uid 0 --gid 0 --uname root --gname root \
      --null --files-from - -C "$root" < "$tmp/$_name.mtree.nul"; then
    fatal "$_name: .MTREE generation failed -- is a path of the file list missing from the staging root?"
  fi
  mv "$tmp/$_name.mtree.raw" "$root/.MTREE"

  make_archive "$_name" "$tmp/$_name.nul" "$_out"

  # Read the archive back: the member ORDER is metadata libalpm streams before the payload, and
  # the member SET must be exactly the list (a missing path is a missing file; a path this package
  # does not own is C18's double ownership). `-tf` output is compared with the metadata names
  # stripped, so an archiver that decided to add parents is caught here rather than in pacman.
  bsdtar -tf "$_out" > "$tmp/$_name.members"
  sed -n '1,3p' "$tmp/$_name.members" > "$tmp/$_name.first3"
  # bsdtar prints a directory member with a trailing slash; the member list has none. Normalise
  # before comparing (the two sets must otherwise match byte for byte).
  sed 's|/$||' "$tmp/$_name.members" > "$tmp/$_name.members.norm"
  tr '\0' '\n' < "$tmp/$_name.nul" | grep -v '^$' | LC_ALL=C sort -u > "$tmp/$_name.expected"
  LC_ALL=C sort -u "$tmp/$_name.members.norm" > "$tmp/$_name.actual"
  if ! cmp -s "$tmp/$_name.expected" "$tmp/$_name.actual"; then
    fatal "$_name's archive does not list the members it was given:
$(diff -u "$tmp/$_name.expected" "$tmp/$_name.actual" | head -20)"
  fi
  note "$_name: $(wc -l < "$tmp/$_name.members" | tr -d ' ') members, metadata first: $(tr '\n' ' ' < "$tmp/$_name.first3")"
}

build_pkg darling-lol "$repo/packaging/arch/PKGINFO.in" files.runtime "$runtime_out" 1
build_pkg darling-lol-launcher "$repo/packaging/arch/launcher-PKGINFO.in" files.launcher "$launcher_out" 0

# C18 at the arch level: the same assertion PLAN 5 makes of the deb and the rpm, on the artifacts
# rather than on the lists -- one path, one package.
#
# The three metadata members are excluded: every package carries its OWN .PKGINFO/.MTREE (and the
# runtime its .INSTALL), so an identical name there is not double ownership -- it is what libalpm
# requires. bsdtar's trailing slash on directory members is stripped so `usr/x` and `usr/x/` cannot
# hide an overlap.
norm_members() {
  LC_ALL=C sed -e 's|/$||' -e '/^\.PKGINFO$/d' -e '/^\.MTREE$/d' -e '/^\.INSTALL$/d' "$1" | LC_ALL=C sort
}
norm_members "$tmp/darling-lol.members" > "$tmp/rt.sorted"
norm_members "$tmp/darling-lol-launcher.members" > "$tmp/lc.sorted"
shared=$(LC_ALL=C comm -12 "$tmp/rt.sorted" "$tmp/lc.sorted")
[ -z "$shared" ] || fatal "both Arch packages claim the same path(s):
$shared"

note "done: $plain-$rel (tag $tag), $(kib_of_list files.runtime) KiB runtime, $(kib_of_list files.launcher) KiB launcher"
