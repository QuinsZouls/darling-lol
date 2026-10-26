#!/bin/sh
# packaging/testdata/mkprefixfixture.sh -- build the synthetic /usr tree for G-PREFIX-1.
#
# A real /usr build cannot be produced on a dev box (the runtime is x86-64 and needs a full
# cmake build), so the prefix gate is exercised against a fixture that reproduces the byte-level
# facts the gate asserts: the three host ELFs' string content, the launcher's allowlisted fork
# stubs (4 of the 11 names check-prefix.sh allowlists -- the shipped list has 11 since the
# 2026-10-26 /usr-local-fallback tools landed), a
# T8-fixed installer, guest macOS files that legitimately contain /usr/local, an
# empty directory, and the Volumes/DarlingEmulatedDrive -> / escape (EVIDENCE C19/§7.5).
#
# The host ELFs are *binary* stand-ins (NUL bytes): the host-side text sweep uses `grep -I`,
# which skips binary files, exactly like the real payload. `strings -a` still reads the lines.
#
# This file is also sourced by mkfixture.sh for its prefix_* helpers; the main below runs only
# when the file is executed directly.
#
# usage: mkprefixfixture.sh <dir>      -> writes <dir>/root and <dir>/files.all
set -eu

# host_elf FILE LINE... -- a binary stand-in for a host ELF carrying exactly these strings.
host_elf() {
  _f=$1
  shift
  {
    printf '\000\000\000\000'
    for _line in "$@"; do printf '%s\n' "$_line"; done
    printf '\000\000'
  } > "$_f"
}

# prefix_elfs ROOT -- the three host ELFs of a *correct* /usr build.
prefix_elfs() {
  _root=$1
  mkdir -p "$_root/usr/bin"
  # darlingserver bakes LIBEXEC_PATH 3x in the real payload; one exact line is enough here.
  host_elf "$_root/usr/bin/darlingserver" \
    '/usr/libexec/darling' \
    '/usr/libexec/darling/usr/libexec/darling/mldr' \
    'mldr!/usr/libexec/darling/usr/libexec/darling/vchroot'
  host_elf "$_root/usr/bin/darling-coredump" \
    '/usr/libexec/darling' \
    '/usr/libexec/darling/usr/libexec/darling/mldr'
  # darling: ONLY the execl() target moved. The three guest literals stay byte-identical -- that
  # is exactly what assertion (d) checks, and their count must stay exactly 3.
  host_elf "$_root/usr/bin/darling" \
    '/usr/bin/darlingserver' \
    '/usr/local' \
    '/usr/local/share' \
    'PATH=/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin'
  chmod 4755 "$_root/usr/bin/darling"
}

# prefix_guest ROOT -- guest macOS content that legitimately contains /usr/local (never rewritten).
prefix_guest() {
  _root=$1
  _g="$_root/usr/libexec/darling"
  mkdir -p "$_g/private/etc" "$_g/usr/share/doc" "$_g/usr/lib/perl" "$_g/usr/lib/python"
  printf '%s\n' '/usr/local/bin' '/usr/bin' '/bin' > "$_g/private/etc/paths"
  printf '%s\n' '/usr/local/share/man' '/usr/share/man' > "$_g/private/etc/manpaths"
  printf '%s\n' '=head1 NAME' 'Guest doc mentioning /usr/local, Apple own local prefix.' \
    > "$_g/usr/share/doc/guest.pod"
  printf '%s\n' '#define PREFIX "/usr/local"' > "$_g/usr/lib/perl/config.h"
  printf '%s\n' "_prefix = '/usr/local'" > "$_g/usr/lib/python/_sysconfigdata.py"
  printf '\177ELF\000/usr/local/libexec/darling\000guest\000' > "$_g/usr/lib/libguest.bin"
}

# prefix_host ROOT -- host-side files, the launcher's allowlisted fork stubs (4 of the 11 names
# check-prefix.sh allowlists), the T8 fix and the C19 escape.
prefix_host() {
  _root=$1
  mkdir -p "$_root/usr/lib/binfmt.d" "$_root/usr/share/darling" \
    "$_root/usr/lib/darling-lol/scripts" "$_root/usr/lib/darling-lol/tools" \
    "$_root/usr/share/doc/darling-lol" "$_root/usr/bin"
  printf '%s\n' ':darling:M::\xcf\xfa\xed\xfe::/usr/libexec/darling/usr/libexec/darling/mldr:P' \
    > "$_root/usr/lib/binfmt.d/darling.conf"
  printf '%s\n' 'prefix: /usr' > "$_root/usr/share/darling/build-info"
  printf '%s\n' '#!/bin/sh' '# fixture launcher' > "$_root/usr/bin/darling-lol"
  chmod 0755 "$_root/usr/bin/darling-lol"
  printf '%s\n' '# fixture README-packaging' > "$_root/usr/share/doc/darling-lol/README-packaging.md"
  # The 4 allowlisted fork stubs THIS FIXTURE writes -- 4 of the 10 fork files the gate allowlists;
  # the 11th allowlisted name is usr/bin/darling-lol (written above as a 2-line stub), and the 6
  # remaining tools (metal-presentation, x11-runtime, urlsession-check, the two riot checks that
  # turned run #67 red, and doctor.py) are not reproduced here.
  # Each stub keeps its literal /usr/local (PLAN §4.1). The allowlist itself lives in
  # check-prefix.sh's ALLOW_PATHS, never here (T8d).
  printf '%s\n' "return {'sdk': '/usr/local/libexec/darling'}" \
    > "$_root/usr/lib/darling-lol/scripts/common.py"
  printf '%s\n' 'sdk = "/usr/local/libexec/darling"' \
    > "$_root/usr/lib/darling-lol/tools/build-riot-power-assertion-check.py"
  printf '%s\n' 'sdk = "/usr/local/libexec/darling"' \
    > "$_root/usr/lib/darling-lol/tools/build-riot-power-notify-check.py"
  printf '%s\n' '"""Audit the SDK in /usr/local/libexec/darling."""' \
    > "$_root/usr/lib/darling-lol/tools/riot_overlay_audit.py"
  # T8-fixed installer: NO literal prefix (shutil.which-resolved). Deliberately NOT allowlisted,
  # so a regression here fails G-PREFIX-1 (mutation M7).
  cat > "$_root/usr/lib/darling-lol/tools/install-riot-darling-server.py" <<'PY'
import shutil
from pathlib import Path


def default_server_destination():
    found = shutil.which("darlingserver")
    return Path(found) if found else Path("/usr/bin/darlingserver")
PY
  # C19: the emulated drive escapes the tree; files.all must not walk through it.
  mkdir -p "$_root/usr/libexec/darling/Volumes"
  ln -s / "$_root/usr/libexec/darling/Volumes/DarlingEmulatedDrive"
  mkdir -p "$_root/usr/libexec/darling/private/tmp"
}

# prefix_files_all ROOT OUT -- identical to stage.sh step 3 (the gate is driven from this list).
prefix_files_all() {
  ( cd "$1" && find . \( ! -type d -o -type d -empty \) -printf '/%P\n' ) | LC_ALL=C sort > "$2"
}

prefix_main() {
  _dir=${1:?usage: mkprefixfixture.sh <dir>}
  _root="$_dir/root"
  rm -rf "$_root"
  mkdir -p "$_root"
  prefix_elfs "$_root"
  prefix_guest "$_root"
  prefix_host "$_root"
  prefix_files_all "$_root" "$_dir/files.all"
  printf 'mkprefixfixture: %s files all, %s host-side, %s guest\n' \
    "$(wc -l < "$_dir/files.all" | tr -d ' ')" \
    "$(sed 's|^/||' "$_dir/files.all" | grep -cvE '^usr/libexec/darling/' || true)" \
    "$(sed 's|^/||' "$_dir/files.all" | grep -cE '^usr/libexec/darling/' || true)"
}

if [ "${0##*/}" = "mkprefixfixture.sh" ]; then
  prefix_main "$@"
fi
