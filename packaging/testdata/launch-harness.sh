#!/bin/bash
# packaging/testdata/launch-harness.sh -- G-LAUNCH-1, the launcher gate (T8).
#
# Runs INSIDE a container as real root: it writes /usr and /usr/local, chmods 4755 and creates a
# 1001 user. Nothing here EXECUTES the x86-64 runtime -- the published ELFs are only grep'd and
# byte-patched, which is architecture-independent, so the gate is meaningful on an arm64 box.
#
# Fixture: the REAL published v0.1.0 host ELFs (/usr-prefixed by launch-mkusr.py, a
# length-preserving NUL-padded byte patch) -- which makes it a HARDER input than a real build
# would be, because the concatenated literals keep /usr/local, so both prefixes are present as
# substrings in one binary (the C28 property the wrapper's anchored cross-check must survive).
#
#     docker build -t l4fix:24.04 -f packaging/testdata/launch-Dockerfile packaging/testdata
#     docker run --rm -v "$PWD":/repo:ro -v "$CACHE":/tarball:ro -v "$STAGED":/staged:ro \
#          -w /repo l4fix:24.04 bash packaging/testdata/launch-harness.sh \
#          /tarball/darling-lol-linux-x86_64-<commit>-base-runtime.tar.gz
#
# Inputs:
#   $1 | L4_TARBALL     the published release tarball holding usr/local/bin/{darling,darlingserver,
#                       darling-coredump}, OR a directory holding those three (the already-extracted
#                       tarball, or a bin/ of the ELFs). Absent and un-downloadable => SKIP, exit 77.
#   L4_PKG_ROOT         optional: a REAL staged tree (dist/pkg/root after packaging/common/
#                       build-launcher.sh). Then the whole case machinery renders with the STAGED
#                       scripts/ and the R block asserts the staged payload's own facts.
#                       ABSENT: the R block does not run, the run says so on its own line and
#                       reports its row count in the summary's SKIP= field (rc stays 0 -- tarball
#                       mode is legal, it is just 14 rows smaller: PASS=71 FAIL=0 SKIP=14).
#   GH_TOKEN            optional: read-only `gh release download` if no tarball was given.
#                       Never printed and never passed on a command line.
#   L4_REPO             optional: repo root override (default: the harness's own ../../).
#
# Contract:
#   * COUNT the PASS=/FAIL= line it prints at the end: that is the total that goes in the PR.
#     (The rev-4 shape's 57/57 is historical; do not quote it for the shipped wrapper.)
#   * The R block (the staged-tree rows) needs L4_PKG_ROOT. When that input is ABSENT the run says
#     so on its own line, names how many counted rows that is, and repeats it in the summary's
#     SKIP= field -- a bare PASS= over a block that silently did not run is exactly the defect
#     this field exists to prevent (review C1). Tarball mode stays a LEGAL, GREEN mode (rc 0):
#     SKIP= is a report of what was NOT run, never a claim that it passed, and it is never added
#     into PASS=. Staged mode reports SKIP=0 and no such line.
#   * A skipped PRECONDITION (`skip()`) exits 77, never 0: a gate that could not run must not leave
#     a green row. That is NOT the same thing as the SKIP= field of the bullet just above: SKIP= is
#     carried by a GREEN rc-0 line and means "counted rows this mode did not need to run", never
#     "rows that failed to run". Two meanings of SKIP three lines apart was review MINOR-2.
#   * A log scanner doing `grep -i skip` on a LEGAL, GREEN tarball run WILL now hit it: the
#     `skip R block NOT RUN` line and the `SKIP=14` in the summary. That is intended -- SKIP= is a
#     report of what was not run, it is never a verdict, and it is never folded into PASS=
#     (review NIT-2). The mechanism this replaced was silent, so treat a `skip`/`SKIP` hit as a
#     question ("was that mode expected?") and read the line, not as a failure.
#   * Hermetic (TASKS preamble rule 7): every fixture is built by this run inside one private
#     mktemp -d, inputs are repo-relative, and nothing is read from a shared path. The negative
#     controls (I', L4, L4b) are what make the total mean something.
#
# Deviations from the executed rev-5 artifact, each forced by shipping it in the repo:
#   * the machine paths (/fix, /p4root, /pkgtest, /usrfix, /tmp/l4) are gone: repo-relative
#     inputs + a private scratch dir;
#   * case I' needs the REV-4 arm, which used to be the unshipped file darling-lol.in.rev4. It is
#     synthesized here by one substitution on the shipped template -- the same transformation
#     mutant L4 applies, which is exactly what "the rev-4 arm" means. I' therefore still asserts
#     rc=1 + "expected 4755" + no STUB-RUN, and L4 still asserts the same arm fires.
#   * launch-mkusr.py takes its source and output directories as arguments, so the sha256 pins in
#     PLAN appendix A10f identify the EXECUTED artifacts but no longer match these shipped copies
#     byte for byte (the patch rules are unchanged and both n==0 rules now fail loudly).
#   * the R block is new: the rev-5 artifact had no way to look at the staged tree. Its /usr/local
#     sweep walks the WHOLE staged tree under L4_PKG_ROOT -- non-usr/ directories (etc/ ...) included
#     -- with host-side symlinks FOLLOWED, minus the guest SDK, not just usr/bin + usr/lib/darling-lol
#     as it first shipped (review C2). That is the set check-prefix.sh (a) REACHES, and the two now agree
#     on the counter-trees that used to falsify the equality claim (review MAJOR-1). It is NOT
#     claimed to be identical, and the two residual differences are deliberate and stated here:
#     (i) PATH SOURCE -- this walks the tree on disk, while (a) walks the files.all list (a listed
#     path that is absent is not swept here; a stray file not in files.all is); (ii) READ ERRORS --
#     a per-file read error is swallowed by `2>/dev/null` here, while (a3) fails closed on one.
#     🚨 Symlinks are followed the way (a) follows them -- by handing the LINK PATH to grep -- and
#     NOT with `find -L`. `find -L` over this tree would follow the payload's OWN
#     usr/libexec/darling/Volumes/DarlingEmulatedDrive -> / (C19) and walk the ENTIRE host
#     (measured on this box: 1,096,791 files listed); the guest-SDK path filter suppresses those
#     RESULTS but cannot stop the traversal. Enumerating `-type f -o -type l` and letting grep open
#     each link cannot recurse out of the tree at all -- and that is exactly what (a) does: it is
#     driven by the list, never recursive. `grep -d skip` drops a link to a DIRECTORY the same way
#     (a)'s own `-d skip` does.
set -u

REPO=${L4_REPO:-}
if [ -z "$REPO" ]; then REPO=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd); fi
TPL=$REPO/packaging/install/darling-lol.in
MKUSR=$REPO/packaging/testdata/launch-mkusr.py
FAKEHOME=/home/tester
PASS=0; FAIL=0

ok(){ printf '  \033[32mok\033[0m   %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
chk(){ if [ "$2" = "$3" ]; then ok "$1 ($2)"; else no "$1: got [$2] want [$3]"; fi; }
has(){ case "$2" in *"$3"*) ok "$1"; return;; esac; no "$1: [$3] not in output"; }
lacks(){ case "$2" in *"$3"*) no "$1: [$3] unexpectedly present"; return;; esac; ok "$1"; }
skip(){ printf 'G-LAUNCH-1: SKIP %s\n' "$1"; exit 77; }

# ------------------------------------------------------------------ preconditions (never green)
[ "$(id -u)" = 0 ] || skip "must run as real root (it writes /usr, /usr/local and chmods 4755); run it in the gate container"
command -v setpriv >/dev/null 2>&1 || skip "setpriv (util-linux) is missing"
command -v python3 >/dev/null 2>&1 || skip "python3 is missing"
command -v strings >/dev/null 2>&1 || skip "strings (binutils) is missing"
[ -f "$TPL" ] || { echo "G-LAUNCH-1: FAIL no wrapper template: $TPL" >&2; exit 1; }
[ -f "$MKUSR" ] || { echo "G-LAUNCH-1: FAIL no fixture patcher: $MKUSR" >&2; exit 1; }

W=$(mktemp -d "${TMPDIR:-/tmp}/g-launch-1.XXXXXX")
# 0755, not mktemp's 0700: cases L8/L8m run the wrapper as a DIFFERENT uid whose $HOME is under $W,
# and a 0700 root-owned scratch makes the wrapper's own `rm -rf "$DEST/..."` fail with EACCES --
# which `set -e` turns into a silent rc=1 in the wrong place (measured: PASS=68 FAIL=3). The scratch
# is still private (a unique name, removed by the trap); it only has to be traversable.
chmod 0755 "$W"
trap 'rm -rf "$W"' EXIT HUP INT TERM

# ------------------------------------------------------------------------------- the tarball
tarball=${1:-${L4_TARBALL:-}}
if [ -z "$tarball" ]; then
  for c in "$REPO"/dist/*linux-x86_64*.tar.gz "$REPO"/dist/*linux-x86_64*.tar.zst; do
    [ -f "$c" ] && { tarball=$c; break; }
  done
fi
if [ -z "$tarball" ] && command -v gh >/dev/null 2>&1 && [ -n "${GH_TOKEN:-}" ]; then
  # Best effort, read-only. The token comes from the environment (never argv) and is never echoed.
  tag=${L4_RELEASE_TAG:-v0.1.0}
  echo "note: no local tarball; trying 'gh release download $tag' (read-only)"
  gh release download "$tag" --repo "${L4_REPO_SLUG:-QuinsZouls/darling-lol}" \
     --pattern '*linux-x86_64*.tar.gz' --dir "$W/dl" >/dev/null 2>&1 || true
  for c in "$W/dl"/*.tar.gz; do [ -f "$c" ] && { tarball=$c; break; }; done
fi
# An argument may also be a DIRECTORY: an extracted tarball, or a bare bin/ of the three ELFs.
if [ -n "$tarball" ] && [ -d "$tarball" ]; then
  if [ -d "$tarball/usr/local/bin" ]; then REALBIN=$tarball/usr/local/bin
  elif [ -f "$tarball/darlingserver" ] && [ -f "$tarball/darling" ]; then REALBIN=$tarball
  else skip "the directory '$tarball' holds neither usr/local/bin/ nor the three ELFs"; fi
fi
if [ -z "${REALBIN:-}" ]; then
  [ -n "$tarball" ] && [ -f "$tarball" ] \
    || skip "no published tarball (pass one as \$1 or L4_TARBALL, or set GH_TOKEN)"
  echo "=== 0. build the /usr fixture from the REAL v0.1.0 ELFs (length-preserving patch) ==="
  mkdir -p "$W/p4root"
  # Extract ONLY the three host ELFs. The published tarball has NO leading directory component
  # (`usr/local/bin/darling`, not `darling-lol-.../usr/local/bin/darling`), and everything else in it
  # is a 145 MB guest SDK this gate has no use for -- so select the members by name rather than
  # un-tarring the archive and hoping a wildcard matches.
  case "$tarball" in
    *.tar.gz|*.tgz) TFLAGS=-z;               list=$(tar -tzf "$tarball") ;;
    *.tar.zst)      command -v zstd >/dev/null 2>&1 \
                      || skip "the tarball is zstd-compressed and zstd is not installed in this image"
                    TFLAGS=--zstd;           list=$(tar --zstd -tf "$tarball") ;;
    *)              { echo "G-LAUNCH-1: FAIL unsupported tarball name: $tarball" >&2; exit 1; } ;;
  esac
  members=$(printf '%s\n' "$list" \
            | grep -E '(^|/)usr/local/bin/(darling|darlingserver|darling-coredump)$' || true)
  [ -n "$members" ] || { echo "G-LAUNCH-1: FAIL $tarball has no usr/local/bin/{darling,darlingserver,darling-coredump}" >&2; exit 1; }
  printf '%s\n' "$members" | tar "$TFLAGS" -xf "$tarball" -C "$W/p4root" -T -
  REALBIN=$(find "$W/p4root" -type d -path '*/usr/local/bin' -print -quit 2>/dev/null || true)
  [ -n "$REALBIN" ] || { echo "G-LAUNCH-1: FAIL the extraction produced no usr/local/bin" >&2; exit 1; }
fi
for f in darling darlingserver darling-coredump; do
  [ -f "$REALBIN/$f" ] \
    || { echo "G-LAUNCH-1: FAIL no $f in the given input ($tarball): need usr/local/bin/$f" >&2; exit 1; }
done
  echo "=== 0. the fixture ELFs (usr/local/bin) came from -- $REALBIN ==="
REAL=${REALBIN%/bin}                     # the published-tarball prefix (/usr/local) fixture root
python3 "$MKUSR" "$REALBIN" "$W/usrfix" || exit 1
echo "--- verify the fixture with the G-PREFIX-1 method (strings | grep -cx) ---"
for b in darlingserver darling-coredump; do
  printf '  %-18s exact /usr/libexec/darling=%s   exact /usr/local/libexec/darling=%s\n' "$b" \
    "$(strings -a "$W/usrfix/$b" | grep -cx '/usr/libexec/darling')" \
    "$(strings -a "$W/usrfix/$b" | grep -cx '/usr/local/libexec/darling')"
done
printf '  %-18s exact /usr/bin/darlingserver=%s   exact /usr/local/bin/darlingserver=%s\n' darling \
  "$(strings -a "$W/usrfix/darling" | grep -cx '/usr/bin/darlingserver')" \
  "$(strings -a "$W/usrfix/darling" | grep -cx '/usr/local/bin/darlingserver')"
echo "--- the guest literals that MUST survive the patch (PLAN 4.1 arm d) ---"
for s in '/usr/local' '/usr/local/share' 'PATH=/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin'; do
  printf '  guest literal %-52s count=%s\n' "$s" "$(strings -a "$W/usrfix/darling" | grep -cxF "$s")"
done
echo "--- fixture limitation, stated: the CONCATENATED literals keep /usr/local ---"
strings -a "$W/usrfix/darlingserver" | grep -n 'libexec/darling' | sed 's/^/    /'

id tester >/dev/null 2>&1 || { groupadd -g 1001 tester; useradd -u 1001 -g 1001 -d "$FAKEHOME" -M -s /bin/bash tester; }

# --------------------------------------------------------------------------- fixture builders
scripts_dir=$REPO/scripts
if [ -n "${L4_PKG_ROOT:-}" ]; then scripts_dir=$L4_PKG_ROOT/usr/lib/darling-lol/scripts; fi
[ -f "$scripts_dir/configure.py" ] || { echo "G-LAUNCH-1: FAIL no configure.py under $scripts_dir" >&2; exit 1; }
[ -f "$scripts_dir/common.py" ]    || { echo "G-LAUNCH-1: FAIL no common.py under $scripts_dir" >&2; exit 1; }

mktemplates(){ # $1=dir -- minimal but faithful: the real configure.py/common.py + tokened tools/
  mkdir -p "$1/scripts" "$1/tools"
  cp "$scripts_dir/configure.py" "$scripts_dir/common.py" "$1/scripts/"
  cat > "$1/tools/run-riot-client.sh" <<'EOF'
#!/bin/sh
echo "STUB-RUN sdk=@DARLING_SDK@ guest_home=@GUEST_HOME@ guest_user=@GUEST_USER@ dprefix=@DPREFIX@"
EOF
  printf 'SDK="@DARLING_SDK@"; HOME_="@GUEST_HOME@"\n' > "$1/tools/another.py"
}
mkusrlocal(){ # the published-tarball shape, using the REAL binaries
  mkdir -p /usr/local/bin /usr/local/libexec/darling/usr/libexec/darling \
           /usr/local/share/doc/darling-lol
  cp "$REAL/bin/darling" "$REAL/bin/darlingserver" /usr/local/bin/
  chmod 4755 /usr/local/bin/darling; chmod 0755 /usr/local/bin/darlingserver
  echo guest > /usr/local/libexec/darling/README
  printf 'commit: cbd8a0e\nprefix: /usr/local\n' > /usr/local/share/doc/darling-lol/BUILD-INFO.txt
  mktemplates /usr/local/share/darling-lol
}
mkusr(){ # the packaged shape, using the string-patched fixture binaries
  mkdir -p /usr/bin /usr/libexec/darling/usr/libexec/darling /usr/share/doc/darling-lol
  cp "$W/usrfix/darling" "$W/usrfix/darlingserver" /usr/bin/
  chmod 4755 /usr/bin/darling; chmod 0755 /usr/bin/darlingserver
  echo guest > /usr/libexec/darling/README
  printf 'commit: aaa1111\nprefix: /usr\n' > /usr/share/doc/darling-lol/BUILD-INFO.txt
  mktemplates /usr/lib/darling-lol
}
mkkiosk(){ # $1 = dir holding the REAL (i.e. /usr/local-compiled) binaries, + the A2 symlink farm
  mkdir -p "$1/bin" /usr/libexec /usr/lib/darling-lol
  cp "$REAL/bin/darling" "$REAL/bin/darlingserver" "$1/bin/"
  chmod 4755 "$1/bin/darling"; chmod 0755 "$1/bin/darlingserver"
  ln -sfn /usr/local/libexec/darling /usr/libexec/darling
  mktemplates /usr/lib/darling-lol
}
wipe(){ rm -rf /usr/local/bin /usr/local/libexec /usr/local/share /usr/bin/darling \
        /usr/bin/darlingserver /usr/libexec /usr/lib/darling-lol /usr/share/doc/darling-lol \
        "$FAKEHOME"
        mkdir -p "$FAKEHOME"; chown 1001:1001 "$FAKEHOME"; }
render_to(){ sed -e "s|@SDK@|$2|g" -e "s|@TEMPLATES@|$3|g" "${4:-$TPL}" > "$1"; chmod 0755 "$1"; }
render(){ render_to /usr/bin/darling-lol "$1" "$2" "${3:-$TPL}"; }
run(){ setpriv --reuid=1001 --regid=1001 --clear-groups env HOME="$FAKEHOME" "$@" \
         /usr/bin/darling-lol 2>&1; }

echo; echo "=== A. only the published v0.1.0 tarball prefix (/usr/local) is installed ==="
wipe; mkusrlocal; render /usr/libexec/darling /usr/lib/darling-lol
out=$(run); rc=$?
chk "A rc" "$rc" 0
has "A detected /usr/local" "$out" "prefix=/usr/local sdk=/usr/local/libexec/darling"
has "A rendered @DARLING_SDK@ to /usr/local" "$out" "STUB-RUN sdk=/usr/local/libexec/darling"
has "A guest_home is the real user" "$out" "guest_home=/Users/tester"

echo; echo "=== B. only the packaged prefix (/usr) is installed ==="
wipe; mkusr; render /usr/libexec/darling /usr/lib/darling-lol
out=$(run); rc=$?
chk "B rc" "$rc" 0
has "B detected /usr" "$out" "prefix=/usr sdk=/usr/libexec/darling"
has "B rendered @DARLING_SDK@ to /usr" "$out" "STUB-RUN sdk=/usr/libexec/darling"

echo; echo "=== C. BOTH installed, wrapper rendered for the PACKAGE -> /usr must win ==="
wipe; mkusrlocal; mkusr; render /usr/libexec/darling /usr/lib/darling-lol
out=$(run); rc=$?
chk "C rc" "$rc" 0
has "C picked /usr" "$out" "prefix=/usr sdk=/usr/libexec/darling"
lacks "C did not pick /usr/local" "$out" "prefix=/usr/local"

echo; echo "=== C2. BOTH installed, wrapper rendered for the TARBALL -> /usr/local must win ==="
wipe; mkusrlocal; mkusr; render /usr/local/libexec/darling /usr/local/share/darling-lol
out=$(run); rc=$?
chk "C2 rc" "$rc" 0
has "C2 picked /usr/local" "$out" "prefix=/usr/local sdk=/usr/local/libexec/darling"
has "C2 templates from /usr/local/share" "$out" "templates=/usr/local/share/darling-lol"

echo; echo "=== D. symlink farm (rejected alternative A2): /usr/libexec/darling -> /usr/local/... ==="
wipe; mkusrlocal; mkkiosk /usr
render /usr/libexec/darling /usr/lib/darling-lol
out=$(run); rc=$?
chk "D rc" "$rc" 0
has "D refused the farm and fell through to the real prefix" "$out" "prefix=/usr/local sdk=/usr/local/libexec/darling"
lacks "D did not pick the farm" "$out" "prefix=/usr "

echo; echo "=== D2. farm only (no real runtime anywhere) -> must die, not guess ==="
wipe; mkdir -p /usr/local/libexec/darling; mkkiosk /usr
render /usr/libexec/darling /usr/lib/darling-lol
out=$(run); rc=$?
chk "D2 rc" "$rc" 1
has "D2 says no usable runtime" "$out" "no usable darling-lol runtime found"
has "D2 names the candidates" "$out" "/usr/local/libexec/darling"

echo; echo "=== E. nothing installed ==="
wipe; mkdir -p /usr/lib/darling-lol; mktemplates /usr/lib/darling-lol
render /usr/libexec/darling /usr/lib/darling-lol
out=$(run); rc=$?
chk "E rc" "$rc" 1
has "E honest message" "$out" "no usable darling-lol runtime found"
has "E tells them about DARLING_SDK" "$out" "DARLING_SDK=/path/to/libexec/darling"

echo; echo "=== F. setuid bit lost on a system prefix (EVIDENCE C3) ==="
wipe; mkusr; chmod 0755 /usr/bin/darling; render /usr/libexec/darling /usr/lib/darling-lol
out=$(run); rc=$?
chk "F rc" "$rc" 1
has "F names the mode" "$out" "is mode 755, expected 4755"
lacks "F did not render first" "$out" "STUB-RUN"

echo; echo "=== F2. (rev 5 / C32) case F with \$HOME unusable -> must still die on the mode check ==="
# 🚨 MEASURED LIMIT OF THE LITERAL PRESCRIPTION. With HOME *unset* and no XDG_DATA_HOME, this wrapper
# dies at its DEST= line (`set -eu`) with "HOME: parameter not set" (rc=2) BEFORE step 3, so the arm
# is never reached and a plain `env -u HOME` can neither test the arm nor catch mutant L4b. The two
# runnable forms below exercise the guard's `""` arm for real: HOME unset with XDG_DATA_HOME set
# (F2b), and HOME empty-but-set (F2c).
wipe; mkusr; chmod 0755 /usr/bin/darling; render /usr/libexec/darling /usr/lib/darling-lol
out=$(setpriv --reuid=1001 --regid=1001 --clear-groups env -u HOME /usr/bin/darling-lol 2>&1); rc=$?
chk "F2 measurement: plain 'env -u HOME' never reaches the arm (rc=2)" "$rc" 2
case "$out" in *"parameter not set"*) ok "F2 and it dies on the DEST= line, not on the mode check";; *) no "F2 unexpected message: $out";; esac
out=$(setpriv --reuid=1001 --regid=1001 --clear-groups env -u HOME XDG_DATA_HOME="$FAKEHOME/.local/share" /usr/bin/darling-lol 2>&1); rc=$?
chk "F2b (HOME unset + XDG_DATA_HOME) rc" "$rc" 1
has "F2b still demands 4755 with no \$HOME" "$out" "is mode 755, expected 4755"
lacks "F2b did not render first" "$out" "STUB-RUN"
out=$(setpriv --reuid=1001 --regid=1001 --clear-groups env HOME= XDG_DATA_HOME="$FAKEHOME/.local/share" /usr/bin/darling-lol 2>&1); rc=$?
chk "F2c (HOME empty but set) rc" "$rc" 1
has "F2c still demands 4755 with an empty \$HOME" "$out" "is mode 755, expected 4755"

echo; echo "=== G. templates missing ==="
wipe; mkusr; rm -rf /usr/lib/darling-lol /usr/local/share/darling-lol
render /usr/libexec/darling /usr/lib/darling-lol
out=$(run); rc=$?
chk "G rc" "$rc" 1
has "G honest message" "$out" "no darling-lol launcher templates found"

echo; echo "=== H. DARLING_SDK override wins over both installed prefixes ==="
wipe; mkusrlocal; mkusr; render /usr/libexec/darling /usr/lib/darling-lol
out=$(run env DARLING_SDK=/usr/local/libexec/darling); rc=$?
chk "H rc" "$rc" 0
has "H honoured the override" "$out" "prefix=/usr/local sdk=/usr/local/libexec/darling"

echo; echo "=== I. (rev 5 / C32) a DARLING_SDK prefix UNDER \$HOME: detected, setuid NOT demanded ==="
# A relocated local build: compiled for /usr, staged under $HOME with its usr/ level intact
# (candidate .../build/darling/usr/libexec/darling => the wrapper computes PREFIX=.../build/darling/usr).
# The binaries MUST be the string-patched /usr fixture: the cross-check greps $p/bin/darlingserver for
# the compiled literal, and the REAL published binary is compiled for /usr/local.
mkc32(){ mkdir -p "$FAKEHOME/build/darling/usr/bin" "$FAKEHOME/build/darling/usr/libexec/darling"
  cp "$W/usrfix/darling" "$W/usrfix/darlingserver" "$FAKEHOME/build/darling/usr/bin/"
  chmod 0755 "$FAKEHOME/build/darling/usr/bin/darling"   # a plain `tar -x` drops setuid (C3)
  mkdir -p /usr/lib/darling-lol; mktemplates /usr/lib/darling-lol; chown -R 1001:1001 "$FAKEHOME"; }
mkc32flat(){ # the same relocated build WITHOUT a usr/ level (PLAN says "prefix $HOME/build/darling")
  mkdir -p "$FAKEHOME/build/darling/bin" "$FAKEHOME/build/darling/libexec/darling"
  cp "$W/usrfix/darling" "$W/usrfix/darlingserver" "$FAKEHOME/build/darling/bin/"
  chmod 0755 "$FAKEHOME/build/darling/bin/darling"
  mkdir -p /usr/lib/darling-lol; mktemplates /usr/lib/darling-lol; chown -R 1001:1001 "$FAKEHOME"; }
wipe; mkc32
render /usr/libexec/darling /usr/lib/darling-lol
out=$(run env DARLING_SDK="$FAKEHOME/build/darling/usr/libexec/darling"); rc=$?
chk "I rc" "$rc" 0
has "I detected the \$HOME prefix" "$out" "prefix=$FAKEHOME/build/darling/usr"
has "I rendered the \$HOME sdk" "$out" "sdk=$FAKEHOME/build/darling/usr/libexec/darling"
lacks "I did not demand 4755" "$out" "expected 4755"

echo; echo "=== I''. MEASUREMENT: the LITERAL '\$HOME/build/darling' shape (no usr/ level) is REJECTED ==="
wipe; mkc32flat
render /usr/libexec/darling /usr/lib/darling-lol
out=$(run env DARLING_SDK="$FAKEHOME/build/darling/libexec/darling"); rc=$?
chk "I'' rc (no usr/ level => not a candidate)" "$rc" 1
has "I'' says no usable runtime" "$out" "no usable darling-lol runtime found"
printf '  \033[33mnote\033[0m the cross-check regex is /usr(/local)?/libexec/darling$, so an SDK tree must keep a usr/ level\n'

echo; echo "=== I'. NEGATIVE CONTROL: the SAME fixture against the REV-4 arm -> must FAIL (C32 is a fix) ==="
# The rev-4 arm is not shipped (it named the discarded user mode); only its PATTERN matters to this
# control, and one substitution reproduces it -- the same one mutant L4 applies, asserted to match.
wipe; mkc32
python3 - "$TPL" "$W/rev4.in" <<'PY' || { echo "G-LAUNCH-1: FAIL could not synthesize the rev-4 arm" >&2; exit 1; }
import pathlib, sys
src, dst = sys.argv[1], sys.argv[2]
s = pathlib.Path(src).read_text()
old = 'in "$HOME"/*) NONSYSTEM=1'
new = 'in "$HOME"/.darling-lol/*) NONSYSTEM=1'
assert s.count(old) == 1, "the NONSYSTEM arm was not found verbatim"
pathlib.Path(dst).write_text(s.replace(old, new))
PY
render /usr/libexec/darling /usr/lib/darling-lol "$W/rev4.in"
out=$(run env DARLING_SDK="$FAKEHOME/build/darling/usr/libexec/darling"); rc=$?
chk "I' rc (rev-4 arm)" "$rc" 1
has "I' names the wrong demand" "$out" "expected 4755"
lacks "I' did not render (it died before rendering)" "$out" "STUB-RUN"

echo; echo "=== J. stamp stability, and re-render when the prefix changes ==="
wipe; mkusrlocal; mkusr; render /usr/libexec/darling /usr/lib/darling-lol
o1=$(run); o2=$(run)
has  "J first run renders" "$o1" "rendering the launcher"
lacks "J second run does NOT re-render" "$o2" "rendering the launcher"
chk  "J stamp content" "$(cat "$FAKEHOME/.local/share/darling-lol/.rendered-from")" "/usr aaa1111"
rm -rf /usr/libexec /usr/bin/darling /usr/bin/darlingserver /usr/lib/darling-lol   # package removed
o3=$(run)
has "J after removing /usr it re-renders" "$o3" "rendering the launcher"
has "J and switches prefix" "$o3" "prefix=/usr/local"
chk "J stamp updated" "$(cat "$FAKEHOME/.local/share/darling-lol/.rendered-from")" "/usr/local cbd8a0e"
grep -q '"sdk": "/usr/local/libexec/darling"' "$FAKEHOME/.local/share/darling-lol/build/config.json" \
  && ok "J config.json re-rendered with the new sdk" || no "J config.json still points at /usr"

echo; echo "=== K. DARLING_GUEST_USER=root (the guest home becomes /Users/root) ==="
wipe; mkusr; render /usr/libexec/darling /usr/lib/darling-lol
out=$(run env DARLING_GUEST_USER=root); rc=$?
chk "K rc" "$rc" 0
has "K configure.py accepts 'root' and renders /Users/root" "$out" "guest_home=/Users/root guest_user=root"

echo; echo "=== MUTANTS (each must change one of the outcomes above) ==="

echo "-- L1: drop the compiled-prefix cross-check --"
wipe; mkusrlocal; mkkiosk /usr
sed '/grep -aqzx -F -- "\$exp"/d' "$TPL" > "$W/m1"
render /usr/libexec/darling /usr/lib/darling-lol "$W/m1"
out=$(run); has "L1 FIRES: the symlink farm is now accepted" "$out" "prefix=/usr sdk=/usr/libexec/darling"

echo "-- L2: unanchored 'grep -aoE | head -1' instead of -z -x --"
wipe; mkusrlocal; mkkiosk /usr
python3 - "$TPL" "$W/m2" <<'PY' || { echo "G-LAUNCH-1: FAIL could not build mutant L2" >&2; exit 1; }
import pathlib, sys
src, dst = sys.argv[1], sys.argv[2]
s = pathlib.Path(src).read_text()
old = 'grep -aqzx -F -- "$exp" "$p/bin/darlingserver" 2>/dev/null || continue'
new = ('c1=$(grep -aoE \'/usr(/local)?/libexec/darling\' "$p/bin/darlingserver" 2>/dev/null | head -n 1 || true)\n'
       '    [ "$c1" = "$exp" ] || continue')
assert old in s, "the anchored cross-check was not found verbatim"
pathlib.Path(dst).write_text(s.replace(old, new))
PY
render /usr/libexec/darling /usr/lib/darling-lol "$W/m2"
out=$(run)
has "L2a the /usr/local binary is still rejected by luck (head -1 happens to be right)" "$out" "prefix=/usr/local"
echo "     ...but the same mutant, asked whether /usr/libexec/darling is compiled in, says YES:"
if grep -aoE '/usr(/local)?/libexec/darling' /usr/bin/darlingserver | grep -qx /usr/libexec/darling
then ok "L2b FIRES: unanchored match reports /usr/libexec/darling PRESENT in a /usr/local binary"
else no "L2b did not reproduce"; fi

echo "-- L3: candidate order reversed (/usr/local before /usr) --"
wipe; mkusrlocal; mkusr; render /usr/libexec/darling /usr/lib/darling-lol
# reverse the list in the RENDERED file: @SDK@ is already substituted, so the reversal is real.
# (Reversing it in the .in file is INERT by construction -- @SDK@ stays first and equals /usr/...
#  for a package-rendered wrapper. Recorded, not dropped, exactly like NR2a/NR2c in the plan.)
sed -i 's|^SDK_CANDIDATES=.*|SDK_CANDIDATES="/usr/local/libexec/darling /usr/libexec/darling"|' /usr/bin/darling-lol
grep -n 'SDK_CANDIDATES=' /usr/bin/darling-lol | head -1 | sed 's/^/     rendered: /'
out=$(run); has "L3 FIRES: /usr/local wins on a box whose package is /usr" "$out" "prefix=/usr/local"

echo "-- L4 (rev 5 / C32, REDEFINED): revert the NONSYSTEM arm to the old \"\$HOME\"/.darling-lol/* pattern --"
python3 - "$TPL" "$W/m4" <<'PY' || { echo "G-LAUNCH-1: FAIL could not build mutant L4" >&2; exit 1; }
import pathlib, sys
src, dst = sys.argv[1], sys.argv[2]
s = pathlib.Path(src).read_text()
old = 'in "$HOME"/*) NONSYSTEM=1'
new = 'in "$HOME"/.darling-lol/*) NONSYSTEM=1'
assert s.count(old) == 1, "the rev-5 arm was not found verbatim"
pathlib.Path(dst).write_text(s.replace(old, new))
PY
wipe; mkc32
render /usr/libexec/darling /usr/lib/darling-lol "$W/m4"
out=$(run env DARLING_SDK="$FAKEHOME/build/darling/usr/libexec/darling"); rc=$?
chk "L4 FIRES: case I is asked for 4755 again" "$rc" 1
has "L4 and it names the wrong demand" "$out" "expected 4755"

echo "-- L4b (rev 5 / C32, NEW): drop the \"\"|\"/\" guard (HOME unset -> pattern /* matches everything) --"
python3 - "$TPL" "$W/m4b" <<'PY' || { echo "G-LAUNCH-1: FAIL could not build mutant L4b" >&2; exit 1; }
import pathlib, re, sys
src, dst = sys.argv[1], sys.argv[2]
s = pathlib.Path(src).read_text()
out, n = re.subn(r'(?m)^[ \t]*""\|"/"\)[ \t]*;;.*\n', '', s, count=1)
assert n == 1, "the \"\"|\"/\" guard line was not found"
pathlib.Path(dst).write_text(out)
PY
wipe; mkusr; chmod 0755 /usr/bin/darling; render /usr/libexec/darling /usr/lib/darling-lol "$W/m4b"
out=$(setpriv --reuid=1001 --regid=1001 --clear-groups env -u HOME XDG_DATA_HOME="$FAKEHOME/.local/share" /usr/bin/darling-lol 2>&1); rc=$?
printf '  \033[33mnote\033[0m L4b rc=%s (irrelevant: it now dies later, on $HOME at --prefix)\n' "$rc"
case "$out" in *"expected 4755"*) no "L4b did not fire: the mode check still ran";; *) ok "L4b FIRES: the 4755 assertion is silently skipped with no \$HOME";; esac

echo "-- L5: stamp records only the commit, not the prefix --"
sed 's|stamp_val="\$PREFIX \$pkg_id"|stamp_val="$pkg_id"|' "$TPL" > "$W/m5"
wipe; mkusrlocal; mkusr
# SAME commit at both prefixes: the v0.1.0 tarball and a package built from the same source.
printf 'commit: cbd8a0e\nprefix: /usr\n' > /usr/share/doc/darling-lol/BUILD-INFO.txt
render /usr/libexec/darling /usr/lib/darling-lol "$W/m5"
run >/dev/null                                   # renders for /usr, stamp="aaa1111"
rm -rf /usr/libexec /usr/bin/darling /usr/bin/darlingserver /usr/lib/darling-lol
out=$(run)
lacks "L5 FIRES: no re-render after the prefix changed" "$out" "rendering the launcher"
if grep -q '"sdk": "/usr/libexec/darling"' "$FAKEHOME/.local/share/darling-lol/build/config.json"; then
  ok "L5 and config.json is left pointing at the REMOVED /usr tree (same commit, so the stamp matched)"
else no "L5 inconclusive"; fi

echo "-- L6: @SDK@ dropped from the candidate list --"
sed 's|SDK_CANDIDATES="@SDK@ /usr/libexec/darling|SDK_CANDIDATES="/usr/libexec/darling|' \
    "$TPL" > "$W/m6"
wipe; mkusrlocal; mkusr; render /usr/local/libexec/darling /usr/local/share/darling-lol "$W/m6"
out=$(run); has "L6 FIRES: a tarball-rendered wrapper ignores its own prefix" "$out" "prefix=/usr "

echo "-- L7: no DARLING_SDK override (the escape hatch removed) --"
sed '/DARLING_SDK:-/d' "$TPL" > "$W/m7"
wipe; mkusrlocal; mkusr; render /usr/libexec/darling /usr/lib/darling-lol "$W/m7"
out=$(run env DARLING_SDK=/usr/local/libexec/darling); rc=$?
has "L7 FIRES: the override is ignored" "$out" "prefix=/usr "

echo "-- L8: the invoking uid has NO /etc/passwd entry (C26-adjacent: LDAP/SSSD enumerate=false) --"
wipe; mkusr; render /usr/libexec/darling /usr/lib/darling-lol
NOENT=$W/noent; mkdir -p "$NOENT"; chmod 0755 "$NOENT"; chown 65431:65431 "$NOENT"
out=$(setpriv --reuid=65431 --regid=65431 --clear-groups env HOME="$NOENT" /usr/bin/darling-lol 2>&1); rc=$?
echo "$out" | tail -6 | sed 's/^/     | /'
printf '     rc=%s\n' "$rc"
if [ "$rc" = 0 ]; then ok "L8 survives a uid with no passwd entry"; else no "L8 DIES on a uid with no passwd entry (rc=$rc): $(echo "$out" | tail -2 | tr '\n' ' ')"; fi

echo "-- L8m: revert the C29 hardening (no LOGNAME, no \$me fallback) --"
# revert to the EXACT earlier form: no `me=` line, `$(id -un)` inline in the echo and in the
# --guest-user argument. Inline matters -- a standalone `me=$(id -un)` assignment would instead be
# killed by `set -e` with a bare "id: cannot find name for user ID", a DIFFERENT (and less
# misleading) failure. The reverted form reaches configure.py and produces the traceback.
python3 - "$TPL" "$W/m8" <<'PY' || { echo "G-LAUNCH-1: FAIL could not build mutant L8m" >&2; exit 1; }
import pathlib, re, sys
src, dst = sys.argv[1], sys.argv[2]
s = pathlib.Path(src).read_text()
s, n = re.subn(r'(?ms)^me=\$\(id -un.*?\n\n', '', s, count=1)
assert n == 1, "the me= hardening was not found"
s = s.replace('LOGNAME="$me" USER="$me" python3', 'python3')
s = s.replace('${DARLING_GUEST_USER:-$me}', '${DARLING_GUEST_USER:-$(id -un)}')
s = s.replace('rendering the launcher for $me into', 'rendering the launcher for $(id -un) into')
assert 'me=$(id -un' not in s and 'LOGNAME="$me"' not in s, 'the me= hardening is still present'
pathlib.Path(dst).write_text(s)
PY
wipe; mkusr; render /usr/libexec/darling /usr/lib/darling-lol "$W/m8"
# A FRESH home: reusing L8's would find L8's own stamp already valid, skip the render block, and
# report rc=0 -- the mutant would look harmless for the wrong reason (measured).
NOENT=$W/noent-m; mkdir -p "$NOENT"; chmod 0755 "$NOENT"; chown 65431:65431 "$NOENT"
out=$(setpriv --reuid=65431 --regid=65431 --clear-groups env HOME="$NOENT" /usr/bin/darling-lol 2>&1); rc=$?
echo "$out" | grep -E 'KeyError|getpwuid|configure.py failed|no such user|cannot find name' | head -4 | sed 's/^/     | /'
chk "L8m FIRES: rc=1 for a uid with no passwd entry" "$rc" 1
has "L8m and the diagnosis is a Python traceback" "$out" "KeyError"
has "L8m plus a misleading message" "$out" "configure.py failed; is python3 installed?"

echo "-- M: BUILD-INFO.txt absent (the tarball ships it at a different path) --"
wipe; mkusr; rm -f /usr/share/doc/darling-lol/BUILD-INFO.txt
render /usr/libexec/darling /usr/lib/darling-lol
m1o=$(run); m2o=$(run)
has  "M first run renders" "$m1o" "rendering the launcher"
lacks "M second run does NOT re-render (stamp is 'unknown' both times)" "$m2o" "rendering the launcher"

# ------------------------------------------------------------------ R. the real staged tree
#
# C1: this block is gated on L4_PKG_ROOT, and it used to have no `else`. Without a staged tree the
# whole block -- R1..R9b, R_ROWS counted rows -- simply vanished from the output and the run still
# ended `G-LAUNCH-1: PASS=71 FAIL=0`, rc 0, with nothing saying 14 rows went unmeasured. The block
# keeps its gate (a staged tree is its input; tarball mode is legal and must stay rc 0), but the
# absence is now STATED and COUNTED in the summary's SKIP= field. R_ROWS is the block's own row
# count; because a number that rots is the same lie in a new place, staged mode (the only mode that
# can see the truth) asserts it against the row delta it actually measured just below, and goes RED
# if a row is added or removed without bumping it.
#
# AM_ROWS is the SAME treatment for the other, larger block (review MINOR-1): the counted rows that
# cases A-M emitted above. They had NO pinned total, so deleting one (measured: `chk "A rc" "$rc" 0`)
# left staged `PASS=84 FAIL=0 SKIP=0` and tarball `PASS=70 FAIL=0 SKIP=14`, rc 0, with no signal --
# the very class this change exists to close, one block up. AM_ROWS is asserted immediately below,
# fail-only, in BOTH modes (cases A-M run in both, unlike R, which only staged mode can measure).
# AM_ROWS + R_ROWS together cover EVERY counted row in this file, each checked in the mode that can
# see it.
R_ROWS=14
AM_ROWS=71
# MINOR-1: pin the A-M total. Fail-only -- a counted `ok` here would move the very total the constant
# protects. Checked before r_rows0 is captured, so a failing AMBLOCK row cannot leak into the R
# block's own delta (measured: deleting one A-M row reddens AMBLOCK alone, not RBLOCK too).
[ "$((PASS + FAIL))" = "$AM_ROWS" ] \
  || no "AMBLOCK: AM_ROWS=$AM_ROWS but cases A-M ran $((PASS + FAIL)) counted row(s) (bump AM_ROWS in the same commit)"
r_rows0=$((PASS + FAIL))
r_ran=no
if [ -n "${L4_PKG_ROOT:-}" ]; then
  r_ran=yes
  echo; echo "=== R. the REAL staged tree (L4_PKG_ROOT=$L4_PKG_ROOT) ==="
  P=$L4_PKG_ROOT
  # C2/MAJOR-1: the sweep SCOPE. R7 and R9 used to walk `$P/usr/bin $P/usr/lib/darling-lol` -- blind
  # to usr/share/doc/** and to any future payload directory -- while the authoritative gate
  # (check-prefix.sh part (a)) reaches every host-side path files.all lists. So this "second opinion"
  # was narrower than it read: a /usr/local literal planted in
  # usr/share/doc/darling-lol/README-packaging.md left the old sweep green (R9=0). One scope
  # variable, used by both rows, now walks the WHOLE staged tree -- non-usr/ directories such as
  # etc/ included, because (a) sweeps them too -- MINUS the guest SDK (usr/libexec/darling/**, whose
  # ~362 /usr/local hits are Apple's and are a report in check-prefix.sh (b)/(e), never a failure).
  # Host-side SYMLINKS are followed by handing the LINK PATH to grep (`-type f -o -type l`), NOT with
  # `find -L`, which would follow the payload's own Volumes/DarlingEmulatedDrive -> / out of the tree
  # and walk the host (measured; see the header). The exclusion is by PATH UNDER THE TREE, so a
  # symlink that merely POINTS at the SDK is still scanned (that is the counter-tree review MAJOR-1
  # falsified with). The two residual differences from (a) are deliberate and stated in the header,
  # not hidden: the scope SOURCE (this walks the tree on disk; (a) walks the files.all list) and READ
  # ERRORS (this swallows a per-file read error via `2>/dev/null`; (a3) fails closed on one).
  sweep=$P
  sweep_skip=$P/usr/libexec/darling
  printf '  \033[33mnote\033[0m cases A-M above rendered with %s (the STAGED scripts, not the checkout'"'"'s)\n' "$scripts_dir"
  chk "R1 the staged wrapper exists and is executable" "$([ -x "$P/usr/bin/darling-lol" ] && echo yes || echo no)" yes
  chk "R2 the staged wrapper is a 2-token render of packaging/install/darling-lol.in" \
      "$(cmp -s /usr/bin/darling-lol "$P/usr/bin/darling-lol" && echo same || echo differs)" same
  # (this one ran after case M, so it compares the harness's own render; re-render to be explicit)
  render_to "$W/r2" /usr/libexec/darling /usr/lib/darling-lol
  chk "R2b the same render is byte-identical again (deterministic)" \
      "$(cmp -s "$W/r2" "$P/usr/bin/darling-lol" && echo same || echo differs)" same
  chk "R3 the staged configure.py is the repo's own file" \
      "$(cmp -s "$P/usr/lib/darling-lol/scripts/configure.py" "$REPO/scripts/configure.py" && echo same || echo differs)" same
  chk "R3b the staged common.py is the repo's own file" \
      "$(cmp -s "$P/usr/lib/darling-lol/scripts/common.py" "$REPO/scripts/common.py" && echo same || echo differs)" same
  # R4 and R8 keep EXACT counts on purpose (NIT-2 disposition, T8d): both pin facts of a file this
  # repo OWNS and generates (the wrapper template packaging/install/darling-lol.in and the doc
  # inventory build-launcher.sh stages), never a number an upstream merge can move -- unlike the
  # old R9, which is why only R9 was re-cut. A deliberate template/doc edit is the same-commit
  # reminder, not merge rot. R2/R2b already prove the staged wrapper IS this template's render.
  chk "R4 the staged wrapper still names @GUEST_HOME@ in a comment (comments untouched)" \
      "$(grep -c '@GUEST_HOME@' "$P/usr/bin/darling-lol")" 1
  chk "R5 the staged wrapper has no residual token on a code line" \
      "$(grep -vE '^[[:space:]]*#' "$P/usr/bin/darling-lol" | grep -cE '@[A-Za-z_]+@')" 0
  ntok=$(find "$P/usr/lib/darling-lol/tools" -type f -exec grep -l '@GUEST_HOME@' {} + 2>/dev/null | wc -l | tr -d ' ')
  printf '  \033[33mnote\033[0m %s staged template file(s) under tools/ still carry @GUEST_HOME@ (must be > 0)\n' "$ntok"
  chk "R6 the staged tools are UNRENDERED (count-agnostic, never a file count)" "$([ "$ntok" -gt 0 ] && echo yes || echo no)" yes
  chk "R7 no staged path carries /home/runner (the D4 bug)" \
      "$(find "$sweep" \( -type f -o -type l \) ! -path "$sweep_skip/*" -exec grep -l -d skip '/home/runner' {} + 2>/dev/null | wc -l | tr -d ' ')" 0
  # R8/R8b: the R-4 split invariant (the doc dir holds exactly the launcher's own README).
  chk "R8 exactly ONE staged file under usr/share/doc/darling-lol (R-4)" \
      "$(find "$P/usr/share/doc/darling-lol" -type f | wc -l | tr -d ' ')" 1
  chk "R8b and it is README-packaging.md" \
      "$(find "$P/usr/share/doc/darling-lol" -type f -name README-packaging.md | wc -l | tr -d ' ')" 1
  # The allowlist has exactly ONE home: check-prefix.sh (T8d/MINOR-2). The R block used to keep a
  # SECOND, COUNT-PINNED copy of it here (`grep -cE "$allowed"` == 8), so every upstream merge that
  # added a reader forced a same-commit edit -- the T8c event, where with only check-prefix.sh fixed
  # R9 stayed green by accident (7 matching lines) and R9b went red, PASS=83 FAIL=1. The harness now
  # ASKS the gate for its allowlist and compares the staged hits against it as a SET, in BOTH
  # directions: no count is asserted, and a future merge needs no edit here. (If --print-allowlist
  # fails or answers nothing, R9a and R9 go red -- fail closed -- while R9b's comparison is then
  # trivially empty, which is why R9a exists as the non-empty assertion.)
  # C2/MAJOR-1: the sweep is over the WHOLE staged tree (`$sweep`, one variable, the same one R7
  # uses) and follows host-side symlinks by grepping the LINK PATH (never `find -L` -- see the
  # header), not over two hand-picked subdirectories -- a subset scope is how the usr/share/doc gap
  # lived.
  printf '  \033[33mnote\033[0m R7/R9 sweep scope: the WHOLE staged tree under %s, symlinks followed via grep (never find -L), guest SDK %s excluded by path -- check-prefix.sh (a) reachability\n' "$sweep" "$sweep_skip"
  hits=$(find "$sweep" \( -type f -o -type l \) ! -path "$sweep_skip/*" -exec grep -Il -d skip 'usr/local' {} + 2>/dev/null \
           | sed "s|^$P/||" | LC_ALL=C sort)
  wl=$(sh "$REPO/packaging/common/check-prefix.sh" --print-allowlist 2>/dev/null) || wl=""
  chk "R9a check-prefix.sh --print-allowlist answers with its allowlist (count-free)" \
      "$([ -n "$wl" ] && echo yes || echo no)" yes
  printf '%s\n' "$hits" | grep -v '^$' | LC_ALL=C sort -u > "$W/r9.hits"
  printf '%s\n' "$wl"   | grep -v '^$' | LC_ALL=C sort -u > "$W/r9.allow"
  chk "R9 no staged /usr/local text hit is off check-prefix.sh's allowlist" \
      "$(comm -23 "$W/r9.hits" "$W/r9.allow" | wc -l | tr -d ' ')" 0
  chk "R9b every reader check-prefix.sh allowlists is present in the staged tree" \
      "$(comm -13 "$W/r9.hits" "$W/r9.allow" | wc -l | tr -d ' ')" 0
  # (the `|` delimiter, not `/`: the label itself contains slashes)
  printf '%s\n' "$hits" | grep -v '^$' | sed 's|^|     staged /usr/local hit: |'
else
  # C1: the block's input is absent, so the block did not run -- SAY it, and count it. Not a `no`
  # (tarball mode is legal and stays rc 0) and never folded into PASS=: SKIP= is the report of what
  # was NOT run. Greppable prefix so a runner (or a CI log search) can see at a glance that a
  # G-LAUNCH-1 PASS= line in this mode is 14 rows short of the staged total.
  echo
  printf '  \033[33mskip\033[0m R block NOT RUN: L4_PKG_ROOT is unset (no staged tree) -> R1..R9b did NOT run, %s counted row(s) unmeasured (excluded from PASS=, reported as SKIP= below)\n' "$R_ROWS"
fi

# The R_ROWS self-check. Fail-only on purpose (a counted `ok` here would move the staged total, and
# the number the tarball-mode note quotes must be the SAME number): staged mode is the only mode
# that can measure the block's real row count, so it asserts the constant against it. A row added
# or removed without bumping R_ROWS turns THIS red -- otherwise the constant would quietly
# under-report what tarball mode did not run, which is the C1 defect again in a new place.
# The delta is PASS+FAIL -- rows EXECUTED, whatever colour -- not PASS alone: a red row inside the
# block must not look like a row that never ran (measured: with PASS only, the planted-doc run
# reported "ran 13" and turned this row red on top of the real R9 failure).
if [ "$r_ran" = yes ]; then
  [ "$(( (PASS + FAIL) - r_rows0 ))" = "$R_ROWS" ] \
    || no "RBLOCK: R_ROWS=$R_ROWS but the R block ran $(( (PASS + FAIL) - r_rows0 )) counted row(s) (bump R_ROWS in the same commit)"
fi
SKIP=$R_ROWS
[ "$r_ran" = yes ] && SKIP=0

echo; echo "=============================================="
echo "G-LAUNCH-1: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
# Yellow, and only when there is something to say: SKIP is a report, never a failure -- but it must
# not be silent either, and it must never be read as a pass (mirrors run-deb-gates.sh's note).
[ "$SKIP" = 0 ] || printf '  \033[33m%s counted row(s) were NOT run in this mode: SKIP is not PASS\033[0m\n' "$SKIP"
[ "$FAIL" = 0 ] || exit 1
