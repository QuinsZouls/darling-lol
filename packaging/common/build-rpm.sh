#!/bin/sh
# packaging/common/build-rpm.sh -- the .rpm half of the distro-packaging build (PLAN 10, PLAN 10.3).
#
# Two packages, both pure metadata consumers of the T1 staging contract: darling-lol (x86_64, the
# runtime) and darling-lol-launcher (noarch). Nothing here builds a payload -- the payload is the
# tree scripts/build-packaging.sh installed and packaging/common/stage.sh described.
#
# usage:
#   sh packaging/common/build-rpm.sh fixture    # build the T1 fixture tree (mkfixture.sh) and
#                                               # package it end to end -- the same code path as
#                                               # the real build, not a parallel copy
#   sh packaging/common/build-rpm.sh TAG        # package $DARLING_PKG_DIST/pkg/root, which
#                                               # scripts/build-packaging.sh + stage.sh produced
#   ... [--render-only]                         # stop after step 7: render the specs, write the
#                                               # sources, run no rpmbuild at all. This is what
#                                               # lets the text-level gates (the rendered spec, the
#                                               # %files list, the version) run on a box with no
#                                               # rpm toolchain, and what proves the shipped
#                                               # ExclusiveArch: x86_64 even when the fixture has to
#                                               # be built for another arch (see RPM_FIXTURE_ARCH).
#
# Environment (all optional):
#   DARLING_PKG_DIST   absolute dist/ directory (default: <repo>/dist) -- the same variable
#                      scripts/build-packaging.sh honours, so both share one layout
#   RPMBUILD           the rpmbuild program (default: whatever rpmbuild is on $PATH)
#   RPM_FIXTURE_TAG    the tag fixture mode versions itself with; default: the exported TAG,
#                      else the checkout's own version (pkg-version.sh -> git describe)
#   RPM_FIXTURE_ARCH   FIXTURE MODE ONLY, and only when the host cannot build the shipped arch:
#                      it rewrites the single `ExclusiveArch:` line of the rendered runtime spec.
#                      Measured: `ExclusiveArch: x86_64` on an aarch64 host is a hard rpmbuild
#                      error ("No compatible architectures found for build", the same error
#                      `BuildArch: x86_64` gives), so the whole hostile-shape battery is unrunnable
#                      on arm64 without it. Unset = the shipped value; it CANNOT affect the
#                      production path (arg != fixture), and the harness asserts both facts. No
#                      payload shape the fixture carries is arch-specific, so the fixture's shapes
#                      are the same either way.
#
# Reads (every one of them a stage.sh product -- PLAN 7.1):
#   $dist/pkg/root             the DESTDIR staging tree
#   $dist/pkg/files.quoted     the whole tree, quoted, step 3 (the only quoting that survives the
#                              payload's 53 space-paths and 2189 %-paths -- EVIDENCE 7.2)
#   $dist/pkg/files.launcher   the launcher's paths, step 4
#   $dist/pkg/files.runtime    files.all minus files.launcher, step 5
#   $dist/pkg/files.emptydirs  the empty directories, step 3
# Writes (all under $dist):
#   pkg/rpmbuild/SPECS/{darling-lol,darling-lol-launcher}.spec        rendered by render.sh
#   pkg/{darling-lol,darling-lol-launcher}-<ver>-root.tar.zst        Source0 (REAL zstd)
#   pkg/{darling-lol,darling-lol-launcher}-filelist.txt              Source1 (paths + %attr lines)
#   pkg/{darling-lol,darling-lol-launcher}-copyright.txt             Source2
#   pkg/{darling-lol,darling-lol-launcher}-BUILD-INFO.txt            Source3
#   rpmlint.toml                                                     the rpmlint config (PLAN 10)
#   darling-lol-<ver>-<rel>.<arch>.rpm, darling-lol-launcher-<ver>-<rel>.noarch.rpm
#
# Source0 is REAL zstd under its .tar.zst name, in both modes (--render-only writes the sources
# too), so `zstd` must be on PATH: the script REFUSES without it instead of writing an xz payload
# under a zstd name (see the guard below). The plan's own reference output for a .tar.zst is
# `zstd -19 -T0` (EVIDENCE 7.3: 92 572 857 B vs 145 062 479 B for the published .tar.gz) and T6's
# sibling build-tar.sh ships zstd for the release tarballs, so an xz-in-a-.zst would make two
# sibling artifacts of one build disagree about what `.tar.zst` means.
#
# rpmbuild is not available on the development box (Ubuntu/arm64, no rpm at all): every rpm gate
# runs inside fedora:41 -- see packaging/testdata/run-rpm-gates.sh, which calls this script there.
# (`zstd` IS on this box, and in the gate image it arrives with rpm-build -- measured: rpm-build
# Requires: zstd, so `darling-rpm-gates:fc41` carries the CLI without an extra install step.)
set -eu

dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo=$(CDPATH='' cd -- "$dir/../.." && pwd)
prog=build-rpm

fatal() { echo "$prog: FATAL $*" >&2; exit 1; }
note() { echo "$prog: $*"; }

# --- 1. arguments -------------------------------------------------------------------------------
[ "$#" -ge 1 ] || fatal "usage: sh packaging/common/build-rpm.sh {fixture|TAG} [--render-only]"
case $1 in
  -h | --help)
    sed -n '2,54p' "$0"
    exit 0
    ;;
esac
arg=$1
shift
render_only=0
for _a in "$@"; do
  case $_a in
    --render-only) render_only=1 ;;
    *) fatal "unknown option '$_a' (usage: sh packaging/common/build-rpm.sh {fixture|TAG} [--render-only])" ;;
  esac
done

dist=${DARLING_PKG_DIST:-$repo/dist}
case "$dist" in
  /*) : ;;
  *) fatal "DARLING_PKG_DIST must be an absolute path (got '$dist')" ;;
esac
pkg=$dist/pkg

rpmbuild=${RPMBUILD:-rpmbuild}
[ "$render_only" = 1 ] || command -v "$rpmbuild" >/dev/null 2>&1 || fatal "rpmbuild not found.
  This box has no rpm toolchain at all (measured: rpmbuild/rpmspec/rpm/rpmlint are all absent on
  Ubuntu 24.04/arm64). Run the build and its gates inside a Fedora container -- PLAN 10.3:
      docker run --rm -v \"\$PWD/dist:/w\" -v \"\$PWD:/src:ro\" fedora:41 bash -lc \\
        'dnf -y install rpm-build && sh /src/packaging/common/build-rpm.sh fixture'"

# --- 1b. the Source0 compressor: REAL zstd, or nothing -------------------------------------------
# Both tars are named `...-root.tar.zst` and must BE zstd. The alternative spellings are not
# equivalent on this toolchain (measured, GNU tar 1.35 + zstd 1.5.7 in the gate image): `tar -Jtf`
# reads ONLY xz (rc=2 `xz: (stdin): File format not recognized` on a real zstd tar), while
# `tar -t -I zstd -f` reads BOTH (zstd's CLI auto-detects xz here) -- which is why the spec is
# allowed to keep the robust read spelling and this end owns the bytes. There is deliberately NO
# fallback to xz in this script: a `.zst` name on an xz payload is a lie no reader can see, and
# the plan's own .tar.zst reference output (EVIDENCE 7.3) and T6's build-tar.sh both say zstd.
command -v zstd >/dev/null 2>&1 || fatal "zstd not found on PATH.
  Source0 is named '<pkg>-<ver>-root.tar.zst' and its bytes must be real zstd: the plan's own
  .tar.zst reference output is 'zstd -19 -T0' (EVIDENCE 7.3), and T6's build-tar.sh ships zstd for
  the release tarballs. Refusing rather than falling back to xz -- an xz payload under a .zst name
  is a silent lie (measured: 'tar -Jtf' and 'tar --zstd -tf' each read only one flavour).
  Install zstd (fedora: rpm-build pulls it in; debian/ubuntu: apt-get install zstd) and re-run."

# --- 2. the staged tree: fixture mode produces one, the real mode requires one -----------------
mkdir -p "$pkg"
if [ "$arg" = fixture ]; then
  # The fixture tag is what the run was given (RPM_FIXTURE_TAG, else the exported TAG that
  # build-all.sh sets) and otherwise the checkout's own version -- the same single derivation the
  # production path uses (pkg-version.sh -> git describe). packaging/common/ never carries a
  # literal version (G-STATIC); a git-less copy still renders the 0.0.0 dev form.
  tag=${RPM_FIXTURE_TAG:-${TAG:-$(sh "$dir/pkg-version.sh")}}
  note "fixture mode: staging the hostile-shape tree with packaging/testdata/mkfixture.sh"
  # mkfixture gets the pkg dir itself, so the fixture's DESTDIR is $pkg/root -- exactly where the
  # real build puts it. That is what makes the two modes share the artifacts (and the paths in
  # them) instead of merely sharing the code.
  sh "$repo/packaging/testdata/mkfixture.sh" "$pkg"
  sh "$dir/stage.sh" "$pkg/root" "$pkg"
else
  tag=$arg
  [ -d "$pkg/root" ] || fatal "$pkg/root is missing.
  Run scripts/build-packaging.sh (it needs x86-64) and then packaging/common/stage.sh, or use
  the 'fixture' mode."
fi
[ -d "$pkg/root" ] || fatal "$pkg/root is missing"
for f in files.quoted files.launcher files.runtime files.emptydirs; do
  [ -s "$pkg/$f" ] || fatal "$pkg/$f is missing or empty: stage.sh did not produce it"
done

# --- 3. version: one derivation (pkg-version.sh), never a literal here -------------------------
ver=$(sh "$dir/pkg-version.sh" "$tag") || fatal "'$tag' is not a version tag and not a commit hash"
note "version $ver (tag $tag)"

tmp=$pkg/rpm-tmp
topdir=$pkg/rpmbuild
rm -rf "$tmp" "$topdir"
mkdir -p "$tmp" "$topdir/BUILD" "$topdir/BUILDROOT" "$topdir/RPMS" "$topdir/SOURCES" \
  "$topdir/SPECS" "$topdir/SRPMS"

# --- 4. the two file lists ----------------------------------------------------------------------
# 🚨 `files.quoted` (stage.sh step 3) is the *whole* tree, quoted -- it is the quoted form of
# files.all, and it also carries the launcher's paths and the empty directories. The runtime
# package must own files.runtime (PLAN 5, and G-STATIC-6/C18: the two packages may not claim the
# same files, or dnf refuses to install the pair that PLAN 16.2 installs together), and the empty
# directories are owned by the generated `%dir` block instead (step 5), so the runtime list is
# files.quoted minus the lines whose path is in files.launcher or in files.emptydirs -- and **no
# quoting is added**: every line emitted is a byte-identical copy of a line stage.sh wrote.
# Re-quoting an already quoted list is the corruption EVIDENCE 7.2 measured (53 space-paths,
# 2189 %-paths).
#
# Why subtract the empty dirs as well: PLAN 10.1 note 3 says an empty dir "must be listed as %dir
# or rpm refuses to own (and later remove) them", but a *measured* run of the listed-only shape
# (rpm 4.20.1) shows a bare empty dir that the `-f` list carries IS owned (`040755` in --dump) and
# IS removed on erase -- so with the plan's own spec the `%dir` block is redundant and rpm says
# "warning: File listed twice" for each one. Subtracting makes the note true by construction, drops
# the warning, and keeps exactly one owner per path (the same reasoning as the launcher split).
cat "$pkg/files.launcher" "$pkg/files.emptydirs" > "$tmp/runtime.exclude"
awk 'NR == FNR { skip[$0] = 1; next }
     { t = $0; sub(/^"/, "", t); sub(/"$/, "", t); if (!(t in skip)) print }' \
  "$tmp/runtime.exclude" "$pkg/files.quoted" > "$pkg/darling-lol-filelist.txt"
[ -s "$pkg/darling-lol-filelist.txt" ] || fatal "the runtime file list is empty"
# The subtraction must reproduce files.runtime exactly (quoted), minus the %dir block's paths.
# This is the same invariant G-STATIC-6 asserts of stage.sh, re-asserted here because the rpm
# consumes the quoted form.
sed 's/^"//; s/"$//' "$pkg/darling-lol-filelist.txt" | LC_ALL=C sort > "$tmp/runtime.stripped"
LC_ALL=C sort "$pkg/files.runtime" > "$tmp/runtime.all.sorted"
LC_ALL=C sort "$pkg/files.emptydirs" > "$tmp/emptydirs.sorted"
LC_ALL=C comm -23 "$tmp/runtime.all.sorted" "$tmp/emptydirs.sorted" > "$tmp/runtime.expected"
cmp -s "$tmp/runtime.stripped" "$tmp/runtime.expected" || fatal \
"the quoted runtime list is not files.runtime minus files.emptydirs.
  $(diff -u "$tmp/runtime.expected" "$tmp/runtime.stripped" | head -20)"
# Every emitted line must be a byte-identical copy of a stage.sh line (no re-quoting, no
# re-ordering, no whitespace repair): the rpm's file list is not ours to rewrite. Compared in
# stripped form because files.quoted is the quoted list, and the stripping here is the same
# single pass the invariant above uses -- nothing else.
LC_ALL=C sed 's/^"//; s/"$//' "$pkg/files.quoted" | LC_ALL=C sort > "$tmp/quoted.stripped"
LC_ALL=C comm -23 "$tmp/runtime.stripped" "$tmp/quoted.stripped" > "$tmp/not.verbatim"
[ ! -s "$tmp/not.verbatim" ] || fatal \
"$(wc -l < "$tmp/not.verbatim") runtime list line(s) are NOT byte-identical to a stage.sh line:
  $(head -5 "$tmp/not.verbatim")"
# The launcher list is stage.sh step 4's own file, unquoted, copied as-is: its paths are the
# repo's own fixed names (no spaces), and it is the list G-STATIC-6 checks the split with.
cp "$pkg/files.launcher" "$pkg/darling-lol-launcher-filelist.txt"

# --- 5. the two generated %files blocks ---------------------------------------------------------
# `%dir` must exist for every entry of files.emptydirs or the directory is not owned (PLAN 10.1
# note 3), and the list is dynamic (51 entries in the real payload, 2 in the fixture), so it
# cannot be written into the template. The block is generated here and spliced in at its marker.
# Quoted, because the payload really does contain empty directories whose names have spaces
# (`System/Library/User Template`): rpm's %files parser splits unquoted names on whitespace.
while IFS= read -r p; do
  [ -n "$p" ] || continue
  printf '%%dir "%s"\n' "$p"
done < "$pkg/files.emptydirs" > "$tmp/block.emptydirs"

# The hardened paths of PLAN 10.1, emitted only when the staged tree actually carries them: a
# `%files` entry that names a path the buildroot does not have is a hard rpmbuild error, and the
# T1 fixture legitimately carries three of the four (it has no guest mldr). A real payload that
# is missing one is reported, never silently dropped.
#
# C52: these lines go INTO the generated file list (Source1), not into the spec as a second,
# explicit block. A path owned both through `-f %{SOURCE1}` and explicitly is `warning: File
# listed twice` (measured on rpm 4.20.1 -- the plan's C52 rationale says rc=1, which does NOT
# reproduce in isolation: the warning is real, the build keeps going, rc=0), and upstream's own
# idiom is a generated list that carries its %attr lines. They stay load-bearing either way: rpm
# applies %attr OVER whatever Source0 carried, so a lost setuid bit in the payload cannot reach
# the package (G-RPM-2 measures 0104755 over a sibling staged 0644).
#
# The %attr line therefore REPLACES the path's plain entry, it is never appended next to it:
# appending does reproduce the "File listed twice" warning (measured: 3 distinct paths, 3 warnings
# with the append shape), and the list has to stay one entry per path or the C52 fix just moves the
# duplicate from the spec into the list. `%files -f` consumes both shapes, so the entry that
# survives carries the mode -- G-RPM-2 asserts `0 File listed twice` over the build log so this
# cannot regress back to the append shape silently.
#
# T4 -> T6 EDGE: this generator is the one the plan's C52 moves into T6's build rules; the shape
# here is the contract T6 inherits -- `%attr(<mode>,root,root) "<path>"` per hardened path, in the
# same quoted list `%files -f %{SOURCE1}` consumes, with no second copy of the path anywhere, so
# the attrs travel with the Source1 payload's own permissions.
hardened=0
: > "$tmp/hardened.paths"
: > "$tmp/hardened.attrs"
while IFS='|' read -r path mode; do
  [ -n "${path:-}" ] || continue
  if grep -qxF "/$path" "$pkg/files.runtime"; then
    printf '"/%s"\n' "$path" >> "$tmp/hardened.paths"
    printf '%%attr(%s,root,root) "/%s"\n' "$mode" "$path" >> "$tmp/hardened.attrs"
    hardened=$((hardened + 1))
  else
    note "note: hardened path /$path is absent from files.runtime -- no %attr line emitted"
  fi
done <<'HARDENED'
usr/bin/darling|4755
usr/bin/darlingserver|0755
usr/bin/darling-coredump|0755
usr/libexec/darling/usr/libexec/darling/mldr|0755
HARDENED
[ "$hardened" -gt 0 ] || fatal "no hardened path is present in the staged tree: it is not a darling tree"
# One entry per path: drop the plain line of every hardened path, then add its %attr form.
grep -vxF -f "$tmp/hardened.paths" "$pkg/darling-lol-filelist.txt" > "$tmp/filelist.replaced"
cat "$tmp/hardened.attrs" >> "$tmp/filelist.replaced"
mv "$tmp/filelist.replaced" "$pkg/darling-lol-filelist.txt"

# The %changelog (C54). rpm's `%_source_date_epoch_from_changelog` (on in Fedora) takes the rpm's
# source date from the newest %changelog entry; with no %changelog rpmbuild says exactly
# "warning: %source_date_epoch_from_changelog is set, but %changelog has no entries to take a date
# from" (measured) and the package has no pinned source date. The date is pinned from the SOURCE,
# never from the clock:
#   * $SOURCE_DATE_EPOCH when the reproducible-builds variable is set (this is what the gate pins,
#     so the date is a literal in the battery rather than "whatever day it ran");
#   * else the HEAD commit's own committer date, which is stable for a given commit and is the
#     date of the sources being packaged;
#   * else -- a git-less tree, where nothing about the build is reproducible anyway -- today's UTC
#     date, and the note below says so out loud.
# render.sh has no @CHANGELOG_DATE@ token (its 18-name table is T1's, untouched here), so this
# generator is the T4 -> T1 edge: the plan's C44/C54 want the token; until T1 grows it, the date
# is resolved here, from the same source the token would have come from.
if [ -n "${SOURCE_DATE_EPOCH:-}" ]; then
  chlog_date=$(date -u -d "@$SOURCE_DATE_EPOCH" '+%a %b %d %Y')
elif chlog_epoch=$(git log -1 --format=%ct 2>/dev/null) && [ -n "$chlog_epoch" ]; then
  chlog_date=$(date -u -d "@$chlog_epoch" '+%a %b %d %Y')
else
  chlog_date=$(date -u '+%a %b %d %Y')
  note "note: no SOURCE_DATE_EPOCH and no git metadata: the %changelog date is today's UTC date"
fi
{
  printf '%%changelog\n'
  printf '* %s darling-lol maintainers - @RPM_VERSION@-@RPM_RELEASE@\n' "$chlog_date"
  printf -- '- Packaged from the staged tree at /usr; provenance in BUILD-INFO.txt.\n'
} > "$tmp/block.changelog"

# --- 6. the specs: splice the generated blocks, then render (never a hand-copied dep string) -----
render_one() { # render_one NAME TEMPLATE
  _name=$1
  _in=$2
  _spliced=$tmp/$_name.spec.in
  awk -v cf="$tmp/block.changelog" -v ef="$tmp/block.emptydirs" '
    /^@RPM_CHANGELOG@$/ { while ((getline l < cf) > 0) print l; close(cf); next }
    /^@RPM_EMPTYDIRS@$/ { while ((getline l < ef) > 0) print l; close(ef); next }
    { print }
  ' "$_in" > "$_spliced"
  # render.sh refuses to emit a leftover @TOKEN@ (G-STATIC-4), so a lost splice fails the build.
  sh "$dir/render.sh" --family rpm --tag "$tag" "$_spliced" > "$topdir/SPECS/$_name.spec"
}
render_one darling-lol "$repo/packaging/rpm/darling-lol.spec.in"
render_one darling-lol-launcher "$repo/packaging/rpm/darling-lol-launcher.spec.in"

# FIXTURE ONLY: the shipped runtime spec pins ExclusiveArch x86_64, and rpmbuild 4.20.1 on
# another arch refuses it outright ("No compatible architectures found for build" -- measured on
# aarch64, the same error `BuildArch: x86_64` gives). No payload shape the fixture carries is
# arch-specific, so an arm64 host can still run the whole hostile-shape battery -- but it has to
# say so, and it may only touch the fixture. The production path (arg != fixture) ignores the knob
# entirely, and the harness asserts both halves.
fixture_arch=${RPM_FIXTURE_ARCH:-}
if [ "$arg" = fixture ] && [ -n "$fixture_arch" ] && [ "$fixture_arch" != x86_64 ]; then
  _spec=$topdir/SPECS/darling-lol.spec
  [ "$(grep -c '^ExclusiveArch:[[:space:]]*x86_64$' "$_spec")" = 1 ] || fatal \
  "expected exactly one 'ExclusiveArch: x86_64' line in $_spec to rewrite for the fixture"
  sed "s/^ExclusiveArch:[[:space:]]*x86_64\$/ExclusiveArch:  $fixture_arch/" "$_spec" > "$_spec.tmp"
  mv "$_spec.tmp" "$_spec"
  note "FIXTURE ONLY: ExclusiveArch rewritten x86_64 -> $fixture_arch (this host cannot build x86_64)."
  note "FIXTURE ONLY: the SHIPPED render still pins x86_64 -- run with --render-only to see it."
fi

# --- 7. the sources -----------------------------------------------------------------------------
# Source0 (runtime): the runtime's OWN path set, stage.sh's files.runtime. PLAN 10.3 writes it as
# `tar -C dist/pkg/root -cJf ... .` -- the WHOLE tree -- but the whole tree carries the launcher's
# paths too, and the runtime spec cannot package them (it owns files.runtime by C18/PLAN 5), so
# rpmbuild refuses the build outright: measured, "Installed (but unpackaged) file(s) found:
# /usr/bin/darling-lol /usr/lib/darling-lol/... /usr/share/doc/darling-lol/README-packaging.md".
# Feeding Source0 from the runtime's own set is the smallest faithful fix: it is the same file the
# spec's %files consumes, the same shape step 7 already uses for the launcher, and the same split
# PLAN 9.7 stages. Nothing about what the runtime owns changes. The list is NUL-separated because
# it is unquoted: GNU tar's -T splits on newlines, so a space in a path would silently become two
# member names.
# Note the bytes: REAL zstd under the .tar.zst name, both ends. The spec reads Source0 with
# `-I zstd -f` (measured to read BOTH flavours, so the reader is robust either way) and this end
# writes what the name promises -- `zstd -19 -T0`, the plan's own .tar.zst reference output
# (EVIDENCE 7.3) and the compression T6's build-tar.sh uses for the release tarballs. The plan's
# §10.3 recipe writes `-cJf` (xz) into the same name; that half is the wrong side of §10.1/C50.
sed 's|^/||' "$pkg/files.runtime" | tr '\n' '\0' > "$tmp/runtime.nul"
tar -C "$pkg/root" --null -T "$tmp/runtime.nul" -I 'zstd -19 -T0' -cf "$pkg/darling-lol-$ver-root.tar.zst"

# Source0 (launcher): only the launcher's paths (PLAN 9.7 stages them separately). Same NUL form.
sed 's|^/||' "$pkg/files.launcher" | tr '\n' '\0' > "$tmp/launcher.nul"
tar -C "$pkg/root" --null -T "$tmp/launcher.nul" -I 'zstd -19 -T0' -cf "$pkg/darling-lol-launcher-$ver-root.tar.zst"

# Both tars must carry exactly the paths the spec will own: nothing missing (a missing path is a
# missing file) and no extra FILE (an extra path is "Installed (but unpackaged) file(s) found", the
# measured failure mode of PLAN 10.3's whole-tree tar -- see the comment above). Directory entries
# are ignored on the extra side: tar adds the parent directories of the members it was given, which
# is exactly what unpacking needs.
for pair in "darling-lol:files.runtime" "darling-lol-launcher:files.launcher"; do
  _pkgname=${pair%%:*}
  _list=${pair#*:}
  _tar=$pkg/$_pkgname-$ver-root.tar.zst
  # The bytes must match the name: real zstd, not "whatever the compressor happened to be". A
  # reader that trusts `.tar.zst` (or `tar --zstd`) cannot see an xz payload, so the builder
  # refuses to write one -- and says which byte said no.
  _magic=$(od -An -tx1 -N4 "$_tar" | tr -d ' \n')
  [ "$_magic" = 28b52ffd ] || fatal "$_pkgname-$ver-root.tar.zst is NOT zstd: magic '$_magic', want 28b52ffd.
  The compressor is pinned in this script ('zstd -19 -T0') and the .zst name is a promise; an xz
  payload under it is invisible to every reader that trusts the name."
  # Read back with `-I zstd -f`, the spelling the spec's %install uses (measured to read both
  # flavours, so it is the robust side even though this writer only ever emits zstd).
  tar -t -I zstd -f "$_tar" > "$tmp/tar.contents"
  sed 's|/$||; s|^\./||' "$tmp/tar.contents" | grep -v '^$' | LC_ALL=C sort -u > "$tmp/tar.all"
  grep -v '/$' "$tmp/tar.contents" | sed 's|^\./||' | grep -v '^$' | LC_ALL=C sort -u > "$tmp/tar.files"
  sed 's|^/||' "$pkg/$_list" | LC_ALL=C sort -u > "$tmp/tar.expected"
  _missing=$(LC_ALL=C comm -23 "$tmp/tar.expected" "$tmp/tar.all")
  _extra=$(LC_ALL=C comm -13 "$tmp/tar.expected" "$tmp/tar.files")
  [ -z "$_missing" ] || fatal "$_pkgname-$ver-root.tar.zst is MISSING $_list paths:
  $(printf '%s\n' "$_missing" | head -5)"
  [ -z "$_extra" ] || fatal "$_pkgname-$ver-root.tar.zst carries FILES that $_list does not:
  $(printf '%s\n' "$_extra" | head -5)"
done

# Source2: the copyright text. PLAN 9.5 owns this generator for the deb; T4's file list has no
# copyright producer, and packaging/deb/ is another task's tree, so the rpm half derives it here
# from the same source (§9.5: our header + the pinned upstream debian/copyright body), with the
# fork's NOTICE.md as the fallback when the pin has not been fetched. T6 unifies the producer.
write_copyright() { # write_copyright OUT
  cat <<'EOF' > "$1"
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: darling
Upstream-Contact: https://www.darlinghq.org/
Source: https://github.com/darlinghq/darling
        (pinned at 60ba801decee7a00782f74f6be4c8ffb013f79ff, patched by darling-lol)

Files: *
Copyright: 2013-2026 Lubos Dolezel and the Darling contributors
           2026 darling-lol contributors
License: GPL-3.0-or-later
Comment: The guest tree under /usr/libexec/darling additionally contains code derived from
         Apple's open-source releases, under the Apple Public Source License 2.0, and
         third-party components under their own licenses. The per-directory stanzas copied
         from the pinned upstream debian/copyright follow below when they are available; the
         repository's LICENSE and NOTICE.md carry the fork's own terms either way.
EOF
  if [ -r "$repo/build/darling-src/debian/copyright" ]; then
    printf '\n# --- copied verbatim from the pinned upstream debian/copyright (PLAN 9.5) ---\n\n' >> "$1"
    cat "$repo/build/darling-src/debian/copyright" >> "$1"
  else
    printf '\n# --- upstream debian/copyright is not fetched on this box (scripts/configure.py +\n' >> "$1"
    printf '#     prepare.py populate build/darling-src/); the fork own terms follow instead ---\n\n' >> "$1"
    cat "$repo/NOTICE.md" >> "$1"
    printf '\n# --- LICENSE (verbatim) ---\n\n' >> "$1"
    cat "$repo/LICENSE" >> "$1"
  fi
}

# Source3: provenance, from the merged generator, never hand-written (PLAN 12.3).
# The rpm payload token is READ FROM THE SPEC that pins it -- one spelling, one place. Otherwise the
# packaged BUILD-INFO.txt contradicts the package: build-info.sh:47 (T1, merged) defaults to the
# plan's `w19T.zstd`, which rpmbuild REJECTS (`Unknown payload compression`, rc=1) while the spec
# pins rpmio's `w19T.zstdio` -- measured before this pin: the built rpm's
# %{_docdir}/darling-lol/BUILD-INFO.txt said `rpm-payload: w19T.zstd`. T4 -> T1 EDGE (PLAN C51): the
# real fix is build-info.sh's own default; this is T4's local pin so the published provenance is not
# false today, and the battery asserts the two sites agree.
rpm_payload=$(sed -n 's/^%global _binary_payload //p' "$repo/packaging/rpm/darling-lol.spec.in" | head -1)
[ -n "$rpm_payload" ] || fatal "no '%global _binary_payload' pin in packaging/rpm/darling-lol.spec.in"
COMPONENTS=${COMPONENTS:-stock} PKG_PREFIX=${PKG_PREFIX:-/usr} RPM_PAYLOAD="$rpm_payload" \
  sh "$dir/build-info.sh" "$pkg/darling-lol-BUILD-INFO.txt"

for n in darling-lol darling-lol-launcher; do
  write_copyright "$pkg/$n-copyright.txt"
  # the runtime's BUILD-INFO.txt is Source3 for both packages; copying it onto itself is an error
  # with `set -e`, not a no-op (measured: cp: '...' and '...' are the same file)
  [ "$n" = darling-lol ] || cp "$pkg/darling-lol-BUILD-INFO.txt" "$pkg/$n-BUILD-INFO.txt"
done

# --- 8. rpmbuild --------------------------------------------------------------------------------
# --render-only stops here: the specs are rendered and the sources written, and no rpmbuild runs.
# That is how the text-level gates (the rendered spec, the %files list, the version, the token
# guard) run on a box with no rpm toolchain at all -- and how the SHIPPED ExclusiveArch: x86_64 is
# still provable from an arm64 host, which cannot build it.
if [ "$render_only" = 1 ]; then
  note "render-only: specs rendered, sources written, no rpmbuild (as asked)"
  note "done: $(sh "$dir/pkg-version.sh" --rpm "$tag")"
  exit 0
fi

# --define "dist .fc41" is pinned rather than left to the build host (the host is Ubuntu and its
# %dist is empty -- PLAN 10.3). The rendered Release already ends in .lol.fc41 because
# pkg-version.sh renders it (DIST=fc41), so this define is belt-and-braces, not the source of the
# value; it is passed because the plan pins it and because a future %{?dist} in the template must
# not silently pick up the host's empty one.
build_rpm() { # build_rpm SPECNAME
  "$rpmbuild" -bb "$topdir/SPECS/$1.spec" \
    --define "_topdir $topdir" \
    --define "_sourcedir $pkg" \
    --define "dist .fc41" \
    --buildroot "$topdir/BUILDROOT"
}
build_rpm darling-lol
build_rpm darling-lol-launcher

for r in "$topdir"/RPMS/*/*.rpm; do
  [ -e "$r" ] || continue
  cp "$r" "$dist/"
  note "wrote $dist/${r##*/}"
done
# rpmlint.toml is copied next to the packages because PLAN 10's lint command (and PLAN 22's CI
# block) mount $dist as /w and pass /w/rpmlint.toml: the config has to travel with the artifacts
# it describes, or the gate command in the plan cannot be typed as written.
cp "$repo/packaging/rpm/rpmlint.toml" "$dist/rpmlint.toml"
note "wrote $dist/rpmlint.toml"
note "done: $(sh "$dir/pkg-version.sh" --rpm "$tag")"
