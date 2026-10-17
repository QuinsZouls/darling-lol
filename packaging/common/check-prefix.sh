#!/bin/sh
# packaging/common/check-prefix.sh (NEW) -- run by stage.sh step 3b, over dist/pkg/root.
# Physical mode only: the payload contains Volumes/DarlingEmulatedDrive -> / (C19), so a
# recursive `grep -R` escapes the tree and greps the host. Never use -R here.
#
# `--print-allowlist` prints, one path per line, the exact payload paths this sweep tolerates. It
# is the MACHINE-READABLE form of the allowlist (T8d/MINOR-2): packaging/testdata/launch-harness.sh
# compares the staged tree's /usr/local hits against THIS output as a set, so the allowlist has
# exactly one home and a future upstream merge cannot put the harness out of step with the gate.
set -eu

# The allowlist. ONE list, two consumers (the sweep and --print-allowlist), so they cannot drift.
# Every entry is exempt by EXACT PATH, never by wildcard -- a wildcard would exempt every future
# tool. Every entry must be a READER of a prefix, never a write target; the reason per file is
# recorded here and in the sweep below:
#   usr/bin/darling-lol -- the launcher entry point. Exempt by name, but ONLY for its documented
#     fallback candidates: see (a2), which is T8d/MINOR-3.
#   usr/lib/darling-lol/scripts/common.py -- the fork's sdk default (a fallback; --sdk overrides).
#   usr/lib/darling-lol/tools/build-riot-power-{assertion,notify}-check.py -- the same fallback: it
#     fires only when build/config.json is absent, and the wrapper always renders config.json
#     first.
#   usr/lib/darling-lol/tools/build-riot-{metal-presentation,x11-runtime}.py -- the SAME fallback
#     as those two twins (R-2): a /usr/local/libexec/darling path that is dead once config.json
#     exists, not a write target.
#   usr/lib/darling-lol/tools/build-riot-urlsession-check.py -- the same FALLBACK-reader class as
#     the two power checks above. NEW on upstream main: the merge added it to the verbatim-staged
#     tools/, which is what turned G-PREFIX-1 red (T8c).
#   usr/lib/darling-lol/tools/riot_overlay_audit.py -- prose in a docstring.
# install-riot-darling-server.py is deliberately NOT allowlisted: T1 removed its literal, so a
# regression there must fail this gate (mutation M7 -- it WAS a write target, i.e. a live bug).
ALLOW_PATHS='
usr/bin/darling-lol
usr/lib/darling-lol/scripts/common.py
usr/lib/darling-lol/tools/build-riot-power-assertion-check.py
usr/lib/darling-lol/tools/build-riot-power-notify-check.py
usr/lib/darling-lol/tools/build-riot-metal-presentation.py
usr/lib/darling-lol/tools/build-riot-x11-runtime.py
usr/lib/darling-lol/tools/build-riot-urlsession-check.py
usr/lib/darling-lol/tools/riot_overlay_audit.py
'

case "${1:-}" in
  --print-allowlist) for p in $ALLOW_PATHS; do printf '%s\n' "$p"; done; exit 0 ;;
  -h|--help)         echo "usage: $0 [--print-allowlist] [ROOT [LIST]]"; exit 0 ;;
  -*)                echo "check-prefix: unknown option '$1' (try --print-allowlist)" >&2; exit 2 ;;
esac

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
#     files.all also lists EMPTY DIRECTORIES (stage.sh step 3); `grep -d skip` drops those rows
#     silently. That is the ONLY diagnostic this sweep is allowed to suppress -- see (a3).
sed 's|^/||' "$list" | grep -vE '^usr/libexec/darling/' > "$root.host.paths"

# (a1) THE EXEMPTION IS APPLIED TO THE LIST, BY EXACT PATH -- never to grep's `file:lineno:content`
#      output (T8d/MINOR-1). grep's trailing `:` is its own field separator, so the old
#      `grep -vE '^(…allowlisted…):'` also matched a file whose NAME continued with `:` after an
#      allowlisted path: `usr/bin/darling-lol:evil` yields `usr/bin/darling-lol:evil:1:…`, which
#      the old pattern exempted (measured: rc 0 / `PREFIX: OK` with a /usr/local literal in the
#      tree). Matching the path FIELD itself cannot be confused with a line number, whatever the
#      file is called. `grep -Fx -f` = whole-line, fixed-string, by name.
: > "$root.allow.names"
for p in $ALLOW_PATHS; do printf '%s\n' "$p" >> "$root.allow.names"; done
grep -vxF -f "$root.allow.names" "$root.host.paths" > "$root.host.scan" || true

if [ -s "$root.host.scan" ]; then
  # -I: the host ELFs are binary and must be skipped by the TEXT sweep (strings(1) checks them
  #     in (c)/(d)). -H: always print the path, even for a single file, so the report is uniform.
  ( cd "$root" && tr '\n' '\0' < "$root.host.scan" \
      | xargs -0 -r grep -InH -d skip 'usr/local' ) > "$root.host.hits" 2> "$root.host.err" || true
  if [ -s "$root.host.hits" ]; then
    echo "PREFIX: FATAL unexplained host-side /usr/local references:" >&2
    head -20 "$root.host.hits" >&2
    fail=1
  fi
  # (a3) FAIL CLOSED (T8d/MINOR-4). The old pipeline ended in `2>/dev/null`, which swallowed
  #      grep's READ errors as well as the intended directory noise: a listed path grep cannot
  #      open (EACCES on a mode-000 file, ENOENT from a filename that a newline splits across two
  #      files.all lines) was never scanned and the gate still printed `PREFIX: OK`. `-d skip`
  #      already removes the one noise source, so ANY line left on stderr is a real read error and
  #      must fail the gate -- an unreadable payload is not a clean payload.
  if [ -s "$root.host.err" ]; then
    echo "PREFIX: FATAL the host-side sweep could not read every path files.all lists:" >&2
    head -20 "$root.host.err" >&2
    fail=1
  fi
fi

# (a2) usr/bin/darling-lol is exempt from the sweep above, but exempting the whole FILE was
#      content-blind (T8d/MINOR-3): a future write target added into the wrapper -- the same class
#      as install-riot-darling-server.py, which is deliberately kept off the allowlist -- would
#      have passed silently. Its /usr/local occurrences may now only be (i) on a comment line (the
#      prose that documents the detected prefix) or (ii) one of the three documented
#      fallback-candidate literals, as a WHOLE token, on a line that carries no write operator and
#      no file-mutating command.
#      So /usr/local/bin/darlingserver, a traversal out of a documented literal, a new list entry,
#      `> /usr/local/...` or `cp -a x /usr/local/share/darling-lol` all FATAL now (the three
#      literals are exactly the candidates the wrapper's SDK_CANDIDATES / TEMPLATES lists test for;
#      the current wrapper names them on 4 non-comment lines, so the rule is a SET MEMBERSHIP check
#      on the tokens, never a count -- a count would rot).
#      Residual, deliberately documented rather than hidden: a write whose target is an INDIRECTION
#      through a QUOTED bare token -- `D="/usr/local/share/darling-lol"` on one line, `mkdir -p
#      "$D"` on another -- is not separable from a list element by content alone, because the token
#      the sweep compares IS the bare literal either way. That is acceptable because the file is
#      generated from packaging/install/darling-lol.in, which this repo owns, and G-LAUNCH-1
#      R2/R2b pin the staged wrapper to that template's render byte for byte: such a line must be
#      added to the template in a reviewed commit, and every shape the template language uses for a
#      write in place (redirection, pipe, command substitution, file-mutating command, decorated or
#      unquoted literal token, traversal) fails closed here.
wrap=$root/usr/bin/darling-lol
if [ -f "$wrap" ]; then
  wrap_lines=$(grep -an 'usr/local' "$wrap" 2> "$root.wrap.err") || true
  if [ -s "$root.wrap.err" ]; then
    echo "PREFIX: FATAL could not read usr/bin/darling-lol:" >&2
    head -5 "$root.wrap.err" >&2
    fail=1
  fi
  # -a so a binary wrapper cannot hide behind "Binary file … matches"; -n to name the line.
  wrap_code=$(printf '%s\n' "$wrap_lines" | grep -vE '^[0-9]+:[[:space:]]*#' || true)
  wrap_leaks=$(printf '%s\n' "$wrap_code" \
      | grep -oE '[^[:space:]"\\|()<>;&]*usr/local[^[:space:]"\\|()<>;&]*' \
      | grep -vxE '(/usr/local/(libexec/darling|lib/darling-lol|share/darling-lol))' || true)
  # The three rules below are what "no write target" means operationally. A line whose only job is
  # to test a fallback candidate matches NONE of them; the real wrapper's `for t in …
  # /usr/local/share/darling-lol` and its SDK_CANDIDATES list match none of them either.
  #   - wrap_writes: a write OPERATOR anywhere on the line (redirection, pipe, command substitution,
  #     backtick) -- `> /usr/local/...` cannot be a candidate test.
  #   - wrap_cmds: a file-MUTATING command on the line, whatever its arguments. `:` is in the
  #     separator class because these lines are `grep -n` output (`128:cp …`), so the path FIELD,
  #     not the line start, precedes the command -- a `^`-only anchor would miss every hit.
  wrap_writes=$(printf '%s\n' "$wrap_code" | grep -E '[<>]|[|]|\$\(|`' || true)
  wrap_cmds=$(printf '%s\n' "$wrap_code" \
      | grep -E '(^|[[:space:];&(){}:])(cp|mv|rm|install|mkdir|ln|dd|tee|touch|truncate|chmod|chown)([[:space:]]|$)' || true)
  if [ -n "$wrap_leaks$wrap_writes$wrap_cmds" ]; then
    echo "PREFIX: FATAL usr/bin/darling-lol names /usr/local outside a documented fallback candidate" >&2
    echo "        (only SDK_CANDIDATES / TEMPLATES and their prose, with no write operator or command):" >&2
    { printf '%s\n' "$wrap_leaks"; printf '%s\n' "$wrap_writes"; printf '%s\n' "$wrap_cmds"; } \
      | grep -v '^$' | head -20 >&2
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
# 🚨 This exact count is an INTENTIONAL pin, kept and not de-rotted (NIT-2 disposition): it is
# evidence-based -- C23 measured the three guest literals of darling.c (dirs[] /usr/local,
# dirs[] /usr/local/share, the guest PATH) on the published v0.1.0 ELFs -- and it is the assertion
# that catches a blanket `sed s#/usr/local#/usr#g` (mutation M3). A future upstream change to that
# array must update this number in the same commit, deliberately.
nloc=$(strings -a "$root/usr/bin/darling" | grep -c '/usr/local' || true)
if [ "$nloc" -ne 3 ]; then
  echo "PREFIX: FATAL usr/bin/darling has $nloc '/usr/local' strings, expected exactly 3 (guest literals)"; fail=1
fi

# (e) report the guest count; a large drift means someone rewrote the SDK. Report only: 2>/dev/null
#     is fine HERE (the count is not an assertion, and the empty-directory rows would add noise).
n=$(cd "$root" && printf '%s\n' "$guest_hits" | tr '\n' '\0' \
      | xargs -0 -r grep -Il 'usr/local' 2>/dev/null | wc -l)
echo "PREFIX: guest-side files containing 'usr/local' = $n (expected ~310 text; not a failure)"
rm -f "$root.host.paths" "$root.host.scan" "$root.host.hits" "$root.host.err" \
      "$root.allow.names" "$root.wrap.err"
[ "$fail" = 0 ] || exit 1
echo "PREFIX: OK"
