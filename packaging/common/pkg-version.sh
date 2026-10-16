#!/bin/sh
# packaging/common/pkg-version.sh -- single source of truth for the version of every format.
#
# PLAN §6. One derivation (git describe / an explicit tag), three renderings:
#   --deb   0.1.0+lol-1          deb-version(7): upstream part + "+lol-" vendor revision
#   --rpm   0.1.0-1.lol.fc41     Version=0.1.0, Release=1.lol%{?dist}
#   --arch  0.1.0-1              .PKGINFO pkgver MUST contain "-" or libalpm rejects it
#
# With no tag argument the tag is `git describe --tags --always`. A bare commit hash renders the
# development form (version 0.0.0 + a date-stamped release); an unrecognised string is a hard
# error (exit 1) -- never a silent 0.0.0. The package version is never hard-coded here.
#
# usage: pkg-version.sh [--deb|--rpm|--arch] [TAG]...
#   --deb|--rpm|--arch   render one format (takes exactly one TAG)
#   TAG...               no format flag: one TAG -> the plain version; several TAGs -> a TSV table
#                        with one row per tag (tag, plain, deb, rpm, arch)
set -eu

dist=${DIST:-fc41}
prog=${0##*/}
fmt=
tags=

for arg in "$@"; do
  case "$arg" in
    --deb|--rpm|--arch)
      if [ -n "$fmt" ]; then
        echo "$prog: FATAL more than one format flag ('$fmt' and '$arg')" >&2
        exit 2
      fi
      fmt=$arg
      ;;
    -h|--help)
      sed -n '2,17p' "$0"
      exit 0
      ;;
    -*)
      echo "$prog: FATAL unknown option '$arg'" >&2
      exit 2
      ;;
    *)
      tags="$tags $arg"
      ;;
  esac
done

[ -n "$tags" ] || tags=" $(git describe --tags --always 2>/dev/null || echo 0.0.0)"

# classify TAG -- print "<ver> <rel>" on success, return 1 for a string that is neither a version
# tag nor a commit hash. A git-describe suffix is stripped; a version must carry at least one dot
# (a bare hash does not), so `2d75d58` is a commit and `0.1.0` is a version.
classify() {
  _tag=$1
  case "$_tag" in
    v[0-9]* | [0-9]*) : ;;
    *) return 1 ;;
  esac
  _base=${_tag#v}
  case "$_base" in
    *.*)
      # PLAN §6: strip everything from the first "-" (a git-describe "-N-gHASH" suffix).
      printf '%s 1\n' "${_base%%-*}"
      ;;
    *)
      # A commit hash is 4+ hex characters and nothing else. Anything with a non-hex byte is a
      # typo, not a build: fail loudly rather than emit the development version for it.
      case "$_base" in
        *[!0-9a-f]*) return 1 ;;
        ????*) printf '0.0.0 0.dev%s\n' "$(date -u +%Y%m%d)" ;;
        *) return 1 ;;
      esac
      ;;
  esac
}

# format FMT VER REL -- one rendering of a derived version.
format() {
  case "$1" in
    --deb) printf '%s+lol-%s\n' "$2" "$3" ;;
    --rpm) printf '%s-%s.lol.%s\n' "$2" "$3" "$dist" ;;
    --arch) printf '%s-%s\n' "$2" "$3" ;;
  esac
}

# Word splitting over $tags is intended (and there are no glob metacharacters in a tag).
set -f
set -- $tags
set +f

if [ -n "$fmt" ]; then
  [ "$#" -eq 1 ] || { echo "$prog: FATAL $fmt takes exactly one tag" >&2; exit 2; }
  pair=$(classify "$1") || { echo "$prog: FATAL '$1' is not a version tag and not a commit hash" >&2; exit 1; }
  format "$fmt" "${pair%% *}" "${pair#* }"
  exit 0
fi

if [ "$#" -eq 1 ]; then
  pair=$(classify "$1") || { echo "$prog: FATAL '$1' is not a version tag and not a commit hash" >&2; exit 1; }
  printf '%s\n' "${pair%% *}"
  exit 0
fi

fail=0
for t in "$@"; do
  if pair=$(classify "$t"); then
    ver=${pair%% *}
    rel=${pair#* }
    printf '%s\t%s\t%s\t%s\t%s\n' "$t" "$ver" \
      "$(format --deb "$ver" "$rel")" \
      "$(format --rpm "$ver" "$rel")" \
      "$(format --arch "$ver" "$rel")"
  else
    echo "$prog: FATAL '$t' is not a version tag and not a commit hash" >&2
    fail=1
  fi
done
[ "$fail" = 0 ] || exit 1
