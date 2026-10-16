#!/bin/sh
# packaging/common/render.sh -- one dependency list -> three syntaxes, plus template rendering.
#
# PLAN §8.4/§9.1/§10/§11.1. The deb control.in, the rpm *.spec.in and the Arch PKGINFO.in carry
# @TOKEN@ placeholders; this script is the single place that fills them, so that no dependency
# string is ever hand-copied into a template. The dependency lists (deps.<family>, conflicts.txt)
# are the source of truth; the version comes from pkg-version.sh (never hard-coded here).
#
#   deb  : @DEPS@       -> one "- "-joined Depends line        ; @CONFLICTS@ -> comma list
#   rpm  : @RPM_REQUIRES@ -> one "Requires: <entry>" per entry  ; @RPM_CONFLICTS@ -> space list
#   arch : @ARCH_DEPENDS@ -> one "depend = <entry>" per entry   ; @ARCH_CONFLICTS@ -> conflict =
#
# It refuses to emit a stream that still contains an @TOKEN@ or an unexpanded ${binary:Version}:
# that would be a silent, installable bug, not a build error (G-STATIC-4).
#
# usage: render.sh --family {deb|rpm|arch} [--release R] [--tag TAG] [--fixture | TEMPLATE]
set -eu

dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
prog=${0##*/}

family=
release=
tag=
installed_size=
launcher_installed_size=
maintainer="darling-lol maintainers"
fixture=0
template=

while [ "$#" -gt 0 ]; do
  case "$1" in
    --family) family=${2:?--family needs a value}; shift 2 ;;
    --release) release=${2:?--release needs a value}; shift 2 ;;
    --tag) tag=${2:?--tag needs a value}; shift 2 ;;
    --installed-size) installed_size=${2:?--installed-size needs a value}; shift 2 ;;
    --launcher-installed-size) launcher_installed_size=${2:?--launcher-installed-size needs a value}; shift 2 ;;
    --maintainer) maintainer=${2:?--maintainer needs a value}; shift 2 ;;
    --fixture) fixture=1; shift ;;
    -h | --help) sed -n '2,18p' "$0"; exit 0 ;;
    -*) echo "$prog: FATAL unknown option '$1'" >&2; exit 2 ;;
    *) template=$1; shift ;;
  esac
done

case "$family" in
  deb | rpm | arch) : ;;
  "") echo "$prog: FATAL --family is required (deb|rpm|arch)" >&2; exit 2 ;;
  *) echo "$prog: FATAL unknown family '$family'" >&2; exit 2 ;;
esac
if [ "$fixture" = 1 ] && [ -n "$template" ]; then
  echo "$prog: FATAL --fixture and a TEMPLATE path are mutually exclusive" >&2
  exit 2
fi

case "$family" in
  deb) deps_file="$dir/deps.deb.${release:-noble}" ;;
  rpm) deps_file="$dir/deps.rpm.${release:-fc41}" ;;
  arch) deps_file="$dir/deps.arch" ;;
esac
[ -r "$deps_file" ] || { echo "$prog: FATAL missing dependency list $deps_file" >&2; exit 2; }
[ -r "$dir/conflicts.txt" ] || { echo "$prog: FATAL missing $dir/conflicts.txt" >&2; exit 2; }

# --- version: one derivation (pkg-version.sh), the family renderings -------------
tag=${tag:-$(git describe --tags --always 2>/dev/null || echo 0.0.0)}
plain=$(sh "$dir/pkg-version.sh" "$tag")
deb_ver=$(sh "$dir/pkg-version.sh" --deb "$tag")
rpm_ver=$plain
rpm_full=$(sh "$dir/pkg-version.sh" --rpm "$tag")
rpm_rel=${rpm_full#"$rpm_ver"-}
arch_ver=$plain
arch_full=$(sh "$dir/pkg-version.sh" --arch "$tag")
arch_rel=${arch_full#"$plain"-}

# --- dependency + conflict renderings -----------------------------------------------------
deps_clean() {
  # One entry per line. An inline `#` comment is stripped first: PLAN §8.1 prints the dependency
  # lists *with* them (e.g. `libfuse2   # <- noble calls this libfuse2t64`), so the shown snippet
  # must be a legal input to this renderer rather than a string that leaks into `Depends`. No
  # dependency syntax in any of the three families contains `#`. Then drop the now-empty lines and
  # any trailing blanks.
  sed 's/[[:space:]]*#.*$//; s/[[:space:]]*$//' "$1" | grep -v '^[[:space:]]*$' || true
}
case "$family" in
  deb)
    deps_body=$(deps_clean "$deps_file" | paste -sd, - | sed 's/,/, /g')
    conflicts_body=$(deps_clean "$dir/conflicts.txt" | paste -sd, - | sed 's/,/, /g')
    ;;
  rpm)
    deps_body=$(deps_clean "$deps_file" | sed 's/^/Requires: /')
    conflicts_body=$(deps_clean "$dir/conflicts.txt" | paste -sd' ' -)
    ;;
  arch)
    deps_body=$(deps_clean "$deps_file" | sed 's/^/depend = /')
    conflicts_body=$(deps_clean "$dir/conflicts.txt" | sed 's/^/conflict = /')
    ;;
esac

installed_size=${installed_size:-0}
launcher_installed_size=${launcher_installed_size:-0}
build_epoch=$(date -u +%s)
installed_bytes=$((installed_size * 1024))
rpm_conflicts=$(deps_clean "$dir/conflicts.txt" | paste -sd' ' -)
arch_opts='optdepend = ffmpeg6: for libavcodec.so.60 audio/video wrappers'
arch_provides="provides = darling-lol=$arch_ver"

# --- token table: written to files so multi-line values survive awk -v ---------------------
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

set_tok() { printf '%s' "$2" > "$tmp/$1"; }
set_tok VERSION "$deb_ver"
set_tok DEPS "$deps_body"
set_tok CONFLICTS "$conflicts_body"
set_tok INSTALLED_SIZE "$installed_size"
set_tok LAUNCHER_INSTALLED_SIZE "$launcher_installed_size"
set_tok MAINTAINER "$maintainer"
set_tok RPM_VERSION "$rpm_ver"
set_tok RPM_RELEASE "$rpm_rel"
set_tok RPM_REQUIRES "$deps_body"
set_tok RPM_CONFLICTS "$rpm_conflicts"
set_tok ARCH_PKGVER "$arch_ver"
set_tok ARCH_PKGREL "$arch_rel"
set_tok ARCH_DEPENDS "$deps_body"
set_tok ARCH_OPTDEPENDS "$arch_opts"
set_tok ARCH_CONFLICTS "$conflicts_body"
set_tok ARCH_PROVIDES "$arch_provides"
set_tok BUILD_EPOCH "$build_epoch"
set_tok INSTALLED_BYTES "$installed_bytes"

# --- template source ----------------------------------------------------------------------
if [ "$fixture" = 1 ]; then
  case "$family" in
    deb)
      template=$tmp/fixture.in
      cat > "$template" <<'EOF'
Package: darling-lol
Version: @VERSION@
Section: contrib/games
Priority: optional
Architecture: amd64
Maintainer: @MAINTAINER@
Homepage: https://github.com/QuinsZouls/darling-lol
Depends: @DEPS@
Conflicts: @CONFLICTS@
Installed-Size: @INSTALLED_SIZE@
Description: fixture control file rendered by render.sh --fixture
 Exists only so the renderer's output can be checked for leftover
 placeholders (G-STATIC-4) and for dependency drift (G-STATIC-5).
EOF
      ;;
    rpm)
      template=$tmp/fixture.in
      cat > "$template" <<'EOF'
Name:           darling-lol
Version:        @RPM_VERSION@
Release:        @RPM_RELEASE@
Summary:        fixture spec rendered by render.sh --fixture
License:        GPL-3.0-or-later
AutoReqProv:    no
Conflicts:      @RPM_CONFLICTS@
@RPM_REQUIRES@
Recommends:     ffmpeg-libs
%description
 fixture
%files
%defattr(-,root,root,-)
EOF
      ;;
    arch)
      template=$tmp/fixture.in
      cat > "$template" <<'EOF'
pkgname = darling-lol
pkgbase = darling-lol
pkgver = @ARCH_PKGVER@-@ARCH_PKGREL@
pkgdesc = fixture PKGINFO rendered by render.sh --fixture
url = https://github.com/QuinsZouls/darling-lol
builddate = @BUILD_EPOCH@
packager = darling-lol CI
size = @INSTALLED_BYTES@
arch = x86_64
license = GPL-3.0-or-later
@ARCH_DEPENDS@
@ARCH_OPTDEPENDS@
@ARCH_CONFLICTS@
@ARCH_PROVIDES@
EOF
      ;;
  esac
elif [ -z "$template" ]; then
  echo "$prog: FATAL no template given (use --fixture or a TEMPLATE path)" >&2
  exit 2
fi
[ -r "$template" ] || { echo "$prog: FATAL cannot read template $template" >&2; exit 2; }

# --- render --------------------------------------------------------------------------------
out=$tmp/out
awk -v dir="$tmp" '
  function lit(s, from, to,   out, i, lf) {
    lf = length(from)
    if (lf == 0) return s
    out = ""
    i = index(s, from)
    while (i > 0) {
      out = out substr(s, 1, i - 1) to
      s = substr(s, i + lf)
      i = index(s, from)
    }
    return out s
  }
  BEGIN {
    n = split("VERSION DEPS CONFLICTS INSTALLED_SIZE LAUNCHER_INSTALLED_SIZE MAINTAINER \
RPM_VERSION RPM_RELEASE RPM_REQUIRES RPM_CONFLICTS ARCH_PKGVER ARCH_PKGREL ARCH_DEPENDS \
ARCH_OPTDEPENDS ARCH_CONFLICTS ARCH_PROVIDES BUILD_EPOCH INSTALLED_BYTES", names, " ")
    for (i = 1; i <= n; i++) {
      v = ""
      while ((getline l < (dir "/" names[i])) > 0) v = v (v == "" ? "" : "\n") l
      close(dir "/" names[i])
      tok["@" names[i] "@"] = v
    }
  }
  {
    line = $0
    for (k in tok) line = lit(line, k, tok[k])
    line = lit(line, "${binary:Version}", tok["@VERSION@"])
    print line
  }
' "$template" > "$out"

# --- refuse to emit an unexpanded token -----------------------------------------------------
if grep -qE '@[A-Za-z_]+@' "$out" || grep -qF '${binary:Version}' "$out"; then
  echo "$prog: FATAL unexpanded token remains in the rendered $family output:" >&2
  grep -nE '@[A-Za-z_]+@|\$\{binary:Version\}' "$out" >&2 || true
  exit 1
fi
cat "$out"
