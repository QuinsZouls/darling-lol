#!/usr/bin/env bash
# packaging/testdata/run-deb-gates.sh -- the T3 (`.deb`) gate battery: self-contained, hermetic,
# asserting (TASKS.md T3's gate block: G-DEB-1 dpkg-deb -c, G-DEB-2 dpkg-deb -f, G-DEB-3 no
# conffiles, G-DEB-4 lintian --fail-on error).
#
# Run from the repo root:
#
#     bash packaging/testdata/run-deb-gates.sh
#     T3_GATES_DOCKER=1 bash packaging/testdata/run-deb-gates.sh     # + G-DEB-4 (lintian)
#
# Everything it needs it creates itself, inside one private `mktemp -d` workdir, and it reads
# nothing the harness did not write: the hostile-shape tree comes from packaging/testdata/
# mkfixture.sh (the same call build-deb.sh fixture makes), the upstream copyright it inlines is
# written by the harness, and the two .deb files are built into $WORK/dist (DIST=$WORK/dist) -- the
# repo's own dist/ is never touched, and the last row proves it (`git status --porcelain` before
# and after). The artifacts it inspects are exactly TASKS.md T3's: $DIST/fix.deb and
# $DIST/fix-launcher.deb.
#
# G-DEB-4 additionally runs lintian, which is not packaged for this box's distro here, so it runs
# in a container -- the image TASKS.md's gate block assumes:
#
#     T3_GATES_DOCKER=1 bash packaging/testdata/run-deb-gates.sh
#     T3_GATES_DOCKER=1 T3_LINTIAN_IMAGE=darling-lol-lintian:24.04 bash packaging/testdata/...
#
# Without T3_GATES_DOCKER=1 the row is SKIPped, loudly, and counted in the summary: SKIP is not
# PASS, and G-DEB-4 is the row the `copyright`/`conffiles` mutations turn red -- one of them inside
# the container (the control at the bottom re-runs this file with T3_GATES_BREAK=no-copyright and
# asserts the child's own "0 E: lines" row fails). The image is overridable only so that repeated
# runs do not re-install lintian (~280 packages, ~25 minutes on this box); the DEFAULT is the
# literal ubuntu:24.04 of the gate block. A default run of this battery is entirely offline:
# G-DEB-4 is the only row that touches the network, and only when T3_GATES_DOCKER=1 is set.
#
# G-DEB-4 also refuses to run on an override file that names a tag the container's lintian does not
# know: an unknown name is "E: alien-tag", i.e. the override file fails the very gate it exists to
# satisfy. That is not hypothetical -- PLAN 9.6's list carries five such names (report finding F9).
#
# This file is POSIX enough that `sh -n run-deb-gates.sh` accepts it, but it is a bash battery
# like its siblings: `sh run-deb-gates.sh` (= dash here) refuses at the first line, before any row
# runs. That refusal is the whole point (T1 review INFO-3: a runner that dies *mid-table* leaves a
# partial table that reads as "mostly green"), so the guard is the first executable statement and
# it parses under dash.
case "${BASH_VERSION:-}" in
  "") echo "run-deb-gates: run me with bash: bash $0" >&2; exit 2 ;;
esac
set -u

if [ ! -f packaging/common/build-deb.sh ] || [ ! -d packaging/testdata ]; then
  echo "run-deb-gates: run me from the repo root (no packaging/ in $PWD)" >&2
  exit 2
fi

# T3_GATES_BREAK=<name> breaks the OBJECT under test on purpose -- a copy of the builder, of
# mk-copyright.sh, of the two override files and of the control templates -- so the negative control
# at the bottom can prove the swept rows really go red (TASKS preamble rule 7). Unset in a normal
# run, and never inherited into the control's child run (the control skips itself when it is set).
#   no-root-owner-group  drop the flag from both dpkg-deb calls      -> the ownership rows
#   no-copyright         drop the runtime copyright install          -> the copyright row (+G-DEB-4)
#   conffiles            register resolv.conf in DEBIAN/conffiles    -> the G-DEB-3 rows (+G-DEB-4)
#   override-tag         delete the elevated-privileges line         -> the override row
#   games-section        put Section: contrib/games back (F10)       -> the Section row (+G-DEB-4)
#   essential-depends    put `bash, coreutils` back in the launcher  -> the Essential-package row
#                        (F11); lintian's own E: depends-on-essential-... comes back too, so this
#                        one can also be asserted inside the container
#   no-trailing-newline  strip the last byte of packaging/deb/prerm  -> the newline hygiene row
#                        (F6: T1's "every file ends with a newline" row globs packaging/common/ and
#                        packaging/testdata/ only, so packaging/deb/ is invisible to it)
#   binary-version       leave ${binary:Version} unsubstituted       -> the build row (render.sh
#                        and build-deb.sh both refuse it, which is the point)
#   launcher-zstd        build ONLY the launcher's data member -Zzstd -> the two "data member is xz"
#                        rows (MENOR-2: the mutation the row could not catch -- `|| echo 0` corrupted
#                        the accumulator so the row PASSed while a zstd member was present)
#   maintainer-wrapped   put PLAN 9.1 (rev 7)'s wrapped Maintainer: back in control.in -> the
#                        exact-Maintainer row (MENOR-1/C43-g: with a real contact the value nests),
#                        and E: malformed-contact in the container
#   maintainer-addressless  drop the address from build-deb.sh's OWN default -> the "the builder's
#                        default carries an address" guard (MENOR-4/C43-g: render.sh's shared default
#                        is still addressless, so the deb path must never rely on it)
#   override-error-tag   delete an ERROR-severity override line (binary-from-other-architecture)
#                        -> G-DEB-4 INSIDE the container (MENOR-3). An offline run cannot see it,
#                        which is exactly the gap MENOR-3 names, so the control lives below with the
#                        other container controls.
#   flat-fatal           restore run 39258643917's bug IN THE GENERATOR: the real, flat upstream
#                        debian/copyright (no Format: header, no stanzas -- the shape the pin
#                        actually ships) FATALs again -> the flat-shape builder row
#   flat-unindented      the naive fix: copy the flat upstream notices byte-for-byte at column 0
#                        instead of as Comment continuations -> the shipped-flat structure row
#                        (lintian does NOT parse the shipped doc copyright -- measured -- so this
#                        is discharged offline, not in the container)
BREAK=${T3_GATES_BREAK:-}
KEEP=${T3_KEEP:-0}
# T3_LINTIAN_FAILON=<level>  the container's `lintian --fail-on <level>` (default: error, the
#   brief's level). Control-only: the fail-on control in the section below sets it to `warning` to
#   prove that a lintian failure which prints no E: line still reddens the two rc rows -- which is
#   only true because the container now exits with lintian's own status instead of the last echo's.
#   T3_NO_CONTROL=1 tells that child to skip the control section: it has no T3_GATES_BREAK label
#   because nothing of the OBJECT changes there -- the measurement does.
FAILON_LEVEL=${T3_LINTIAN_FAILON:-error}
NO_CONTROL=${T3_NO_CONTROL:-}
# T3_GATES_REQUIRE_DOCKER=1 turns "G-DEB-4 was SKIPped" into a FAILURE (NIT-5): a CI wiring that
# runs this battery without T3_GATES_DOCKER=1 must not come back green with the package's only
# policy gate never executed. Off by default, because a bare offline run cannot run lintian.
REQUIRE_DOCKER=${T3_GATES_REQUIRE_DOCKER:-0}

WORK=$(mktemp -d "${TMPDIR:-/tmp}/darling-t3-deb-gates.XXXXXX")
if [ "$KEEP" = 1 ]; then
  echo "run-deb-gates: T3_KEEP=1, keeping $WORK"
else
  trap 'rm -rf "$WORK"' EXIT HUP INT TERM
fi

pass=0; fail=0; skips=0
# dockerskip: set when the G-DEB-4 ROW is skipped, so T3_GATES_REQUIRE_DOCKER=1 can refuse a green
# battery in which the package's only policy gate never ran (NIT-5).
dockerskip=0
ok()   { pass=$((pass+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
no()   { fail=$((fail+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
chk()  { if [ -z "${2:-}" ]; then no "$1: EMPTY result (command failed)"; elif [ "$2" = "$3" ]; then ok "$1 ($2)"; else no "$1: got '$2', want '$3'"; fi; }
skip() { skips=$((skips+1)); printf '  \033[33mSKIP\033[0m %s\n' "$1"; }
sec()  { printf '\n\033[1m%s\033[0m\n' "$1"; }
note() { printf '    %s\n' "$1"; }

# cnt PATTERN FILE -> always a number (grep -c prints 0 and exits 1 when nothing matches)
cnt()  { grep -c -- "$1" "$2" 2>/dev/null || true; }
cntn() { grep -c -e "$1" -e "$2" "$3" 2>/dev/null || true; }
# allof FILE TOKEN... -> how many of the tokens the file contains (compare against $#, which is
# also what makes the row fail loudly instead of counting prose occurrences).
allof() { _f=$1; shift; _n=0; for _t in "$@"; do grep -qF -- "$_t" "$_f" && _n=$((_n+1)); done; printf '%s' "$_n"; }

DIST=$WORK/dist
TAG=v0.1.0
VERSION=0.1.0+lol-1
UPSTREAM=$WORK/upstream-copyright

# The synthetic upstream debian/copyright. Written BY the harness. Its Files:/License: stanzas
# carry a path and a short name that appear nowhere else in the tree, so the rows below can prove
# the SHIPPED copyright was generated from this input instead of typed into the payload.
cat > "$UPSTREAM" <<'EOF'
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: darling
Upstream-Contact: https://www.darlinghq.org/
Source: https://github.com/darlinghq/darling

Files: src/harness-marker-only
Copyright: 2026 The T3 gate harness
License: T3-Harness-Marker-1.0

Files: src/frameworks/*
Copyright: 2008-2026 Apple Inc. and the Darling contributors
License: APSL-2.0
EOF

# The OTHER shape: what the pin ACTUALLY ships. This harness used to describe the real
# build/darling-src/debian/copyright as a "~33k" DEP-5 document -- fiction, measured by runs
# 39245729525/39258643917: at 60ba801d it is a flat three-line notice, no Format: header, no
# blank-line-separated stanzas, and the generator that only understood the shape above died on
# it inside build-all's fail-fast, taking rpm and tar with it. A fixture whose shape differs
# from production is how that class survives a green battery; UPSTREAM_FLAT is the same bytes
# the CI checkout feeds the builder.
UPSTREAM_FLAT=$WORK/upstream-copyright-flat
cat > "$UPSTREAM_FLAT" <<'EOF'
Copyright (C) 2012-2023 Darling developers
Copyright (C) 1999-2017 Apple, Inc.
Copyright (C) 1989-2005 Free Software Foundation, Inc.

EOF

# --- the object under test ----------------------------------------------------------------------
if [ -n "$BREAK" ]; then
  MUT=$WORK/mut
  mkdir -p "$MUT"
  cp -a packaging "$MUT/packaging"
  mkdir -p "$MUT/upstream"
  cp upstream/manifest.json "$MUT/upstream/manifest.json"
  B=$MUT/packaging/common/build-deb.sh
  case $BREAK in
    no-root-owner-group)
      sed -i 's/--build --root-owner-group -Zxz/--build -Zxz/g' "$B" ;;
    no-copyright)
      sed -i '/usr\/share\/doc\/darling-lol\/copyright"/d' "$B" ;;
    conffiles)
      # Register a private/etc data file as a conffile (C5) and neuter the guard that refuses it,
      # in one edit: the guard IS the object, and a mutation that could not get past it would prove
      # nothing. PLAN 9.3/TASKS name private/etc/resolv.conf; the FIXTURE payload has no such file
      # (mkfixture.sh ships paths/manpaths/machine-id), and dpkg-deb itself refuses a conffile that
      # "does not appear in package" -- so the mutation registers the fixture's private/etc/paths.
      # The class under test is identical: a non-/etc data file declared a conffile.
      sed -i 's|^if \[ -e "\$work/DEBIAN/conffiles"|printf "%s\\n" /usr/libexec/darling/private/etc/paths > "$work/DEBIAN/conffiles"\nif false|' "$B" ;;
    override-tag)
      sed -i '/^elevated-privileges /d' "$MUT/packaging/deb/darling-lol.lintian-overrides" ;;
    games-section)
      # F10: PLAN 9.1's Section, put back -- lintian answers it with
      # "E: package-section-games-but-contains-no-game" because neither package ships /usr/games.
      sed -i 's|^Section: contrib/otherosfs$|Section: contrib/games|' "$MUT/packaging/deb/control.in" ;;
    essential-depends)
      # F11: PLAN 9.2's dependency list, put back -- lintian answers it with
      # "E: depends-on-essential-package-without-using-version Depends: bash" (and coreutils).
      sed -i 's|^Depends: darling-lol (= ${binary:Version}), python3 (>= 3.8)$|Depends: darling-lol (= ${binary:Version}), python3 (>= 3.8), bash, coreutils|' \
        "$MUT/packaging/deb/launcher-control.in" ;;
    no-trailing-newline)
      # Strip prerm's last byte -- the exact defect T1's hygiene row was written for, and the one it
      # cannot see here (it globs packaging/common/ and packaging/testdata/ only). Two files of this
      # task shipped without a trailing newline and T1 caught exactly those two, which is why
      # packaging/deb/ needs a row of its own.
      printf '%s' "$(cat "$MUT/packaging/deb/prerm")" > "$MUT/packaging/deb/prerm" ;;
    binary-version)
      # render.sh's awk program is single-quoted: a replacement that is not valid awk would fail at
      # parse time and the failure would NOT name ${binary:Version}. Replace the substitution with a
      # valid awk no-op instead, so the guard that is supposed to catch it is the thing that fires.
      sed -i 's/^    line = lit(line, "\${binary:Version}", tok\["@VERSION@"\])$/    line = line # T3_GATES_BREAK/' \
        "$MUT/packaging/common/render.sh" ;;
    launcher-zstd)
      # MENOR-2: build ONLY the launcher's data member with zstd, so the runtime row stays green and
      # the launcher row (and the swept "no zstd member in EITHER" row) must go red -- this is the
      # mutation that used to PASS because `|| echo 0` made the accumulator a syntax error.
      sed -i 's|--build --root-owner-group -Zxz "$lwork"|--build --root-owner-group -Zzstd "$lwork"|' "$B" ;;
    maintainer-wrapped)
      # MENOR-1/C43-g: PLAN 9.1 rev 7 wrapped the token; once --maintainer carries a real contact it
      # nests (`... <darling-lol maintainers <addr>>`). Only the exact-value row sees it offline;
      # lintian answers it with E: malformed-contact.
      sed -i 's|^Maintainer: @MAINTAINER@$|Maintainer: darling-lol maintainers <@MAINTAINER@>|' \
        "$MUT/packaging/deb/control.in" ;;
    maintainer-addressless)
      # MENOR-4/C43-g: put the builder's own default back to the addressless shape render.sh:27
      # still ships. The deb path is supposed to be discharged by passing its own address-bearing
      # contact, so the guard row -- not lintian -- is what goes red.
      sed -i 's|:-darling-lol maintainers <darling-lol@users.noreply.github.com>}|:-darling-lol maintainers}|' "$B" ;;
    override-error-tag)
      # MENOR-3: delete an ERROR-severity override line. F14 measured that only such a tag is
      # load-bearing for `lintian --fail-on error`; the older `override-tag` label deletes a
      # *warning* tag, so it proves the in-tree TEXT row, not the gate.
      sed -i '/^binary-from-other-architecture /d' "$MUT/packaging/deb/darling-lol.lintian-overrides" ;;
    flat-fatal)
      # run 39258643917's bug, restored: send the generator's verbatim branch into emit_header's
      # unknown-mode refusal, i.e. make the REAL flat shape FATAL again. The flat builder row is
      # what must redden -- production feeds build-deb.sh exactly this shape.
      sed -i 's/^      emit_header verbatim$/      emit_header nosuchmode/' \
        "$MUT/packaging/deb/mk-copyright.sh" ;;
    flat-unindented)
      # the naive fix: copy the flat notices byte-for-byte at column 0. That opens a malformed
      # DEP-5 paragraph -- and lintian does NOT parse the shipped doc copyright (measured with
      # the container's 2.122: neither shape earns an E:), so the structural row is what must
      # see it, offline.
      sed -i 's/printf " %s\\n", line\[i\]/printf "%s\\n", line[i]/' \
        "$MUT/packaging/deb/mk-copyright.sh" ;;
    *) echo "run-deb-gates: unknown T3_GATES_BREAK='$BREAK'" >&2; exit 2 ;;
  esac
  BUILDER=$B
  # prove the mutation is real: a sed that silently matched nothing would leave the object
  # untouched and make the whole negative control vacuous.
  case $BREAK in
    no-root-owner-group | no-copyright | conffiles | maintainer-addressless) cmp -s "$B" packaging/common/build-deb.sh ;;
    launcher-zstd) cmp -s "$B" packaging/common/build-deb.sh ;;
    override-tag | override-error-tag) cmp -s "$MUT/packaging/deb/darling-lol.lintian-overrides" packaging/deb/darling-lol.lintian-overrides ;;
    games-section | maintainer-wrapped) cmp -s "$MUT/packaging/deb/control.in" packaging/deb/control.in ;;
    essential-depends) cmp -s "$MUT/packaging/deb/launcher-control.in" packaging/deb/launcher-control.in ;;
    no-trailing-newline) cmp -s "$MUT/packaging/deb/prerm" packaging/deb/prerm ;;
    binary-version) cmp -s "$MUT/packaging/common/render.sh" packaging/common/render.sh ;;
    flat-fatal | flat-unindented) cmp -s "$MUT/packaging/deb/mk-copyright.sh" packaging/deb/mk-copyright.sh ;;
  esac && { echo "run-deb-gates: T3_GATES_BREAK=$BREAK changed nothing -- refusing (the sed matched nothing)" >&2; exit 2; }
else
  BUILDER=packaging/common/build-deb.sh
fi

# The tree under test: the mutated copy when T3_GATES_BREAK is set, the repo otherwise. Source-
# hygiene rows read THIS, never the repo directly -- otherwise their negative control could not
# touch what they read and the control would be vacuous.
SRC=${BREAK:+$MUT/}packaging

GIT_BEFORE=$(git status --porcelain 2>/dev/null | LC_ALL=C sort)

# --- build --------------------------------------------------------------------------------------
sec "the object: build-deb.sh fixture, over mkfixture.sh's hostile tree"
# TAG and DEB_FAMILY are exported on purpose: the builder must never fall back to `git describe`
# over whatever checkout is current (TASKS preamble rule 7 / C35). Everything else is the
# builder's own default, so the row below also proves the defaults are sane.
rc=0
export DIST UPSTREAM_COPYRIGHT=$UPSTREAM FIXTURE_DIR=$DIST/fixture DEB_FAMILY=noble TAG
sh "$BUILDER" fixture > "$WORK/build.log" 2>&1 || rc=$?
sed 's/^/    /' "$WORK/build.log"
chk "the builder exits 0 (fixture mode)" "$rc" 0

RT=$DIST/fix.deb
LT=$DIST/fix-launcher.deb
chk "both artifacts exist and are non-empty" "$([ -s "$RT" ] && [ -s "$LT" ] && echo 2 || echo 0)" 2
chk "the builder names both artifacts" "$(cnt '^build-deb\.sh: built ' "$WORK/build.log")" 2
chk "the builder reports no FATAL" "$(cnt 'FATAL' "$WORK/build.log")" 0

dpkg-deb -c "$RT" > "$WORK/rt.list" 2>&1 || true
dpkg-deb -c "$LT" > "$WORK/lt.list" 2>&1 || true
dpkg-deb -f "$RT" > "$WORK/rt.ctl" 2>&1 || true
dpkg-deb -f "$LT" > "$WORK/lt.ctl" 2>&1 || true
dpkg-deb -e "$RT" "$WORK/rt.ctl.d" || true
dpkg-deb -e "$LT" "$WORK/lt.ctl.d" || true
dpkg-deb -x "$RT" "$WORK/rt.x" || true
dpkg-deb -x "$LT" "$WORK/lt.x" || true
chk "both data archives extract (dpkg-deb -x)" "$([ -d "$WORK/rt.x/usr/libexec/darling" ] && [ -d "$WORK/lt.x/usr/lib/darling-lol" ] && echo 2 || echo 0)" 2
# NIT-1 (removed): the row that used to live here, `the payload carries no DEBIAN/ directory`,
# counted ` \./DEBIAN` in `dpkg-deb -c`'s output. That listing is the DATA archive only, and a
# top-level `./DEBIAN` in a payload *is* the control directory by definition, so the pattern could
# never match: the row was unfalsifiable (no build, including one with a nested `usr/DEBIAN`, could
# redden it). The invariant it pretended to assert -- "the control files are not in the payload" --
# is genuinely asserted by the G-DEB-3 rows below (`dpkg-deb -e` extracts exactly
# `control postinst postrm prerm`, and the launcher's control archive is `control` alone). The
# review's guidance is explicit: a row that cannot fail is worse than no row.

# --- G-DEB-1 ------------------------------------------------------------------------------------
sec "G-DEB-1  dpkg-deb -c: the nine hostile shapes survive verbatim"
HOSTILE='usr/bin/darling
usr/libexec/darling/usr/bin/write
usr/libexec/darling/System/Library/User Template
usr/libexec/darling/System/Library/CoreServices/Menu Extras/%21.menu
usr/libexec/darling/usr/share/ipv6only%7c-i.ri
usr/libexec/darling/usr/share/eql%3f-i.ri
usr/libexec/darling/usr/share/%3d%3d%3d-i.ri
usr/libexec/darling/private/etc/machine-id
usr/libexec/darling/private/tmp'
n=0
while IFS= read -r p; do
  [ -n "$p" ] || continue
  grep -qF -- "$p" "$WORK/rt.list" && n=$((n+1))
done <<EOF
$HOSTILE
EOF
chk "all nine hostile shapes are in the archive, under the SAME names" "$n" 9
chk "the four distinct %-escapes survived (%21 %7c %3f %3d)" "$(grep -cE '%(21|7c|3f|3d)' "$WORK/rt.list" || true)" 4
chk "no escape was DECODED on the way in" "$(grep -cE '!\.menu|ipv6only\|-i\.ri|eql\?-i\.ri|===-i\.ri' "$WORK/rt.list" || true)" 0
chk "no escape was double-encoded (%25)" "$(cnt '%25' "$WORK/rt.list")" 0
chk "spaces survived, in a file name and in a directory name" "$(cntn 'Menu Extras/%21.menu' 'User Template/' "$WORK/rt.list")" 2
chk "the dangling symlink ships AS a symlink, with its guest target" \
  "$(grep -cE '^lrwxrwxrwx root/root .*machine-id -> /Volumes/SystemRoot/etc/machine-id$' "$WORK/rt.list" || true)" 1
chk "the empty directory ships as a directory entry" \
  "$(grep -cE '^d.* \./usr/libexec/darling/private/tmp/$' "$WORK/rt.list" || true)" 1

sec "G-DEB-1  the build is the T3 command, and nothing else (PLAN 9 preamble, 22)"
nodb=0
for f in packaging/common/build-deb.sh packaging/deb/mk-copyright.sh packaging/deb/postinst \
         packaging/deb/postrm packaging/deb/prerm packaging/deb/control.in \
         packaging/deb/launcher-control.in packaging/deb/changelog.in; do
  c=$(grep -v '^[[:space:]]*#' "$f" | grep -cE '\bdh_[a-z_]+|debhelper|dpkg-gencontrol|debian/rules' || true)
  [ "$c" = 0 ] || nodb=$((nodb+1))
done
chk "no dh_*/debhelper/dpkg-gencontrol in the new files' CODE (prose is allowed)" "$nodb" 0
grep -v '^[[:space:]]*#' "$BUILDER" > "$WORK/builder.code"
chk "the builder's two calls are dpkg-deb --build --root-owner-group -Zxz" \
  "$(cnt '^dpkg-deb --build --root-owner-group -Zxz ' "$WORK/builder.code")" 2
chk "the runtime's data member is xz (C13: zstd is unreadable on dpkg < 1.21.18)" \
  "$(grep -ac 'data\.tar\.xz' "$RT" || true)" 1
chk "the launcher's data member is xz" "$(grep -ac 'data\.tar\.xz' "$LT" || true)" 1
zst=0
for f in "$RT" "$LT"; do
  # MENOR-2: `|| true`, NOT `|| echo 0`. `grep -c` prints `0` and *exits 1* when the file exists
  # with no match (it prints nothing only when the FILE is missing), so `|| echo 0` appended a
  # second line and the operand became `"0\n0"` -- a bash arithmetic syntax error on every run,
  # which silently pinned $zst to 0 and left this row blind to a zstd member. `|| true` keeps the
  # printed `0` and swallows the status. (Measured before the fix: `line N: zst + 0\n0: syntax
  # error in expression`; and a launcher-only `-Zzstd` build PASSed this row while carrying the
  # member -- now `T3_GATES_BREAK=launcher-zstd` turns it red, see the control section.)
  zst=$((zst + $(grep -ac 'data\.tar\.zst' "$f" || true)))
done
chk "no zstd data member in either package" "$zst" 0

sec "G-DEB-1  ownership, setuid/setgid (--root-owner-group, PLAN 13.1)"
chk "every entry is root/root" "$(awk '$2 != "root/root"' "$WORK/rt.list" | wc -l | tr -d ' ')" 0
chk "the launcher's entries are root/root too" "$(awk '$2 != "root/root"' "$WORK/lt.list" | wc -l | tr -d ' ')" 0
chk "usr/bin/darling is setuid 4755 root:root" \
  "$(grep -cE '^-rwsr-xr-x root/root .* \./usr/bin/darling$' "$WORK/rt.list" || true)" 1
chk "usr/bin/write kept its setgid bit (2755 root:root)" \
  "$(grep -cE '^-rwxr-sr-x root/root .* \./usr/libexec/darling/usr/bin/write$' "$WORK/rt.list" || true)" 1

sec "G-DEB-1  the payload is the staged bytes (C6: a published payload shipped a broken one)"
chk "usr/lib/binfmt.d/darling.conf is byte-identical to the staged file" \
  "$(cmp -s "$WORK/rt.x/usr/lib/binfmt.d/darling.conf" "$DIST/fixture/root/usr/lib/binfmt.d/darling.conf" \
     && echo identical || echo differs)" identical
chk "the launcher ships its template UNRENDERED (@GUEST_HOME@ intact)" \
  "$(cnt '@GUEST_HOME@' "$WORK/lt.x/usr/lib/darling-lol/tools/config.in")" 1
chk "the launcher's wrapper ships too" "$(cnt 'fixture launcher' "$WORK/lt.x/usr/bin/darling-lol")" 1

# --- G-DEB-2 ------------------------------------------------------------------------------------
sec "G-DEB-2  dpkg-deb -f: the metadata dpkg reads, render.sh wrote"
chk "runtime Version == pkg-version.sh --deb $TAG" "$(dpkg-deb -f "$RT" Version 2>/dev/null)" "$VERSION"
chk "launcher Version == the same" "$(dpkg-deb -f "$LT" Version 2>/dev/null)" "$VERSION"
cat "$WORK/rt.ctl" "$WORK/lt.ctl" > "$WORK/all.ctl"
chk "no @TOKEN@ in ANY control field (both packages)" "$(cnt '@[A-Za-z_]*@' "$WORK/all.ctl")" 0
# NIT-2 (removed): a `no unexpanded ${binary:Version}` row used to sit here. It was unfalsifiable
# through every code path -- render.sh:231 refuses a leftover ${binary:Version}, build-deb.sh's
# check_no_tokens re-checks the installed file, and dpkg-deb itself refuses to build a package whose
# *relationship* field still carries it ("epoch in version is empty") -- so the review measured that
# neutering all four upstream guards still could not make the row red. A row that cannot fail is
# worse than no row, and leaving it in would let the brief's "leave ${binary:Version} unsubstituted"
# mutation be *credited* to a row that never fires. The substitution is instead anchored where it is
# genuinely falsifiable: `the launcher pins the runtime to THIS version` (the rendered pin, a
# positive assertion on the substituted value) plus `the builder exits 0` (which the
# `binary-version` BREAK label does redden, and whose log names ${binary:Version}).
chk "Architecture: amd64 (the runtime is amd64-only)" "$(dpkg-deb -f "$RT" Architecture 2>/dev/null)" amd64
chk "Architecture: all (the launcher is text)" "$(dpkg-deb -f "$LT" Architecture 2>/dev/null)" all

# Depends: rendered for the noble family, token for token, against the source list
sed 's/#.*$//' packaging/common/deps.deb.noble | sed 's/[[:space:]]*$//' | grep -v '^$' \
  | LC_ALL=C sort > "$WORK/deps.want"
dpkg-deb -f "$RT" Depends | tr ',' '\n' | sed 's/^ *//; s/ *$//' | grep -v '^$' \
  | LC_ALL=C sort > "$WORK/deps.have"
chk "Depends == packaging/common/deps.deb.noble, token for token" \
  "$(cmp -s "$WORK/deps.want" "$WORK/deps.have" && echo identical || echo differs)" identical
chk "that list is not empty (31 tokens)" "$(wc -l < "$WORK/deps.want" | tr -d ' ')" 31
chk "the launcher pins the runtime to THIS version" \
  "$(dpkg-deb -f "$LT" Depends > "$WORK/lt.dep"; cnt "^darling-lol (= $VERSION), " "$WORK/lt.dep")" 1

sed 's/#.*$//' packaging/common/conflicts.txt | sed 's/[[:space:]]*$//' | grep -v '^$' \
  | LC_ALL=C sort > "$WORK/conf.want"
dpkg-deb -f "$RT" Conflicts | tr ',' '\n' | sed 's/^ *//; s/ *$//' | grep -v '^$' \
  | LC_ALL=C sort > "$WORK/conf.have"
chk "Conflicts == packaging/common/conflicts.txt" \
  "$(cmp -s "$WORK/conf.want" "$WORK/conf.have" && echo identical || echo differs)" identical
chk "Conflicts is not empty (21 names)" "$(wc -l < "$WORK/conf.want" | tr -d ' ')" 21
chk "Breaks and Replaces are present" \
  "$(fields=$(printf '%s\n' "$(dpkg-deb -f "$RT" Breaks)" "$(dpkg-deb -f "$RT" Replaces)" | grep -c .); printf '%s' "$fields")" 2

rtsize=$(dpkg-deb -f "$RT" Installed-Size)
ltsize=$(dpkg-deb -f "$LT" Installed-Size)
chk "Installed-Size: two positive integers" \
  "$(printf '%s\n' "$rtsize" "$ltsize" | grep -cE '^[1-9][0-9]*$' || true)" 2
chk "the runtime is the bigger package (the numbers are per package, not one number twice)" \
  "$([ "$rtsize" -gt "$ltsize" ] && echo yes || echo no)" yes
chk "Section/Priority/Homepage/Maintainer as the templates say (F10: otherosfs, not games)" \
  "$(n=0
     for want in 'Section: contrib/otherosfs' 'Priority: optional' \
                 'Homepage: https://github.com/QuinsZouls/darling-lol' \
                 'Maintainer: darling-lol maintainers <darling-lol@users.noreply.github.com>'; do
       grep -qxF "$want" "$WORK/rt.ctl" && n=$((n+1))
     done
     printf '%s' "$n")" 4
chk "neither package claims the games section while shipping no /usr/games entry (F10)" \
  "$(n=0; for c in "$WORK/rt.ctl" "$WORK/lt.ctl"; do grep -qE '^Section: ([a-z-]+/)?games$' "$c" && n=$((n+1)); done; printf '%s' "$n")" 0
chk "the launcher does not depend on an Essential package unversioned (F11: bash and coreutils are Essential: yes)" \
  "$(dpkg-deb -f "$LT" Depends | tr ',' '\n' | sed 's/^ *//; s/ *$//' | grep -cxE '(bash|coreutils|dpkg|dash|perl-base)' || true)" 0
irc=0; iout=$(dpkg-deb -I "$RT" 2>&1) || irc=$?
chk "dpkg-deb -I parses the control file" "$irc" 0
printf '%s\n' "$iout" > "$WORK/rt.I"
chk "dpkg-deb -I printed the fields (not an empty read)" "$(cnt '^ Package: darling-lol$' "$WORK/rt.I")" 1

# --- the @MAINTAINER@ seam (C43-g, MENOR-1/MENOR-4) ---------------------------------------------
sec "the @MAINTAINER@ seam (C43-g): the deb path always passes an address-bearing contact"
note "render.sh:27's shared default is still 'darling-lol maintainers' (no address) -- the T1-owned"
note "file the brief freezes for T3 (MENOR-4). The .deb path does not rely on it: build-deb.sh"
note "always passes its own contact, and its default carries an address. The four rows below are the"
note "guard that makes the reliance impossible, and both shipped Maintainer fields are checked too."
# The default must be a full `Name <addr>` phrase, not a bare address: lintian rejects a bare
# address with `E: no-phrase` (and the old wrapped form nests: that is MENOR-1). Sourced from
# builder.code so the `maintainer-addressless` mutation can reach it.
chk "build-deb.sh's OWN default carries an address (a bare address is E: no-phrase)" \
  "$(grep -cE '^maintainer=\$\{MAINTAINER:-[^}]*<[^>]*@[^>]*>\}' "$WORK/builder.code")" 1
chk "and it always hands that contact to render.sh (never render.sh's addressless default)" \
  "$(grep -cF -- '--maintainer "$maintainer"' "$WORK/builder.code" || true)" 1
chk "the runtime's SHIPPED Maintainer carries an address" \
  "$(dpkg-deb -f "$RT" Maintainer 2>/dev/null | grep -cE '<[^>]*@[^>]*>' || true)" 1
chk "the launcher's SHIPPED Maintainer carries an address too" \
  "$(dpkg-deb -f "$LT" Maintainer 2>/dev/null | grep -cE '<[^>]*@[^>]*>' || true)" 1

# --- G-DEB-3 ------------------------------------------------------------------------------------
sec "G-DEB-3  no DEBIAN/conffiles (C5/C7: registering resolv.conf is a lintian error)"
chk "the runtime's control archive holds exactly control+3 scripts" \
  "$(ls "$WORK/rt.ctl.d" | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')" "control postinst postrm prerm"
chk "NO conffiles" "$(find "$WORK/rt.ctl.d" -maxdepth 1 -name conffiles | wc -l | tr -d ' ')" 0
chk "the launcher's control archive holds ONLY control (no maintainer scripts)" \
  "$(ls "$WORK/lt.ctl.d" | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')" "control"
chk "the three maintainer scripts are 0755" \
  "$(n=0; for f in postinst postrm prerm; do [ "$(stat -c '%a' "$WORK/rt.ctl.d/$f")" = 755 ] && n=$((n+1)); done; printf '%s' "$n")" 3
chk "control is 0644" "$(stat -c '%a' "$WORK/rt.ctl.d/control")" 644
chk "private/etc content ships as plain 0644 data" \
  "$(grep -cE '^-rw-r--r-- root/root .* \./usr/libexec/darling/private/etc/paths$' "$WORK/rt.list" || true)" 1

sec "the shipped maintainer scripts (T3 acceptance, one row per promise)"
chk "postinst asserts the setuid mode AND the real mldr" \
  "$(allof "$WORK/rt.ctl.d/postinst" 'expected 4755' 'usr/libexec/darling/mldr' 'exit 1')" 3
chk "postinst reloads systemd-binfmt NON-fatally" \
  "$(grep -cE 'systemctl restart systemd-binfmt\.service >/dev/null 2>&1 \|\|' "$WORK/rt.ctl.d/postinst" || true)" 1
chk "postinst prints the next step, naming the launcher package" \
  "$(cntn 'Next steps' 'darling-lol-launcher' "$WORK/rt.ctl.d/postinst")" 2
chk "postrm reloads binfmt on remove AND purge (C6)" \
  "$(grep -cE '^if \[ "\$1" = remove \] \|\| \[ "\$1" = purge \]; then$' "$WORK/rt.ctl.d/postrm" || true)" 1
chk "prerm handles failed-upgrade (the arm that is not optional, as CODE not prose)" \
  "$(cnt '^[[:space:]]*failed-upgrade) : ;;$' "$WORK/rt.ctl.d/prerm")" 1
cat "$WORK/rt.ctl.d/postinst" "$WORK/rt.ctl.d/postrm" "$WORK/rt.ctl.d/prerm" > "$WORK/rtscripts"
# N5 is about MUTATING per-user state, so the row looks for a mutating command naming it -- the
# scripts *talk* about ~/.darling in their comments and in postinst's closing message on purpose.
chk "no maintainer script mutates per-user state (N5)" \
  "$(cnt '(rm|rmdir|chown|chmod|install|mkdir|cp|mv|find)[^|]*(\.darling|\.local/share/darling-lol)' "$WORK/rtscripts")" 0
if command -v shellcheck >/dev/null 2>&1; then
  sc=0
  for f in postinst postrm prerm; do
    shellcheck -s sh -S warning "$WORK/rt.ctl.d/$f" || sc=$((sc+1))
  done
  chk "the SHIPPED scripts are shellcheck-clean (POSIX sh)" "$sc" 0
  sc2=0
  shellcheck -S warning packaging/common/build-deb.sh packaging/deb/*.sh || sc2=$?
  chk "the T3 builders are shellcheck-clean (G-STATIC-1 does not glob packaging/deb/)" "$sc2" 0
else
  skip "shellcheck is not installed"
fi
d=0
for f in "$WORK/rt.ctl.d/postinst" "$WORK/rt.ctl.d/postrm" "$WORK/rt.ctl.d/prerm"; do
  dash -n "$f" 2>/dev/null || d=$((d+1))
done
chk "dash -n parses all three shipped scripts" "$d" 0

# --- PLAN 9.5: the copyright is generated --------------------------------------------------------
sec "the copyright is GENERATED from the pinned body (PLAN 9.5), not typed into the payload"
rc=0; sh packaging/deb/mk-copyright.sh --upstream "$UPSTREAM" --out "$WORK/copyright.1" 2>"$WORK/cop.err" || rc=$?
chk "mk-copyright.sh exits 0 over the synthetic upstream" "$rc" 0
chk "exactly ONE header paragraph (the upstream's own was dropped)" \
  "$(cnt '^Upstream-Name: ' "$WORK/copyright.1")" 1
chk "the upstream stanzas are inlined verbatim (path AND short name)" \
  "$(cntn '^Files: src/harness-marker-only$' '^License: T3-Harness-Marker-1.0$' "$WORK/copyright.1")" 2
chk "the header stanza of the upstream file did NOT survive twice" \
  "$(cnt '^Upstream-Contact: ' "$WORK/copyright.1")" 1
pin=$(sed -n 's/.*"revision": "\([0-9a-fA-F]\{40\}\)".*/\1/p' upstream/manifest.json | head -n 1)
chk "the header carries the 40-hex pin from upstream/manifest.json" \
  "$(grep -c -- "pinned at $pin, patched by darling-lol" "$WORK/copyright.1" || true)" 1
# and the pin is DERIVED, not typed: change the manifest, the generated header changes with it
MUT2=$WORK/mut2
mkdir -p "$MUT2/upstream"
cp -a packaging "$MUT2/packaging"
sed 's/"revision": "[0-9a-fA-F]\{40\}"/"revision": "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"/' \
  upstream/manifest.json > "$MUT2/upstream/manifest.json"
sh "$MUT2/packaging/deb/mk-copyright.sh" --upstream "$UPSTREAM" --out "$WORK/copyright.mut" 2>/dev/null || true
chk "with a different manifest the header follows it (deadbeef...)" \
  "$(cnt 'pinned at deadbeefdeadbeefdeadbeefdeadbeefdeadbeef, patched by darling-lol' "$WORK/copyright.mut")" 1
chk "and the real pin is gone from that run" "$(cnt "$pin" "$WORK/copyright.mut")" 0

sec "the copyright is SHIPPED, and what is shipped is what the generator emits"
chk "the runtime ships /usr/share/doc/darling-lol/copyright" \
  "$([ -s "$WORK/rt.x/usr/share/doc/darling-lol/copyright" ] && echo 1 || echo 0)" 1
chk "the launcher ships its own" "$([ -s "$WORK/lt.x/usr/share/doc/darling-lol-launcher/copyright" ] && echo 1 || echo 0)" 1
chk "both are mode 0644" \
  "$(n=0; for f in "$WORK/rt.x/usr/share/doc/darling-lol/copyright" "$WORK/lt.x/usr/share/doc/darling-lol-launcher/copyright"; do [ "$(stat -c '%a' "$f")" = 644 ] && n=$((n+1)); done; printf '%s' "$n")" 2
chk "the SHIPPED copy carries the harness's marker (it was generated, not typed)" \
  "$(cnt 'T3-Harness-Marker-1.0' "$WORK/rt.x/usr/share/doc/darling-lol/copyright")" 1
sh packaging/deb/mk-copyright.sh --upstream "$UPSTREAM" --out "$WORK/copyright.2" 2>/dev/null || true
chk "it is byte-identical to a fresh generation from the same input" \
  "$(cmp -s "$WORK/rt.x/usr/share/doc/darling-lol/copyright" "$WORK/copyright.2" && echo identical || echo differs)" identical
rc=0; sh packaging/deb/mk-copyright.sh --upstream /nonexistent/pinned/debian/copyright \
  --if-missing fail --out "$WORK/copyright.3" 2>"$WORK/cop.fail" || rc=$?
chk "production mode (--if-missing fail) refuses to ship without the pinned body" "$rc" 1
chk "and it names the file it wanted" "$(cnt '/nonexistent/pinned/debian/copyright' "$WORK/cop.fail")" 1
sh packaging/deb/mk-copyright.sh --upstream /nonexistent/pinned/debian/copyright \
  --if-missing note --out "$WORK/copyright.4" 2>/dev/null || true
chk "fixture mode (--if-missing note) says the stanzas were omitted" \
  "$(cnt 'upstream stanzas omitted' "$WORK/copyright.4")" 1

# --- the REAL pinned shape -----------------------------------------------------------------------
sec "the REAL pinned shape: a flat notice, no Format: header, no stanzas (run 39258643917)"
# Everything above feeds the generator the DEP-5 shape. This section feeds it -- and the full
# builder, and the container below -- the shape the pin actually ships. The divergence between
# the two is the class that killed the packages job twice and, through build-all's fail-fast,
# kept rpm and tar from ever running in production.
rc=0; sh packaging/deb/mk-copyright.sh --upstream "$UPSTREAM_FLAT" --if-missing fail \
  --out "$WORK/copyright.flat" 2>"$WORK/cop.flat.err" || rc=$?
chk "mk-copyright.sh exits 0 over the REAL shape, in production mode" "$rc" 0
chk "the three notices are all present, as Comment continuations" \
  "$(cnt '^ Copyright (C) ' "$WORK/copyright.flat")" 3
chk "no notice stands at column 0 (that would open a malformed paragraph)" \
  "$(cnt '^Copyright (C) ' "$WORK/copyright.flat")" 0
chk "still exactly one header paragraph" "$(cnt '^Upstream-Name: ' "$WORK/copyright.flat")" 1
chk "and exactly one Files: paragraph (the generator invented no stanza)" \
  "$(cnt '^Files: ' "$WORK/copyright.flat")" 1
sh packaging/deb/mk-copyright.sh --upstream "$UPSTREAM_FLAT" --out "$WORK/copyright.flat2" 2>/dev/null || true
chk "the flat output regenerates byte-identically" \
  "$(cmp -s "$WORK/copyright.flat" "$WORK/copyright.flat2" && echo identical || echo differs)" identical
# the fail-closed classes stay dead: a DEP-5 file whose body is empty, and a file with no text
# at all, must still refuse -- the verbatim branch must not become a licence to emit nothing.
printf 'Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/\n\n' \
  > "$WORK/dep5-no-stanzas"
rc=0; sh packaging/deb/mk-copyright.sh --upstream "$WORK/dep5-no-stanzas" \
  --out "$WORK/copyright.ns" 2>/dev/null || rc=$?
chk "a DEP-5 file with an empty body still FATALs (the old fail-closed rule survives)" "$rc" 1
printf '   \n\n\t\n' > "$WORK/blank-only"
rc=0; sh packaging/deb/mk-copyright.sh --upstream "$WORK/blank-only" \
  --out "$WORK/copyright.bo" 2>/dev/null || rc=$?
chk "a whitespace-only file still FATALs" "$rc" 1
# and the REAL builder, end to end, over the real shape -- the exact call the CI packages job
# makes through build-all.sh. The flat pair gets its own DIST so the synthetic object under test
# is untouched; the container section below lints BOTH pairs.
DIST_FLAT=$WORK/dist-flat
rc=0
env DIST="$DIST_FLAT" FIXTURE_DIR="$DIST_FLAT/fixture" UPSTREAM_COPYRIGHT="$UPSTREAM_FLAT" \
  sh "$BUILDER" fixture > "$WORK/build-flat.log" 2>&1 || rc=$?
sed 's/^/    /' "$WORK/build-flat.log"
chk "the builder exits 0 over the pinned REAL shape (flat copyright)" "$rc" 0
chk "the flat build reports no FATAL" "$(cnt 'FATAL' "$WORK/build-flat.log")" 0
chk "the flat-shape artifacts exist and are non-empty" \
  "$([ -s "$DIST_FLAT/fix.deb" ] && [ -s "$DIST_FLAT/fix-launcher.deb" ] && echo 2 || echo 0)" 2
dpkg-deb -x "$DIST_FLAT/fix.deb" "$WORK/flat.x" || true
chk "the SHIPPED flat-shape copyright keeps the three notices as continuations" \
  "$(cnt '^ Copyright (C) ' "$WORK/flat.x/usr/share/doc/darling-lol/copyright")" 3
chk "and ships no column-0 notice (the malformed-paragraph class stays closed)" \
  "$(cnt '^Copyright (C) ' "$WORK/flat.x/usr/share/doc/darling-lol/copyright")" 0
# when the prepared checkout exists on this box, the generator must survive the pin itself, not
# just the harness's copy of its shape.
if [ -r build/darling-src/debian/copyright ]; then
  rc=0; sh packaging/deb/mk-copyright.sh --out "$WORK/copyright.pin" 2>"$WORK/cop.pin.err" || rc=$?
  chk "the generator exits 0 over the REAL pinned checkout on this box" "$rc" 0
else
  skip "the generator vs build/darling-src/debian/copyright (needs scripts/prepare.py on this box)"
fi

# --- C4: the changelog ---------------------------------------------------------------------------
sec "the changelog (C4: E: no-changelog)"
chk "changelog.Debian.gz is in BOTH packages" \
  "$(n=0; for f in "$WORK/rt.x/usr/share/doc/darling-lol/changelog.Debian.gz" "$WORK/lt.x/usr/share/doc/darling-lol-launcher/changelog.Debian.gz"; do [ -s "$f" ] && n=$((n+1)); done; printf '%s' "$n")" 2
chk "and it is really gzipped" \
  "$(n=0; for f in "$WORK/rt.x/usr/share/doc/darling-lol/changelog.Debian.gz" "$WORK/lt.x/usr/share/doc/darling-lol-launcher/changelog.Debian.gz"; do [ "$(head -c2 "$f" | od -An -tx1 | tr -d ' \n')" = 1f8b ] && n=$((n+1)); done; printf '%s' "$n")" 2
chk "gzip -9n: no name field, no mtime (reproducible bytes)" \
  "$(od -An -tx1 -N8 "$WORK/rt.x/usr/share/doc/darling-lol/changelog.Debian.gz" | tr -d ' \n')" "1f8b080000000000"
gunzip -c "$WORK/rt.x/usr/share/doc/darling-lol/changelog.Debian.gz" > "$WORK/changelog" 2>/dev/null || true
chk "the two copies are byte-identical (one generated file, installed twice)" \
  "$(cmp -s "$WORK/rt.x/usr/share/doc/darling-lol/changelog.Debian.gz" "$WORK/lt.x/usr/share/doc/darling-lol-launcher/changelog.Debian.gz" && echo identical || echo differs)" identical
chk "the changelog header names the version and the archive" \
  "$(cnt "^darling-lol ($VERSION) unstable; urgency=low$" "$WORK/changelog")" 1
chk "the trailer is an RFC2822 date with a NUMERIC zone (English day/month)" \
  "$(grep -cE '^ -- darling-lol maintainers <darling-lol@users\.noreply\.github\.com>  [A-Z][a-z]{2}, [0-9]{2} [A-Z][a-z]{2} [0-9]{4} [0-9]{2}:[0-9]{2}:[0-9]{2} \+0000$' "$WORK/changelog" || true)" 1
chk "no @TOKEN@ left in the changelog (render.sh's guard saw it first)" \
  "$(cnt '@[A-Za-z_]*@' "$WORK/changelog")" 0

# --- PLAN 5/D3: the two packages are a split -----------------------------------------------------
sec "the two packages split the tree, and do not overlap (PLAN 5/D3, C18)"
sed 's/^.* \.\//\//' "$WORK/rt.list" | grep -v '/$' | LC_ALL=C sort > "$WORK/rt.paths"
sed 's/^.* \.\//\//' "$WORK/lt.list" | grep -v '/$' | LC_ALL=C sort > "$WORK/lt.paths"
chk "no non-directory entry appears in BOTH packages" \
  "$(LC_ALL=C comm -12 "$WORK/rt.paths" "$WORK/lt.paths" | wc -l | tr -d ' ')" 0
chk "both packages ship more than one entry" \
  "$(r=$(wc -l < "$WORK/rt.paths" | tr -d ' '); l=$(wc -l < "$WORK/lt.paths" | tr -d ' ')
     [ "$r" -gt 1 ] && [ "$l" -gt 1 ] && echo both || echo "runtime=$r launcher=$l")" both
chk "the runtime does not ship the launcher's paths" \
  "$(grep -cE '^/(usr/bin/darling-lol|usr/lib/darling-lol/)' "$WORK/rt.paths" || true)" 0
chk "the launcher does not ship the runtime's" \
  "$(grep -cE '^/(usr/bin/darling$|usr/bin/darlingserver|usr/libexec/darling/|usr/lib/binfmt\.d/|usr/share/darling/)' "$WORK/lt.paths" || true)" 0
chk "the launcher ships the wrapper, a script and a template" \
  "$(grep -c -e '^/usr/bin/darling-lol$' -e '^/usr/lib/darling-lol/scripts/common.py$' -e '^/usr/lib/darling-lol/tools/config.in$' "$WORK/lt.paths" || true)" 3
chk "the runtime ships the guest tree, the binfmt drop-in and the host ELFs" \
  "$(grep -c -e 'System/Library/User Template/' -e '/usr/lib/binfmt.d/darling.conf$' -e ' \./usr/bin/darlingserver$' "$WORK/rt.list" || true)" 3

sec "the lintian overrides ship, and are honest (PLAN 9.6)"
chk "both packages ship their override file" \
  "$(n=0; for f in "$WORK/rt.x/usr/share/lintian/overrides/darling-lol" "$WORK/lt.x/usr/share/lintian/overrides/darling-lol-launcher"; do [ -s "$f" ] && n=$((n+1)); done; printf '%s' "$n")" 2
chk "the runtime's override names the setuid binary (lintian's name, not PLAN 9.6's inert setuid-binary)" \
  "$(cnt '^elevated-privileges \*$' "$WORK/rt.x/usr/share/lintian/overrides/darling-lol")" 1
chk "and does not use the inert context form the plan carries (measured: mismatched-override)" \
  "$(cnt '^elevated-privileges [0-9]' "$WORK/rt.x/usr/share/lintian/overrides/darling-lol")" 0
chk "the launcher's override claims no elevated-privileges file it does not have" \
  "$(cnt 'elevated-privileges' "$WORK/lt.x/usr/share/lintian/overrides/darling-lol-launcher")" 0
cat "$WORK/rt.x/usr/share/lintian/overrides/darling-lol" \
    "$WORK/lt.x/usr/share/lintian/overrides/darling-lol-launcher" > "$WORK/overrides"
chk "every non-comment line is '<tag>' or '<tag> <context>' (no trailing blank)" \
  "$(grep -vE '^(#|$)' "$WORK/overrides" | grep -vcE '^[a-z][a-z0-9-]+( .*[^ ])?$' || true)" 0
chk "no override line names one of the five tags the gate's lintian does not know (F9)" \
  "$(grep -cE '^(dangling-symlink|no-shebang|shebang-is-interpreter|non-executable-script|example-interpreter-not-in-package)( |$)' "$WORK/overrides" || true)" 0
chk "no override line uses a tag NAME lintian has renamed away (the old spelling is inert, not an error)" \
  "$(grep -cE '^(binary-or-shlib-defines-rpath|setuid-binary|setgid-binary)( |$)' "$WORK/overrides" || true)" 0

# --- G-DEB-4 -------------------------------------------------------------------------------------
sec "G-DEB-4  lintian --fail-on error (the row the copyright/override mutations turn red)"
LINTIAN_IMAGE=${T3_LINTIAN_IMAGE:-ubuntu:24.04}
if [ "${T3_GATES_DOCKER:-0}" != 1 ]; then
  dockerskip=1
  skip "G-DEB-4 not run: lintian is not installed on this box (Debian 12 carries 2.116.3; the PLAN measured C4 with 2.122.0) and installing it is a host modification. Re-run with T3_GATES_DOCKER=1 to run the brief's container (image: $LINTIAN_IMAGE)"
elif ! command -v docker >/dev/null 2>&1; then
  dockerskip=1
  skip "G-DEB-4 not run: docker is not installed (T3_GATES_DOCKER=1 was set)"
else
  lrc=0
  # The distinct tag names the two override files use, one per line, read inside the container.
  # An unknown name is "E: alien-tag" (the override file fails the gate it exists to satisfy), and
  # that check needs no package at all -- so it runs first, and it is the row that catches a
  # copy-paste from PLAN 9.6 (five of its names are unknown to lintian 2.117, see finding F9).
  grep -vE '^(#|$)' "$WORK/overrides" | awk '{print $1}' | LC_ALL=C sort -u > "$DIST/override-tags.txt"
  # the flat-shape pair rides the same mount: /w is $DIST, so the two copies below join fix.deb
  # and fix-launcher.deb. If the flat build itself failed, these cp errors are noise next to what
  # the offline rows already said; the container's LINTIAN_FLAT_RC row is what stays honest.
  cp "$DIST_FLAT/fix.deb" "$DIST/fix-flat.deb"
  cp "$DIST_FLAT/fix-launcher.deb" "$DIST/fix-flat-launcher.deb"
  # T3_LINTIAN_FAILON is a control-only knob (default: error, the brief's level). The negative
  # control at the bottom sets it to `warning` to prove the two rc rows below are not vacuous: this
  # object's 8 W: lines make lintian exit 2 WITHOUT printing an E: line, so the "0 E: lines" row
  # stays green and only a truthful container exit status can catch it.
  FA=$FAILON_LEVEL
  lout=$(timeout 3600 docker run --rm -v "$DIST:/w:ro" "$LINTIAN_IMAGE" bash -lc '
    if ! command -v lintian >/dev/null 2>&1; then
      apt-get update -qq >/dev/null 2>&1 || { echo "APT-UPDATE-FAILED"; exit 3; }
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends lintian >/dev/null 2>&1 \
        || { echo "APT-INSTALL-FAILED"; exit 3; }
    fi
    echo "LINTIAN_VERSION=$(lintian --version 2>&1 | head -1)"
    echo "LINTIAN_FAILON='"$FA"'"
    lintian-explain-tags --list-tags > /tmp/known-tags.txt 2>/dev/null
    unknown=0
    while read -r t; do
      [ -n "$t" ] || continue
      grep -qxF "$t" /tmp/known-tags.txt || { echo "UNKNOWN-TAG $t"; unknown=$((unknown+1)); }
    done < /w/override-tags.txt
    echo "UNKNOWN_TAG_COUNT=$unknown"
    # lintian'"'"'s OWN exit status is the container'"'"'s, and it is reported as a number: an echo after a
    # failing lintian would make both rc rows green no matter what lintian did (measured: the
    # `warning` control below is what keeps this honest).
    lintian --fail-on '"$FA"' --no-tag-display-limit /w/fix.deb /w/fix-launcher.deb; lrc=$?
    echo "LINTIAN_CLEAN_RC=$lrc"
    # the flat-shape pair (the upstream copyright the REAL pin ships) gets its own invocation and
    # its own markers, so a regression in either shape names itself instead of blending into the
    # aggregate E: count. The container still exits with the status OF THE SYNTHETIC PAIR: the
    # rows whose controls already depend on that keep their meaning, and the flat pair has its
    # own rc row below.
    lintian --fail-on '"$FA"' --no-tag-display-limit /w/fix-flat.deb /w/fix-flat-launcher.deb \
      > /tmp/flat.out 2>&1; flrc=$?
    cat /tmp/flat.out
    echo "E_FLAT_COUNT=$(grep -c "^E: " /tmp/flat.out || true)"
    echo "LINTIAN_FLAT_RC=$flrc"
    exit $lrc' 2>&1) || lrc=$?
  printf '%s\n' "$lout" > "$WORK/lintian.log"
  sed 's/^/    /' "$WORK/lintian.log"
  chk "lintian actually ran (this row keeps the two below from being vacuous)" \
    "$(cnt '^LINTIAN_VERSION=' "$WORK/lintian.log")" 1
  chk "every tag name in the override files is one the gate's lintian knows (0 alien; F9)" \
    "$(cnt '^UNKNOWN_TAG_COUNT=0$' "$WORK/lintian.log")" 1
  chk "0 E: lines over all four packages (both upstream shapes)" "$(cnt '^E: ' "$WORK/lintian.log")" 0
  chk "lintian --fail-on error exits 0, and says so itself" \
    "$(cnt '^LINTIAN_CLEAN_RC=0$' "$WORK/lintian.log")" 1
  chk "the container exited 0" "$lrc" 0
  # the flat pair's own rows: ran, clean, and rc reported by lintian itself (the same honesty the
  # synthetic pair's control above established for the first invocation).
  chk "the flat pair was lintian'd too (its own rc marker reported)" \
    "$(cnt '^LINTIAN_FLAT_RC=' "$WORK/lintian.log")" 1
  chk "0 E: lines over the flat pair" "$(cnt '^E_FLAT_COUNT=0$' "$WORK/lintian.log")" 1
  chk "lintian --fail-on error exits 0 over the flat pair, and says so itself" \
    "$(cnt '^LINTIAN_FLAT_RC=0$' "$WORK/lintian.log")" 1
fi

# --- hygiene -------------------------------------------------------------------------------------
sec "hygiene: the harness touched nothing it did not create"
# T1's own G-STATIC row ("every file ends with a newline") globs packaging/common/* and
# packaging/testdata/* -- it does not look at packaging/deb/, and it caught exactly two files of
# this task (the builder and this battery) the first time the full T1 battery was re-run. This row
# is the half T1 cannot see, and it is why packaging/deb/* was checked here.
chk "every file in packaging/deb/ ends with a newline (T1 hygiene row globs common/ + testdata/ only, F6)" \
  "$(for f in "$SRC"/deb/*; do [ -n "$(tail -c1 "$f")" ] && echo x; done | wc -l)" 0
GIT_AFTER=$(git status --porcelain 2>/dev/null | LC_ALL=C sort)
chk "git status --porcelain is unchanged by the run" \
  "$([ "$GIT_BEFORE" = "$GIT_AFTER" ] && echo unchanged || echo changed)" unchanged
chk "the artifacts are inside the private workdir, not in dist/" \
  "$(case "$RT" in "$WORK"/*) echo yes ;; *) echo no ;; esac)" yes

# --- negative control (TASKS preamble rule 7) ----------------------------------------------------
# Every swept row must be able to go RED. The control breaks the OBJECT under test
# (T3_GATES_BREAK, a copy) and re-runs this file, asserting the run exits non-zero AND names the
# row that was swept. The child sees BREAK set, so it skips this section -- no recursion.
# T3_NO_CONTROL marks the one control that mutates the MEASUREMENT instead of the object (the
# lintian fail-on level): nothing about the object changes there, so a BREAK label would be a lie.
if [ -z "$BREAK" ] && [ -z "$NO_CONTROL" ]; then
  sec "negative control: the swept rows MUST go red when their object breaks"
  esc=$(printf '\033')
  ctl() { # ctl BREAK 'FAIL-label' [needle the child's output must also contain]
    crc=0; cout=$(T3_GATES_BREAK="$1" bash "$0" 2>&1) || crc=$?
    cn=$(printf '%s\n' "$cout" | sed "s/${esc}\[[0-9;]*m//g" | grep -cF "FAIL $2")
    if [ "$crc" != 0 ] && [ "$cn" = 1 ]; then ok "T3_GATES_BREAK=$1 -> red on '$2' (rc $crc)"
    else no "T3_GATES_BREAK=$1: expected exactly 1 'FAIL $2', rc $crc, got $cn"; fi
    if [ -n "${3:-}" ]; then
      ck=$(printf '%s\n' "$cout" | grep -cF "$3")
      if [ "$ck" -ge 1 ]; then ok "T3_GATES_BREAK=$1: and the failure names '$3'"
      else no "T3_GATES_BREAK=$1: the output does not mention '$3'"; fi
    fi
  }
  ctl no-root-owner-group "every entry is root/root"
  ctl no-copyright       "the runtime ships /usr/share/doc/darling-lol/copyright"
  ctl conffiles          "NO conffiles"
  ctl override-tag       "the runtime's override names the setuid binary (lintian's name, not PLAN 9.6's inert setuid-binary)"
  ctl games-section      "neither package claims the games section while shipping no /usr/games entry (F10)"
  ctl essential-depends  "the launcher does not depend on an Essential package unversioned (F11: bash and coreutils are Essential: yes)"
  ctl no-trailing-newline "every file in packaging/deb/ ends with a newline (T1 hygiene row globs common/ + testdata/ only, F6)"
  ctl binary-version     'the builder exits 0 (fixture mode)' '${binary:Version}'
  # MENOR-2: the row that used to PASS while a zstd member was present. The mutation flips only the
  # launcher's `-Zxz`, so the runtime row stays green and this one (plus the swept "either" row)
  # must redden.
  ctl launcher-zstd      "the launcher's data member is xz"
  # MENOR-1: PLAN 9.1 rev 7's wrapped Maintainer:, put back -- with a real contact it nests, and the
  # exact-value row is what sees it offline.
  ctl maintainer-wrapped "Section/Priority/Homepage/Maintainer as the templates say (F10: otherosfs, not games)"
  # MENOR-4: the builder's own default, made addressless (the state render.sh:27 still ships). The
  # guard rows that assert the deb path never relies on render.sh's default are what redden.
  ctl maintainer-addressless "build-deb.sh's OWN default carries an address (a bare address is E: no-phrase)"
  # run 39258643917's class: the REAL upstream shape, restored to FATAL in the generator. The
  # flat builder row is the swept one -- production feeds build-deb.sh exactly this file, and the
  # direct generator rows read the repo's script, so only the builder-driven row can see it.
  ctl flat-fatal        "the builder exits 0 over the pinned REAL shape (flat copyright)"
  # the naive fix (column-0 copy) opens a malformed paragraph lintian never parses in a shipped
  # doc copyright (measured) -- so the structural row, not the container, is its discharge.
  ctl flat-unindented   "the SHIPPED flat-shape copyright keeps the three notices as continuations"

  # G-DEB-4 is the row the container work exists for, so it must be able to go red too -- and only
  # the container can show that: the same no-copyright mutation makes lintian report
  # "E: darling-lol: no-copyright-file", i.e. the CHILD's own "0 E: lines" row fails. Asserting the
  # inner row (not just the harness's copyright row above) is what makes G-DEB-4 non-vacuous.
  # It needs the same container as the row itself, so it is SKIPped without T3_GATES_DOCKER=1.
  if [ "${T3_GATES_DOCKER:-0}" = 1 ] && command -v docker >/dev/null 2>&1; then
    crc=0; cout=$(T3_GATES_BREAK=no-copyright bash "$0" 2>&1) || crc=$?
    cn=$(printf '%s\n' "$cout" | sed "s/${esc}\[[0-9;]*m//g" | grep -cF "FAIL 0 E: lines over all four packages (both upstream shapes)")
    if [ "$crc" != 0 ] && [ "$cn" = 1 ]; then ok "T3_GATES_BREAK=no-copyright -> G-DEB-4 goes red INSIDE the container (rc $crc)"
    else no "T3_GATES_BREAK=no-copyright: G-DEB-4 did not go red inside the container (rc $crc, $cn matching rows)"; fi
    ck=$(printf '%s\n' "$cout" | grep -cF "E: darling-lol: no-copyright-file")
    if [ "$ck" -ge 1 ]; then ok "and the child's lintian output names E: no-copyright-file"
    else no "the child's lintian output does not name no-copyright-file"; fi

    # MENOR-3: the plan's own override mutation, discharged IN-TREE. `override-tag` above deletes a
    # *warning*-severity line, which proves the in-tree TEXT row but leaves `--fail-on error` at rc 0
    # (F14). This deletes an *error*-severity line, so only the container can see it: the child's
    # "0 E: lines over all four packages" row must fail and lintian must print
    # `E: darling-lol: binary-from-other-architecture` for both stand-ins. Without this control the
    # override list's container load-bearing-ness would be asserted nowhere in the deliverable.
    crc=0; cout=$(T3_GATES_BREAK=override-error-tag bash "$0" 2>&1) || crc=$?
    cn=$(printf '%s\n' "$cout" | sed "s/${esc}\[[0-9;]*m//g" | grep -cF "FAIL 0 E: lines over all four packages (both upstream shapes)")
    if [ "$crc" != 0 ] && [ "$cn" = 1 ]; then ok "T3_GATES_BREAK=override-error-tag -> G-DEB-4 goes red INSIDE the container (rc $crc)"
    else no "T3_GATES_BREAK=override-error-tag: G-DEB-4 did not go red inside the container (rc $crc, $cn matching rows)"; fi
    ck=$(printf '%s\n' "$cout" | grep -cF "E: darling-lol: binary-from-other-architecture")
    if [ "$ck" -ge 1 ]; then ok "and the error-severity override's removal names E: binary-from-other-architecture"
    else no "the child's lintian output does not name binary-from-other-architecture"; fi

    # MENOR-1/C43-g: the plan's own Maintainer mutation, anchored where the plan says it is seen.
    # Reverting control.in:6 to PLAN 9.1 rev 7's wrapped form makes the rendered contact nest
    # (`darling-lol maintainers <darling-lol maintainers <addr>>`); dpkg-deb accepts it (rc 0), so
    # only lintian sees it -- and it must print `E: malformed-contact`.
    crc=0; cout=$(T3_GATES_BREAK=maintainer-wrapped bash "$0" 2>&1) || crc=$?
    cn=$(printf '%s\n' "$cout" | sed "s/${esc}\[[0-9;]*m//g" | grep -cF "FAIL 0 E: lines over all four packages (both upstream shapes)")
    if [ "$crc" != 0 ] && [ "$cn" = 1 ]; then ok "T3_GATES_BREAK=maintainer-wrapped -> G-DEB-4 goes red INSIDE the container (rc $crc)"
    else no "T3_GATES_BREAK=maintainer-wrapped: G-DEB-4 did not go red inside the container (rc $crc, $cn matching rows)"; fi
    ck=$(printf '%s\n' "$cout" | grep -cF "E: darling-lol: malformed-contact")
    if [ "$ck" -ge 1 ]; then ok "and the nested Maintainer names E: malformed-contact (C43-g's measured class)"
    else no "the child's lintian output does not name malformed-contact"; fi

    # The two rc rows are only as good as the container's exit status, and a trailing `echo` after
    # lintian would make them green no matter what lintian did (measured: it did, until the inner
    # script started exiting with lintian's own status). Prove the fix: `warning` makes lintian exit
    # 2 over this object's 8 W: lines while printing NO E: line, so the E-line row must STAY green
    # and the rc rows must go red. T3_NO_CONTROL=1 replaces the BREAK label: the object is
    # untouched, the measurement is what changes.
    crc=0; cout=$(T3_NO_CONTROL=1 T3_LINTIAN_FAILON=warning bash "$0" 2>&1) || crc=$?
    cout=$(printf '%s\n' "$cout" | sed "s/${esc}\[[0-9;]*m//g")
    cn=$(printf '%s\n' "$cout" | grep -cF "FAIL lintian --fail-on error exits 0, and says so itself")
    ck=$(printf '%s\n' "$cout" | grep -cF "FAIL the container exited 0")
    ce=$(printf '%s\n' "$cout" | grep -cF "FAIL 0 E: lines over all four packages (both upstream shapes)")
    if [ "$crc" != 0 ] && [ "$cn" = 1 ] && [ "$ck" = 1 ] && [ "$ce" = 0 ]; then
      ok "T3_LINTIAN_FAILON=warning -> both rc rows go red and the E-line row does not (rc $crc)"
    else
      no "T3_LINTIAN_FAILON=warning: wanted rc!=0, 1 rc-row + 1 exit-row FAIL, 0 E-row FAIL; got rc $crc, $cn, $ck, $ce"
    fi
    ck=$(printf '%s\n' "$cout" | grep -cF "LINTIAN_CLEAN_RC=2")
    if [ "$ck" = 1 ]; then ok "and lintian's own status (2) is what the container reports, not the last echo's 0"
    else no "the container did not report lintian's status (LINTIAN_CLEAN_RC=2 count: $ck)"; fi
  else
    skip "the G-DEB-4 negative control (T3_GATES_DOCKER=1 + docker needed)"
  fi
fi

sec "SUMMARY"
# NIT-5: a battery that is green while G-DEB-4 never ran is exactly the CI wiring NIT-5 warns
# about. Opt-in, because a bare offline run cannot run lintian: with T3_GATES_REQUIRE_DOCKER=1 a
# skipped policy gate is a FAILURE, not a yellow line.
if [ "$REQUIRE_DOCKER" = 1 ]; then
  chk "G-DEB-4 ran (T3_GATES_REQUIRE_DOCKER=1 forbids a green battery with the policy gate skipped)" \
    "$([ "$dockerskip" = 0 ] && echo ran || echo skipped)" ran
fi
printf '  %d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skips"
[ "$skips" = 0 ] || printf '  \033[33m%d row(s) SKIPped: SKIP is not PASS\033[0m\n' "$skips"
[ "$fail" = 0 ] || exit 1
