#!/bin/sh
# packaging/common/exclude.sh -- what must NOT reach the staging tree, and what must (PLAN §13.2).
#
# Runs against the DESTDIR staging tree before any file list is generated. Four rules:
#   1. Build-machine leakage: 13 rendered tool files contain /home/runner or /Users/runner. We
#      ship templates instead (PLAN §14), so nothing rendered is ever staged -- this guards the
#      case where a rendered file sneaks in anyway.
#   2. cmake's own leftovers inside the prefix (*/lib/cmake/*.cmake).
#   3. The known-missing manifest entry must not be synthesised (EVIDENCE C17).
#   4. Reject, do not silently drop: a build-path leak into a host binary is a bug in the build.
#
# Exclude.sh removes NOTHING else. Kept deliberately (each verified to survive deb+rpm+tar,
# EVIDENCE C15): the 37 dangling guest symlinks, the 51 empty directories, the 15 .localized
# files, private/etc/resolv.conf (plain 0644, C5) and private/tmp (as a directory entry).
#
# usage: exclude.sh [ROOT] [OUT]      (defaults: dist/pkg/root, dist/pkg)
set -eu

root=${1:-dist/pkg/root}
out=${2:-dist/pkg}

[ -d "$root" ] || { echo "exclude: FATAL $root does not exist" >&2; exit 2; }

# 1 + 2. cmake package-config leftovers inside the prefix. Removing them is safe: nothing in the
# installed tree consumes a *-config.cmake after the DESTDIR install.
if [ -n "$(find "$root" -path '*/lib/cmake/*' -name '*.cmake' -print -quit 2>/dev/null)" ]; then
  find "$root" -path '*/lib/cmake/*' -name '*.cmake' -print0 | xargs -0 -r rm -f --
fi

# 2b. Prune ONLY what the removal above leaves behind: the now-empty <pkg> directories and the
#     lib/cmake container itself. Without this, stage.sh's files.emptydirs (step 3) would ship the
#     empty directories of a build-system remnant as package content. The 51 empty directories the
#     SDK legitimately ships (PLAN §13.2, C15) are NOT matched by these two patterns and stay.
find "$root" -depth -type d -empty \( -path '*/lib/cmake' -o -path '*/lib/cmake/*' \) -delete 2>/dev/null || true

# 3. The known-missing manifest entry is NOT synthesised. `if`, not `cond && echo`: under `set -e`
#    a failing AND-list at statement level is a footgun (PLAN §4.1 says exactly this).
if [ -f "$out/missing-installed-files.txt" ] && \
   grep -q 'install-bin' "$out/missing-installed-files.txt"; then
  echo "exclude: note: usr/libexec/darling/usr/bin/install-bin is absent upstream; not synthesised"
fi

# 4. A build-path leak into a *host* binary is a bug, not something to drop silently.
#    `grep -r`, not `-R`, on purpose (C19): -r does not descend a symlink, so
#    usr/libexec/darling/Volumes/DarlingEmulatedDrive -> / cannot walk this out of the tree and
#    grep the host. Do not "fix" this to -R.
leaks=$(grep -rla '/home/runner' "$root/usr/bin" "$root/usr/libexec/darling/usr/libexec" 2>/dev/null || true)
if [ -n "$leaks" ]; then
  echo "exclude: FATAL build-path leak into a host binary:" >&2
  printf '%s\n' "$leaks" >&2
  exit 1
fi

echo "exclude: OK"
