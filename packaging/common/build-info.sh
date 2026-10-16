#!/bin/sh
# packaging/common/build-info.sh -- provenance generator (PLAN §12.3).
#
# Extends the schema the /usr/local build already publishes -- 9 keys, EVIDENCE C17 -- with the
# packaging keys, so all four formats plus the release metadata describe one build in one shape.
# Every value comes from the environment or from the repository: nothing here is hard-coded per
# release. Missing environment values fall back to a repository-derived default, never to a
# literal version.
#
# usage: build-info.sh [OUTPUT]        (default: stdout)
#
# Environment (all optional): REPO COMMIT REF COMPONENTS INSTALL_MANIFEST INPUTS RUN DATE UNAME
#   PKG_PREFIX CMAKE_INSTALL_LIBDIR CMAKE_INSTALL_PREFIX DEB_COMPRESSION RPM_PAYLOAD
#   TAR_COMPRESSION UPSTREAM_PIN UPSTREAM_SUBMODULE PATCH RUNTIME_PATHS LAUNCHER_PATHS
#   INSTALLED_SIZE_KIB REFERENCE_DIFF_LINES
set -eu

out=${1:-/dev/stdout}

# val ENVVAR DEFAULT -- the environment value if set and non-empty, else DEFAULT.
val() {
  eval "_pv=\${$1:-}"
  if [ -n "${_pv:-}" ]; then printf '%s' "$_pv"; else printf '%s' "$2"; fi
}

# count_or FILE -- the integer in FILE with surrounding whitespace stripped, or "unknown".
count_or() {
  if [ -r "$1" ]; then tr -d ' \t\n' < "$1"; else printf 'unknown'; fi
}

repo=$(val REPO "$(git config --get remote.origin.url 2>/dev/null || echo unknown)")
{
  printf 'repo: %s\n' "$repo"
  printf 'commit: %s\n' "$(val COMMIT "$(git rev-parse HEAD 2>/dev/null || echo unknown)")"
  printf 'ref: %s\n' "$(val REF "$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)")"
  printf 'components: %s\n' "$(val COMPONENTS stock)"
  printf 'install-manifest: %s\n' "$(val INSTALL_MANIFEST unknown)"
  printf 'inputs: %s\n' "$(val INPUTS unknown)"
  printf 'run: %s\n' "$(val RUN local)"
  printf 'date: %s\n' "$(val DATE "$(date -u +%Y-%m-%dT%H:%M:%SZ)")"
  printf 'uname: %s\n' "$(val UNAME "$(uname -a)")"
  printf '# --- added by the packaging job ---\n'
  printf 'prefix: %s\n' "$(val PKG_PREFIX /usr)"
  printf 'cmake-install-libdir: %s\n' "$(val CMAKE_INSTALL_LIBDIR lib)"
  printf 'cmake-install-prefix: %s\n' "$(val CMAKE_INSTALL_PREFIX "$(val PKG_PREFIX /usr)")"
  printf 'deb-compression: %s\n' "$(val DEB_COMPRESSION xz)"
  printf 'rpm-payload: %s\n' "$(val RPM_PAYLOAD w19T.zstd)"
  printf 'tar-compression: %s\n' "$(val TAR_COMPRESSION 'zstd -19 -T0')"
  printf 'upstream-pin: %s\n' "$(val UPSTREAM_PIN unknown)"
  printf 'upstream-submodule-darlingserver: %s\n' "$(val UPSTREAM_SUBMODULE unknown)"
  printf 'patch: %s\n' "$(val PATCH patches/darling.patch)"
  printf 'runtime-paths: %s\n' "$(val RUNTIME_PATHS "$(count_or dist/pkg/count.runtime)")"
  printf 'launcher-paths: %s\n' "$(val LAUNCHER_PATHS "$(count_or dist/pkg/count.launcher)")"
  printf 'installed-size-kib: %s\n' "$(val INSTALLED_SIZE_KIB "$(count_or dist/pkg/installed-size-kib)")"
  printf 'reference-manifest-diff-lines: %s\n' "$(val REFERENCE_DIFF_LINES 0)"
} > "$out"
