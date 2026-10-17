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
#   RPM_FIXTURE_TAG    the tag fixture mode versions itself with (default: v0.1.0)
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
#   pkg/{darling-lol,darling-lol-launcher}-<ver>-root.tar.zst        Source0
#   pkg/{darling-lol,darling-lol-launcher}-filelist.txt              Source1
#   pkg/{darling-lol,darling-lol-launcher}-copyright.txt             Source2
#   pkg/{darling-lol,darling-lol-launcher}-BUILD-INFO.txt            Source3
#   rpmlint.toml                                                     the rpmlint config (PLAN 10)
#   darling-lol-<ver>-<rel>.<arch>.rpm, darling-lol-launcher-<ver>-<rel>.noarch.rpm
#
# rpmbuild is not available on the development box (Ubuntu/arm64, no rpm at all): every rpm gate
# runs inside fedora:41 -- see packaging/testdata/run-rpm-gates.sh, which calls this script there.
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

# --- 2. the staged tree: fixture mode produces one, the real mode requires one -----------------
mkdir -p "$pkg"
if [ "$arg" = fixture ]; then
  tag=${RPM_FIXTURE_TAG:-v0.1.0}
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
: > "$tmp/block.hardened"
while IFS='|' read -r path macro mode; do
  [ -n "${path:-}" ] || continue
  if grep -qxF "/$path" "$pkg/files.runtime"; then
    printf '%%attr(%s,root,root) %s\n' "$mode" "$macro" >> "$tmp/block.hardened"
  else
    note "note: hardened path /$path is absent from files.runtime -- no %attr line emitted"
  fi
done <<'HARDENED'
usr/bin/darling|%{_bindir}/darling|4755
usr/bin/darlingserver|%{_bindir}/darlingserver|0755
usr/bin/darling-coredump|%{_bindir}/darling-coredump|0755
usr/libexec/darling/usr/libexec/darling/mldr|%{_libexecdir}/darling/usr/libexec/darling/mldr|0755
HARDENED
[ -s "$tmp/block.hardened" ] || fatal "no hardened path is present in the staged tree: it is not a darling tree"

# --- 6. the specs: splice the generated blocks, then render (never a hand-copied dep string) -----
render_one() { # render_one NAME TEMPLATE
  _name=$1
  _in=$2
  _spliced=$tmp/$_name.spec.in
  awk -v hf="$tmp/block.hardened" -v ef="$tmp/block.emptydirs" '
    /^@RPM_HARDENED@$/  { while ((getline l < hf) > 0) print l; close(hf); next }
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
# Note the -J: it is xz, not zstd, despite the .tar.zst name -- both ends (here and %install in the
# spec) use -J, so it round-trips; reported as a plan inconsistency rather than "fixed" silently.
sed 's|^/||' "$pkg/files.runtime" | tr '\n' '\0' > "$tmp/runtime.nul"
tar -C "$pkg/root" --null -T "$tmp/runtime.nul" -cJf "$pkg/darling-lol-$ver-root.tar.zst"

# Source0 (launcher): only the launcher's paths (PLAN 9.7 stages them separately). Same NUL form.
sed 's|^/||' "$pkg/files.launcher" | tr '\n' '\0' > "$tmp/launcher.nul"
tar -C "$pkg/root" --null -T "$tmp/launcher.nul" -cJf "$pkg/darling-lol-launcher-$ver-root.tar.zst"

# Both tars must carry exactly the paths the spec will own: nothing missing (a missing path is a
# missing file) and no extra FILE (an extra path is "Installed (but unpackaged) file(s) found", the
# measured failure mode of PLAN 10.3's whole-tree tar -- see the comment above). Directory entries
# are ignored on the extra side: tar adds the parent directories of the members it was given, which
# is exactly what unpacking needs.
for pair in "darling-lol:files.runtime" "darling-lol-launcher:files.launcher"; do
  _pkgname=${pair%%:*}
  _list=${pair#*:}
  _tar=$pkg/$_pkgname-$ver-root.tar.zst
  tar -tJf "$_tar" > "$tmp/tar.contents"
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
COMPONENTS=${COMPONENTS:-stock} PKG_PREFIX=${PKG_PREFIX:-/usr} \
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