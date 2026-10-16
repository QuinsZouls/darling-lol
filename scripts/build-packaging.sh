#!/bin/sh
# scripts/build-packaging.sh -- the distro-packaging build of the Darling runtime: prefix /usr (D1).
#
# Same pin, same patches and the same base cmake flags as scripts/build.sh. The four packaging
# flags are load-bearing: one is the prefix build.sh also sets, with another value, and three exist
# only in this build (PLAN 3.1, C7/C8/C9):
#
#   CMAKE_INSTALL_PREFIX=/usr   Debian Policy 9.1.2, Fedora and Arch all forbid /usr/local, and
#       LIBEXEC_PATH is a *compile-time* string inside darlingserver with no environment
#       override, so the prefix cannot be moved after the fact: relocating the files of the
#       published /usr/local artifact produces a runtime that installs clean and dies in
#       mount("overlay")/execl(mldr). That is why this is a second full build, not a repack.
#   CMAKE_INSTALL_LIBDIR=lib    GNUInstallDirs would pick lib/x86_64-linux-gnu on Debian and
#       lib64 on Fedora; one build feeds all four formats, so the layout has to be pinned or the
#       deb and the rpm diverge (C8). It also puts the binfmt.d drop-in at /usr/lib/binfmt.d on
#       every family, which is the path systemd scans on all of them. Never lib64.
#   COMPONENTS=stock            Explicit, because DEBIAN_PACKAGING flips  CMake's default to
#       "all" (C9). stock is the *validated* composition: the published v0.1.0 was built with
#       build.sh, i.e. stock (C17); "all" adds devenv/gui/python2/ruby/perl/pyobjc/jsc and is
#       unvalidated. Never omit it.
#   DEBIAN_PACKAGING=ON         Mandatory for packaging (C9): it skips the install(CODE) hook that
#       runs tools/shutdown-user.sh, which the fork's patch turns into a FATAL_ERROR.
#
# The script owns the build *and* the DESTDIR install, so that the flags live in exactly one place
# (PLAN 3.3, "the workflow calls it and never inlines cmake flags"), the install log is asserted
# here instead of by a copy of the assertion living in a YAML file, and the artefact states in
# BUILD-INFO-packages.txt what it was built with.
#
# 🚨 R6 (the missing `install-bin` manifest entry, C17) is answered in the comment above
# check_install_log(): it is NOT a COMPONENTS question. Do not re-open it as one.
#
# usage: [JOBS=n] sh scripts/build-packaging.sh
#
# Environment (all optional):
#   JOBS                      parallel make jobs (default: nproc)
#   DARLING_PKG_PREFIX        install prefix, packages require /usr (default: /usr)
#   DARLING_PKG_LIBDIR        CMAKE_INSTALL_LIBDIR, must be lib (default: lib -- C8)
#   DARLING_PKG_COMPONENTS    COMPONENTS, must be stock (default: stock -- C9)
#   DARLING_PKG_DIST          absolute dist/ directory (default: ${GITHUB_WORKSPACE:-<repo>}/dist)
#   DARLING_PKG_LOG           install log (default: <repo>/build/install-pkg.log)
#   DARLING_PKG_CLEAN_ROOT    =1: remove an existing staging tree first (opt-in, path-guarded)
#   GITHUB_WORKSPACE          CI: the checkout root the staging tree is built under
#
# Not runnable on a non-x86-64 host: the build is x86-64 only (TARGET_i386=OFF, and the patched
# OpenDirectory needs the 64-bit ABI). G-PKG-2/G-PKG-3/G-PKG-4 are CI gates.
set -eu

# `set -o pipefail` stops the `| tee` below from reporting tee's status instead of cmake's. dash
# -- the `sh` on the runner, 0.5.12 -- rejects the option with "Illegal option -o pipefail", so it
# is requested rather than assumed and the install step below checks a status of its own either
# way. Do not replace this with a bare `set -euo pipefail`: under `sh` that aborts on line 1.
have_pipefail=0
# shellcheck disable=SC3040  # `set -o pipefail` is not POSIX: requested here, never assumed.
if (set -o pipefail) 2>/dev/null; then
	set -o pipefail
	have_pipefail=1
fi

fatal() {
	echo "build-packaging: FATAL $*" >&2
	exit 1
}

note() {
	echo "build-packaging: $*"
}

# --- 0. No arguments ---------------------------------------------------------------------------
# The flags come from the environment (listed in the header), never from $@. Rejecting arguments
# loudly beats silently ignoring a typo'd one.
[ "$#" -eq 0 ] || fatal "this script takes no arguments (see the header for the DARLING_PKG_* overrides)"

# --- 1. Locations: absolute, derived from $0, never from the current directory -----------------
repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
[ -f "$repo/upstream/manifest.json" ] || fatal "$repo does not look like the darling-lol checkout"
dist=${DARLING_PKG_DIST:-${GITHUB_WORKSPACE:-$repo}/dist}
case "$dist" in
	/*) : ;;
	*) fatal "DARLING_PKG_DIST must be an absolute path (got '$dist')" ;;
esac
pkg_root=$dist/pkg/root
install_log=${DARLING_PKG_LOG:-$repo/build/install-pkg.log}
build_info=$dist/BUILD-INFO-packages.txt
src_tree=$repo/build/darling-src
build_tree=$src_tree/build
# configure.py/prepare.py and cmake's relative arguments are documented from the checkout root;
# every path this script *writes* is absolute regardless.
cd "$repo"

# --- 2. The packaging flags: the ONE place they are written (PLAN 3.3) -------------------------
# The cmake invocation below expands this argument list and the BUILD-INFO line at the end records
# the same expansion, so what was built and what the artefact says cannot drift -- and a grep can
# prove the four flags appear exactly once in this file.
pkg_prefix=${DARLING_PKG_PREFIX:-/usr}
pkg_libdir=${DARLING_PKG_LIBDIR:-lib}
pkg_components=${DARLING_PKG_COMPONENTS:-stock}
[ "$pkg_libdir" = lib ] || fatal "CMAKE_INSTALL_LIBDIR must be 'lib' (got '$pkg_libdir'): lib64 diverges the rpm from the deb (C8)"
[ "$pkg_prefix" = /usr ] || note "warning: prefix '$pkg_prefix' is not /usr; the packages require /usr (C7)"
[ "$pkg_components" = stock ] || note "warning: COMPONENTS='$pkg_components' is not stock; stock is the validated composition (C9/C17)"
set -- \
	-DCMAKE_INSTALL_PREFIX="$pkg_prefix" \
	-DCMAKE_INSTALL_LIBDIR="$pkg_libdir" \
	-DCOMPONENTS="$pkg_components" \
	-DDEBIAN_PACKAGING=ON
pkg_cmake_flags=$*

# --- 3. Preflight: the staging tree must be fresh ----------------------------------------------
# A reused tree is D1's *silent* failure mode: cmake finds the paths already present, logs
# Up-to-date, and leaves whatever was there -- including a whole /usr/local install tree left by a
# scripts/build.sh run -- so the packages ship a runtime that dies in mount("overlay"). A non-empty
# root is therefore refused, not merged, and the removal is opt-in and guarded: no blind `rm -rf`
# (a wrong DARLING_PKG_DIST would otherwise delete a checkout).
if [ -e "$pkg_root" ]; then
	[ -d "$pkg_root" ] || fatal "$pkg_root exists and is not a directory"
	if [ -n "$(ls -A -- "$pkg_root" 2>/dev/null || true)" ]; then
		[ "${DARLING_PKG_CLEAN_ROOT:-0}" = 1 ] || fatal \
"$pkg_root is not empty. Refusing to install over it: cmake would report Up-to-date and leave a
  stale tree in place (D1's silent failure). Remove it yourself, or re-run with
  DARLING_PKG_CLEAN_ROOT=1 to have this script remove it."
		case "$pkg_root" in
			*/dist/pkg/root) : ;;
			*) fatal "refusing to remove $pkg_root: it is not a .../dist/pkg/root staging path" ;;
		esac
		note "DARLING_PKG_CLEAN_ROOT=1: removing the previous staging tree $pkg_root"
		rm -rf -- "$pkg_root"
	fi
fi
mkdir -p -- "$pkg_root" "$dist"

# --- 4. Pinned sources + patches (identical to scripts/build.sh) -------------------------------
python3 scripts/configure.py
if [ -d "$repo/build/venv/bin" ]; then PATH="$repo/build/venv/bin:$PATH"; export PATH; fi
python3 scripts/prepare.py

# --- 5. Configure + build ----------------------------------------------------------------------
# Empty build type, as upstream Darling uses: objc4 always defines OBJC_IS_DEBUG_BUILD=1, so
# Release's -DNDEBUG trips its "mismatch in debug-ness macros" #error. x86-64 only: the patched
# OpenDirectory declares ivars in @implementation, which the 32-bit (fragile ABI) slice cannot
# compile, and the macOS client is 64-bit.
# The four packaging flags are "$@" -- the single source defined in step 2. Nothing is repeated.
cmake -S "$src_tree" -B "$build_tree" -G 'Unix Makefiles' \
	-DCMAKE_BUILD_TYPE= -DTARGET_i386=OFF -DENABLE_METAL=ON "$@"
cmake --build "$build_tree" --parallel "${JOBS:-$(nproc)}"

# --- 6. Install into the staging tree, never into / --------------------------------------------
# DESTDIR staging is what makes `dh_fixperms -X` / `%attr` / `.PKGINFO` mode control possible at
# all, and it is what upstream's debian/rules:57-62 and rpm/darling.spec:270-275 do. `sudo -E` is
# required by the install rules that need root to set the setuid bit on usr/bin/darling.
note "installing into $pkg_root (log: $install_log)"
install_rc=0
if [ "$have_pipefail" = 1 ]; then
	DESTDIR="$pkg_root" sudo -E cmake --install "$build_tree" 2>&1 \
		| sudo -E tee "$install_log" > /dev/null || install_rc=$?
else
	# Without `pipefail` a pipeline would report tee's status, so the log is written directly and
	# echoed afterwards: same file, same content, and cmake's own status is never masked.
	set +e
	# shellcheck disable=SC2024  # on purpose: the log is the *invoking* user's file, opened
	# before sudo runs, and the branching exists only because dash cannot report cmake's status
	# through a `| sudo tee`.
	DESTDIR="$pkg_root" sudo -E cmake --install "$build_tree" > "$install_log" 2>&1
	install_rc=$?
	set -e
	cat -- "$install_log"
fi
[ "$install_rc" -eq 0 ] || fatal "cmake --install exited $install_rc (log: $install_log)"

# --- 7. G-PKG-2: assert the log describes a fresh /usr staging tree -----------------------------
# 🚨 The literal acceptance text ("the log contains 0 occurrences of Up-to-date and 0 of
# /usr/local") cannot be implemented as written: BOTH strings appear in the log of a build that is
# exactly right, measured twice --
#   * /usr/local: the guest's own prefix is part of the payload (`install(DIRECTORY DESTINATION
#     libexec/darling/usr/local)`, pinned upstream CMakeLists.txt:223-224), and the published
#     v0.1.0 install.log carries both of those lines. What must be zero is the HOST prefix.
#   * Up-to-date: cmake creates a parent directory implicitly while installing a deeper file and
#     then logs Up-to-date when an explicit install(DIRECTORY DESTINATION) asks for that same
#     path (reproduced against cmake 3.25 on a fresh DESTDIR), and upstream installs the same
#     target twice in one run (darling-file_cmds:66 lists gzip, :85 installs gzip again). The
#     published v0.1.0 install.log has 52 Up-to-date lines on a tree built exactly right, 23 of
#     them directories with no matching `Installing` line. Both numbers were measured, not
#     inferred: the first reproduced against cmake 3.25 on a fresh DESTDIR, the second read off
#     the published log.
# A gate that fails the build it exists to protect is the defect class C23 warns about, so this
# function asserts the invariants the literal text was after. Every one of them is false for the
# published /usr/local artefact we must not ship:
#   (1) every path the log names must live inside the staging tree: a PREFIX test, not a substring
#       one. A path outside it means cmake installed somewhere else -- a reused /usr/local tree is
#       exactly that shape.
#   (2) no named path may sit at the host prefix, i.e. start with "$pkg_root/usr/local/". The
#       guest's payload lives at "$pkg_root/usr/libexec/darling/usr/local", never there, so this is
#       an exact prefix test and needs no mask; a CMAKE_INSTALL_PREFIX=/usr/local build, or a stale
#       such tree, always has a path under it.
#   (3) an Up-to-date line the LOG cannot explain means the tree was not fresh. The log explains it
#       two ways and only two: the same path was also installed by a duplicate rule, or some path
#       installed in this run lies deeper under it (the implicit-parent cause). Whether the path
#       exists on this host is not evidence. With step 3 refusing a non-empty root this can only
#       fire on a real regression.
# 🚨 R6: darling-file_cmds:70-71 installs `install-bin` and then renames it to `install` with an
# install(CODE) block whose WORKING_DIRECTORY is `${CMAKE_INSTALL_PREFIX}/libexec/darling/usr/bin`
# -- DESTDIR is ignored by that code path, so with prefix /usr it renames into the *host* /usr (a
# runner has no such directory; the `mv` fails, cmake ignores the status, and the staging tree
# keeps install-bin and never gets install -- which is the whole of C17's "1 missing" entry, and
# not a COMPONENTS question: INSTALL-BIN IS IN THE STOCK BUILD, as the published log line 7692
# `-- Installing: /usr/local/libexec/darling/usr/bin/install-bin` proves. Nothing is synthesised
# here (C17); the rename belongs to the packaging step that owns the staging tree. Answer for
# packaging/README.md is handed to T12.
check_install_log() {
	log=$1
	[ -s "$log" ] || fatal "$log is empty or missing: nothing was installed"
	claims=$(grep -aE '^-- (Installing|Up-to-date): ' "$log" | sed -E 's/^-- (Installing|Up-to-date): //' || true)
	[ -n "$claims" ] || fatal "$log has no '-- Installing:' lines: the install did not run"

	# (1) everything cmake names must be inside the staging tree. A PREFIX test, not a substring
	# one: `grep -vF -e "$pkg_root/"` matches the root string anywhere in the line, so a claim
	# outside the tree that merely *contains* it (/opt$pkg_root/usr/bin/darling) passed. `index()`
	# is literal, so a $pkg_root carrying regex metacharacters (`.`, `+`, `[`) needs no escaping.
	stray=$(printf '%s\n' "$claims" | PKG_ROOT_SLASH="$pkg_root/" awk 'index($0, ENVIRON["PKG_ROOT_SLASH"]) != 1' || true)
	if [ -n "$stray" ]; then
		echo "build-packaging: FATAL the install log names paths outside $pkg_root:" >&2
		printf '%s\n' "$stray" | head -10 >&2
		fatal "DESTDIR staging failed: cmake installed outside the staging tree"
	fi

	# (2) no host-prefix /usr/local path in the tree. A literal PREFIX test too, and it needs no
	# mask: the guest skeleton is payload at "$pkg_root/usr/libexec/darling/usr/local", never at
	# "$pkg_root/usr/local". The old `sed 's#.*/libexec/darling/usr/local#...#'` was greedy and
	# unanchored -- it stripped everything up to the LAST match -- so a genuine /usr/local path
	# that also contained the guest substring ($pkg_root/usr/local/x/libexec/darling/usr/local/y)
	# was masked out of the sweep.
	residue=$(printf '%s\n' "$claims" | PKG_LOCAL_SLASH="$pkg_root/usr/local/" awk 'index($0, ENVIRON["PKG_LOCAL_SLASH"]) == 1' || true)
	if [ -n "$residue" ]; then
		echo "build-packaging: FATAL the install log names host /usr/local paths:" >&2
		printf '%s\n' "$residue" | head -10 >&2
		fatal "this is not a /usr staging tree: a stale /usr/local tree was reused, or the prefix was not /usr"
	fi

	# (3) Up-to-date: report the shape, and fail unless the LOG explains the line.
	tmp=$(mktemp -d)
	trap 'rm -rf -- "$tmp"' EXIT INT TERM HUP
	# `|| true`: an empty match set is not an error, and with `pipefail` on (bash) grep's status
	# would otherwise abort a correct build.
	grep -a '^-- Up-to-date: ' "$log" | sed 's/^-- Up-to-date: //' | LC_ALL=C sort -u > "$tmp/up_to_date" || true
	grep -a '^-- Installing: ' "$log" | sed 's/^-- Installing: //' | LC_ALL=C sort -u > "$tmp/installed" || true
	LC_ALL=C comm -12 "$tmp/up_to_date" "$tmp/installed" > "$tmp/explained"
	LC_ALL=C comm -23 "$tmp/up_to_date" "$tmp/installed" > "$tmp/unexplained"
	# An unexplained path is an implicit parent only when the log itself installs something deeper
	# under it. The previous form asked `[ -d "$p" ]` -- i.e. THIS host's filesystem -- so the same
	# log scored rc=0 or rc=1 depending on whether a path happened to exist, and a log replayed
	# against another tree misreported the cause. Consequence, deliberate: a stale DIRECTORY that
	# this run then installs into is still exempt (it is genuinely undetectable from the log
	# alone); a stale directory nothing was installed under is not. `FILENAME`, not `NR == FNR`:
	# with an empty $tmp/installed every line of the second file would take the first branch.
	INSTALLED_LOG="$tmp/installed" awk '
		FILENAME == ENVIRON["INSTALLED_LOG"] {
			# every ancestor of an installed path, literal ("/a/b/c" adds "/a" and "/a/b");
			# split() keeps the leading empty field of an absolute path, so f[1] is "".
			n = split($0, f, "/"); acc = f[1]
			for (j = 2; j < n; j++) { acc = acc "/" f[j]; parents[acc] = 1 }
			next
		}
		!( $0 in parents )
	' "$tmp/installed" "$tmp/unexplained" > "$tmp/unexplained_files"
	if [ -s "$tmp/unexplained_files" ]; then
		echo "build-packaging: FATAL the install log reports Up-to-date for paths this run never installed:" >&2
		head -10 "$tmp/unexplained_files" >&2
		fatal "the staging tree was not fresh: cmake reused paths that were already there"
	fi
	note "install log: $(wc -l < "$tmp/installed") paths installed, $(wc -l < "$tmp/up_to_date") Up-to-date ($(wc -l < "$tmp/explained") of them covered by a duplicate install rule, $(wc -l < "$tmp/unexplained") implicit parent directories)"
}

check_install_log "$install_log"
[ -e "$pkg_root/usr/bin/darling" ] || fatal "$pkg_root/usr/bin/darling is missing: the install log and the tree disagree"

# --- 8. Provenance: BUILD-INFO-packages.txt says what this artefact was built with --------------
# PLAN 12.3: extend the existing 9-key schema, never invent a parallel one. packaging/common/
# build-info.sh owns the schema (T1) and reads the run-scoped values from the environment, so the
# flags keep their single source. The packaging step (T6) re-runs the same generator over the
# staged tree to add the counts; this call is the build-scoped half and runs even for a build that
# never reaches staging.
COMPONENTS="$pkg_components" \
PKG_PREFIX="$pkg_prefix" \
CMAKE_INSTALL_LIBDIR="$pkg_libdir" \
CMAKE_INSTALL_PREFIX="$pkg_prefix" \
	sh "$repo/packaging/common/build-info.sh" "$build_info"
printf 'cmake-flags: %s\n' "$pkg_cmake_flags" >> "$build_info"
note "wrote $build_info"
note "done: staging tree $pkg_root"