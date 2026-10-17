#!/bin/sh
# packaging/common/check-prefix.sh (NEW) -- run by stage.sh step 3b, over dist/pkg/root.
# Physical mode only: the payload contains Volumes/DarlingEmulatedDrive -> / (C19), so a
# recursive `grep -R` escapes the tree and greps the host. Never use -R here.
set -eu
root=${1:-dist/pkg/root}; list=${2:-dist/pkg/files.all}

# Guard: every pattern below is written against the PACKAGED (/usr) layout. Running this against
# a /usr/local tree does not silently pass -- it says so. (stage.sh step 1 already asserts the
# prefix; this is here so the script is safe to run by hand.) `if` form, not `[ ] && { }`: under
# `set -e` a failing AND-list at statement level is a footgun worth not relying on.
if [ ! -d "$root/usr/libexec/darling" ]; then
  echo "PREFIX: FATAL $root is not a /usr staging tree (usr/libexec/darling missing)" >&2; exit 2
fi
if [ -e "$root/usr/local" ]; then
  echo "PREFIX: FATAL $root/usr/local exists -- wrong CMAKE_INSTALL_PREFIX" >&2; exit 2
fi

# (a) HOST-SIDE TEXT must be clean. Scope = everything the packages own that is NOT inside the
#     guest SDK. The guest-side sweep is (b)/(e) below and is a report, never a failure.
# (b) GUEST-SIDE hits are expected and counted, never rewritten: /usr/local is Apple's own
#     local prefix there (362 files measured at v0.1.0, EVIDENCE C19).
guest_hits=$(sed 's|^/||' "$list" | grep -E '^usr/libexec/darling/' || true)

fail=0
# (a) the host-side sweep: bin/, lib/binfmt.d/, share/, lib/darling-lol/ -- text only.
#     files.all also lists EMPTY DIRECTORIES (stage.sh step 3), so grep's "Is a directory"
#     warning must be suppressed or the log drowns (measured: 3 600+ lines of noise).
sed 's|^/||' "$list" | grep -vE '^usr/libexec/darling/' > "$root.host.paths"
if [ -s "$root.host.paths" ]; then
  ( cd "$root" && tr '\n' '\0' < "$root.host.paths" \
      | xargs -0 -r grep -In 'usr/local' 2>/dev/null ) > "$root.host.hits" || true
  # The ONLY allowed host-side text hits are the launcher's 7 allowlisted fork files (PLAN 4.1).
  # One line of reason per file; every one of them is a READER of a prefix, never a write target:
  #   usr/bin/darling-lol -- the launcher entry point. Its /usr/local strings are the FALLBACK
  #     candidate prefixes (the published tarball's prefix) and the documentation of them; they
  #     are what G-LAUNCH-1 cases A/C2/D exercise, so they cannot be removed. Measured: the 6
  #     paths R-2 prices are not enough -- this file is in the tree and is swept.
  #   scripts/common.py:9 -- the fork's sdk default (a fallback; --sdk overrides it).
  #   tools/build-riot-power-{assertion,notify}-check.py:10 -- same fallback: it fires only when
  #     build/config.json is absent, and the wrapper always renders config.json first.
  #   tools/build-riot-{metal-presentation,x11-runtime}.py:9-10 -- the SAME fallback as those two
  #     twins (R-2): a /usr/local/libexec/darling path that is dead once config.json exists, not a
  #     write target. Path-exact, by name: the allowlist cannot inspect content, so a wildcard here
  #     would exempt every future tool.
  #   tools/riot_overlay_audit.py:9 -- prose in a docstring.
  # install-riot-darling-server.py is deliberately NOT allowlisted: T1 removed its literal, so a
  # regression there must fail this gate (mutation M7 -- it WAS a write target, i.e. a live bug).
  if grep -vE '^(usr/bin/darling-lol|usr/lib/darling-lol/(scripts/common\.py|tools/((build-riot-power-(assertion|notify)-check|build-riot-(metal-presentation|x11-runtime))\.py|riot_overlay_audit\.py))):' \
       "$root.host.hits" | grep -q .; then
    echo "PREFIX: FATAL unexplained host-side /usr/local references:" >&2
    grep -vE '^(usr/bin/darling-lol|usr/lib/darling-lol/(scripts/common\.py|tools/((build-riot-power-(assertion|notify)-check|build-riot-(metal-presentation|x11-runtime))\.py|riot_overlay_audit\.py))):' \
      "$root.host.hits" | head -20 >&2
    fail=1
  fi
fi
# (c) the compiled prefix must be /usr. This is the assertion that actually proves D1 worked --
#     the text sweep cannot see inside a binary.
#     🚨 It is PER-BINARY, not a uniform loop over the three (C23). Measured on the published
#     v0.1.0 ELFs, the three do NOT carry the same prefix strings:
#       darlingserver    /usr/local/libexec/darling   x3 (1 standalone + 2 concatenated)
#       darling-coredump /usr/local/libexec/darling   x1
#       darling          /usr/local/bin/darlingserver x1  <-- and NO libexec string at all
#     A loop asserting LIBEXEC_PATH on `darling` fails a CORRECT /usr build (it was written that
#     way in an earlier draft of this plan, and the fixture run caught it -- EVIDENCE §7.5).
for b in usr/bin/darlingserver usr/bin/darling-coredump; do
  # substring, not -x: darlingserver bakes LIBEXEC_PATH 3x, twice concatenated with a guest path
  # ("mldr!" LIBEXEC_PATH "/usr/libexec/darling/vchroot", darlingserver.cpp:271), so an exact-line
  # match would see only 1 of the 3 and miss a partial regression.
  if strings -a "$root/$b" | grep -q '/usr/local/libexec/darling'; then
    echo "PREFIX: FATAL $b still has LIBEXEC_PATH=/usr/local/libexec/darling"; fail=1
  fi
  strings -a "$root/$b" | grep -qx '/usr/libexec/darling' \
    || { echo "PREFIX: FATAL $b does not have LIBEXEC_PATH=/usr/libexec/darling"; fail=1; }
done
# `darling`'s ONLY prefix-derived string is INSTALL_PREFIX "/bin/darlingserver" (darling.c:820;
# INSTALL_PREFIX comes from src/startup/CMakeLists.txt:15
#   add_definitions(-DINSTALL_PREFIX="${CMAKE_INSTALL_PREFIX}" ...)).
if strings -a "$root/usr/bin/darling" | grep -qx '/usr/local/bin/darlingserver'; then
  echo "PREFIX: FATAL usr/bin/darling still execl()s /usr/local/bin/darlingserver"; fail=1
fi
strings -a "$root/usr/bin/darling" | grep -qx '/usr/bin/darlingserver' \
  || { echo "PREFIX: FATAL usr/bin/darling does not execl() /usr/bin/darlingserver"; fail=1; }

# (d) the guest-side literals that MUST survive a prefix change. All three live in usr/bin/darling
#     and all three are Apple's, not ours (C23):
#       /usr/local                              darling.c:991  dirs[] -- created INSIDE the container
#       /usr/local/share                        darling.c:992  dirs[] -- same
#       PATH=/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin   darling.c:592-598 -- the GUEST's PATH
#     A blanket `sed s#/usr/local#/usr#g` over the staging tree deletes all three and produces a
#     runtime whose ~/.darling skeleton is missing /usr/local/share and whose guest PATH is wrong.
for s in '/usr/local' '/usr/local/share' 'PATH=/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin'; do
  strings -a "$root/usr/bin/darling" | grep -qxF "$s" \
    || { echo "PREFIX: FATAL darling guest literal '$s' was rewritten -- guest prefix skeleton/PATH broken"; fail=1; }
done
# and the count: a correct /usr build leaves EXACTLY 3 '/usr/local' substrings in `darling`
# (the 4th, /usr/local/bin/darlingserver, is the one that must have moved).
nloc=$(strings -a "$root/usr/bin/darling" | grep -c '/usr/local' || true)
if [ "$nloc" -ne 3 ]; then
  echo "PREFIX: FATAL usr/bin/darling has $nloc '/usr/local' strings, expected exactly 3 (guest literals)"; fail=1
fi

# (e) report the guest count; a large drift means someone rewrote the SDK.
n=$(cd "$root" && printf '%s\n' "$guest_hits" | tr '\n' '\0' \
      | xargs -0 -r grep -Il 'usr/local' 2>/dev/null | wc -l)
echo "PREFIX: guest-side files containing 'usr/local' = $n (expected ~310 text; not a failure)"
rm -f "$root.host.paths" "$root.host.hits"
[ "$fail" = 0 ] || exit 1
echo "PREFIX: OK"
