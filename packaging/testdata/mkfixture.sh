#!/bin/sh
# packaging/testdata/mkfixture.sh -- build the hostile-shape staging fixture for G-STATIC-6.
#
# The real payload contains shapes that break naive file-list generators: 53 space-paths, 2189
# '%'-paths, dangling guest symlinks, empty directories, a setuid and a setgid binary, and a
# template with an unexpanded @GUEST_HOME@ (EVIDENCE §7.2). This fixture reproduces them in a
# tree that is *also* a valid /usr prefix tree, so `stage.sh` (which calls check-prefix.sh in
# step 3b) can be run against it end to end.
#
# It writes:
#   <dir>/root            the staging tree (9 hostile shapes + launcher + a correct /usr prefix)
#   <dir>/files.all       the generated list, exactly as stage.sh step 3 makes it
#   <dir>/expect-runtime  the runtime paths, computed INDEPENDENTLY of stage.sh (different find
#                         expression, different launcher subtraction) so a bug in stage.sh's
#                         -printf or its `comm` split shows up as a diff (G-STATIC-6)
#
# usage: mkfixture.sh <dir>
set -eu

_here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=mkprefixfixture.sh
. "$_here/mkprefixfixture.sh"

# The 9 hostile shapes, as absolute tree paths. Counted and asserted below.
_hostile='/usr/bin/darling
/usr/libexec/darling/usr/bin/write
/usr/libexec/darling/System/Library/User Template
/usr/libexec/darling/System/Library/CoreServices/Menu Extras/%21.menu
/usr/libexec/darling/usr/share/ipv6only%7c-i.ri
/usr/libexec/darling/usr/share/eql%3f-i.ri
/usr/libexec/darling/usr/share/%3d%3d%3d-i.ri
/usr/libexec/darling/private/etc/machine-id
/usr/libexec/darling/private/tmp'

mkfixture_main() {
  _dir=${1:?usage: mkfixture.sh <dir>}
  _root="$_dir/root"
  rm -rf "$_root"
  mkdir -p "$_root"

  # A correct /usr prefix tree first, so stage.sh's step 3b (check-prefix.sh) passes.
  prefix_elfs "$_root"
  prefix_guest "$_root"
  prefix_host "$_root"

  # The hostile shapes (EVIDENCE §7.2). 1 setuid, 2 setgid, spaces, four distinct %-escapes,
  # a dangling symlink and an empty directory.
  _g="$_root/usr/libexec/darling"
  mkdir -p "$_g/usr/bin" "$_g/System/Library/CoreServices/Menu Extras" "$_g/usr/share"
  printf '\177ELF\000write\000' > "$_g/usr/bin/write"          # setgid (chmod below)
  chmod 2755 "$_g/usr/bin/write"
  mkdir -p "$_g/System/Library/User Template"                  # spaces in a directory name
  printf 'x' > "$_g/System/Library/CoreServices/Menu Extras/%21.menu"
  printf 'x' > "$_g/usr/share/ipv6only%7c-i.ri"
  printf 'x' > "$_g/usr/share/eql%3f-i.ri"
  printf 'x' > "$_g/usr/share/%3d%3d%3d-i.ri"
  mkdir -p "$_g/private/etc"
  ln -s /Volumes/SystemRoot/etc/machine-id "$_g/private/etc/machine-id"
  mkdir -p "$_g/private/tmp"
  # binfmt drop-in + a template carrying an unexpanded @GUEST_HOME@ (both under the launcher).
  printf '%s\n' '# fixture template, rendered per user' '@GUEST_HOME@' \
    > "$_root/usr/lib/darling-lol/tools/config.in"

  prefix_files_all "$_root" "$_dir/files.all"

  # every hostile shape, and nothing else, must be (a) present on disk and (b) listed.
  _h=0
  while IFS= read -r _p; do
    [ -n "$_p" ] || continue
    [ -e "$_root$_p" ] || [ -L "$_root$_p" ] || { echo "mkfixture: FATAL hostile shape missing: $_p" >&2; exit 1; }
    grep -qxF "$_p" "$_dir/files.all" || { echo "mkfixture: FATAL $_p not in files.all" >&2; exit 1; }
    _h=$((_h + 1))
  done <<EOF
$_hostile
EOF

  # expect-runtime: an independent implementation of "everything that is not the launcher".
  ( cd "$_root" && find . -mindepth 1 \( -type f -o -type l -o -type d -empty \) -printf '/%P\n' ) \
    | LC_ALL=C sort \
    | grep -vE '^/(usr/bin/darling-lol$|usr/lib/darling-lol/|usr/share/doc/darling-lol/)' \
    > "$_dir/expect-runtime"

  printf 'mkfixture: %s hostile shapes, %s files all, %s expected runtime\n' \
    "$_h" "$(wc -l < "$_dir/files.all" | tr -d ' ')" \
    "$(wc -l < "$_dir/expect-runtime" | tr -d ' ')"
}

mkfixture_main "$@"
