#!/usr/bin/env bash
# packaging/testdata/run-gates.sh -- the T1 gate battery: self-contained, hermetic, asserting.
#
# Run from the repo root:
#
#     bash packaging/testdata/run-gates.sh
#
# Everything it needs it creates itself, inside one private `mktemp -d` workdir, and it reads
# nothing the harness did not write (T1 review MAJOR-1: the pre-review battery compared a rendered
# Depends against a *leftover* /tmp/render-eq it neither created nor shipped, and planted its
# snippet at /tmp/re/render-eq -- a typo -- so a clean box scored 48/49). The two stale leftovers
# are removed on entry so a run below cannot fall back to them.
#
# The dependency lists are additionally compared against the PLAN's own fenced lists when
# T1_PLAN_FILE points at PLAN.md; the PLAN is not in this repo, so the check is skipped otherwise:
#
#     T1_PLAN_FILE=/path/to/PLAN.md bash packaging/testdata/run-gates.sh
#
# Companions: packaging/testdata/run-mutations.sh (the two mutation tables, self-asserting, with a
# negative control) and packaging/testdata/state-probe.sh (the transient current-state probe).
set -u

if [ ! -f packaging/common/stage.sh ] || [ ! -d packaging/testdata ]; then
  echo "run-gates: run me from the repo root (no packaging/ in $PWD)" >&2
  exit 2
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/darling-t1-gates.XXXXXX")
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

for stale in "${TMPDIR:-/tmp}/render-eq" "${TMPDIR:-/tmp}/plan-bookworm.verbatim"; do
  [ -e "$stale" ] || continue
  printf 'note: dropping the pre-review leftover %s (MAJOR-1)\n' "$stale"
  rm -rf -- "$stale"
done

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
no()   { fail=$((fail+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
chk()  { if [ -z "$2" ]; then no "$1: EMPTY result (command failed)"; elif [ "$2" = "$3" ]; then ok "$1 ($2)"; else no "$1: got '$2', want '$3'"; fi; }
skip() { printf '  \033[33mSKIP\033[0m %s\n' "$1"; }
sec()  { printf '\n\033[1m%s\033[0m\n' "$1"; }

# the pattern this file searches for, built so that the file does not itself contain it
space=' '
c19pat="grep${space}-R"

sec "G-STATIC-1  shellcheck -S warning + bash -n / sh -n over every script"
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck -S warning packaging/common/*.sh packaging/testdata/*.sh; then ok "shellcheck: 0 findings"; else no "shellcheck findings"; fi
else
  skip "shellcheck is not installed"
fi
syn=0
for f in packaging/common/*.sh packaging/testdata/*.sh; do
  bash -n "$f" 2>/dev/null || { sh -n "$f" 2>/dev/null || { no "syntax error: $f"; syn=$((syn+1)); }; }
done
chk "bash -n / sh -n: 0 syntax errors" "$syn" 0

sec "G-STATIC-3  pkg-version.sh reproduces the PLAN 6 table"
rc=0; out=$(./packaging/common/pkg-version.sh v0.1.0 v0.2.0-rc1 v1.0.0 0.1.0 v0.1.0-3-gabc1234 2>/dev/null) || rc=$?
printf '%s\n' "$out" | sed 's/^/    /'
chk "5 valid tags -> exit 0" "$rc" 0
chk "rows printed" "$(printf '%s\n' "$out" | wc -l)" 5
chk "v0.1.0 deb row" "$(printf '%s\n' "$out" | awk -F'\t' '$1=="v0.1.0"{print $3}')" "0.1.0+lol-1"
chk "v0.1.0 rpm row" "$(printf '%s\n' "$out" | awk -F'\t' '$1=="v0.1.0"{print $4}')" "0.1.0-1.lol.fc41"
chk "v0.1.0 arch row" "$(printf '%s\n' "$out" | awk -F'\t' '$1=="v0.1.0"{print $5}')" "0.1.0-1"
chk "0.2.0-rc1 -> 0.2.0 (suffix stripped)" "$(printf '%s\n' "$out" | awk -F'\t' '$1=="v0.2.0-rc1"{print $2}')" "0.2.0"
chk "bare 0.1.0 accepted" "$(printf '%s\n' "$out" | awk -F'\t' '$1=="0.1.0"{print $2}')" "0.1.0"
chk "describe suffix 0.1.0-3-gabc1234 -> 0.1.0" "$(printf '%s\n' "$out" | awk -F'\t' '$1=="v0.1.0-3-gabc1234"{print $2}')" "0.1.0"
./packaging/common/pkg-version.sh not-a-tag >/dev/null 2>"$WORK/verr"; chk "garbage fails loudly" "$?" 1
chk "garbage names the input" "$(grep -c "not-a-tag" "$WORK/verr")" 1
chk "garbage emits NO 0.0.0" "$(grep -c '0\.0\.0' "$WORK/verr")" 0
chk "a bare hash -> the dev form" "$(./packaging/common/pkg-version.sh 2d75d58 | cut -d. -f1-2)" "0.0"

sec "G-STATIC-4/5  render.sh: one list -> three syntaxes, no drift, no tokens"
for fam in deb rpm arch; do
  ./packaging/common/render.sh --family "$fam" --fixture > "$WORK/$fam.out" || no "render $fam"
done
if ! grep -qE '@[A-Za-z_]+@' "$WORK/deb.out" "$WORK/rpm.out" "$WORK/arch.out" && \
   ! grep -qF '${binary:Version}' "$WORK/deb.out" "$WORK/rpm.out" "$WORK/arch.out"; then ok "no @TOKEN@ / \${binary:Version} left"; else no "token left"; fi
chk "deb: exactly one Depends line" "$(grep -c '^Depends: ' "$WORK/deb.out")" 1
chk "deb: Depends == deps.deb.noble" \
  "$(diff <(sed -n 's/^Depends: //p' "$WORK/deb.out" | tr ',' '\n' | sed 's/^ *//;s/ *$//' | sort -u) <(grep -v '^#' packaging/common/deps.deb.noble | sed 's/[[:space:]]*$//' | grep -v '^$' | sort -u) | wc -l)" 0
chk "deb: Conflicts == conflicts.txt" \
  "$(diff <(sed -n 's/^Conflicts: //p' "$WORK/deb.out" | tr ',' '\n' | sed 's/^ *//;s/ *$//' | sort -u) <(grep -v '^#' packaging/common/conflicts.txt | sed 's/[[:space:]]*$//' | grep -v '^$' | sort -u) | wc -l)" 0
chk "rpm: one Requires per entry" "$(grep -c '^Requires: ' "$WORK/rpm.out")" 27
chk "rpm: Requires == deps.rpm.fc41" \
  "$(diff <(sed -n 's/^Requires: //p' "$WORK/rpm.out" | sort -u) <(grep -v '^#' packaging/common/deps.rpm.fc41 | sed 's/[[:space:]]*$//' | grep -v '^$' | sort -u) | wc -l)" 0
chk "rpm: Version: has no dash" "$(grep -c '^Version: .*-.*$' "$WORK/rpm.out")" 0
chk "arch: one depend per entry" "$(grep -c '^depend = ' "$WORK/arch.out")" 25
chk "arch: depend == deps.arch" \
  "$(diff <(sed -n 's/^depend = //p' "$WORK/arch.out" | sort -u) <(grep -v '^#' packaging/common/deps.arch | sed 's/[[:space:]]*$//' | grep -v '^$' | sort -u) | wc -l)" 0
chk "arch: pkgver contains a dash (libalpm)" "$(grep -c '^pkgver = [^-]*-' "$WORK/arch.out")" 1
if command -v dpkg-deb >/dev/null 2>&1; then
  mkdir -p "$WORK/ctl/DEBIAN"; cp "$WORK/deb.out" "$WORK/ctl/DEBIAN/control"
  if dpkg-deb -b "$WORK/ctl" "$WORK/t1.deb" 2>/dev/null; then
    chk "dpkg-deb accepts the rendered control file" "$(dpkg-deb -f "$WORK/t1.deb" Version)" "0.1.0+lol-1"
  else no "dpkg-deb rejected the rendered control file"; fi
else
  skip "dpkg-deb is not installed"
fi
chk "the version really comes from the tag (--tag v9.9.9)" \
  "$(./packaging/common/render.sh --family deb --tag v9.9.9 --fixture | sed -n 's/^Version: //p')" "9.9.9+lol-1"

sec "G-STATIC-5b  render.sh accepts the PLAN's inline-comment style (hermetic -- MAJOR-1)"
# Build the snippet INSIDE the gate: copy the worktree's own packaging/common into the private
# workdir, give its bookworm list the inline-comment style PLAN 8.1 prints it with, and render
# *that*. Both sides of the comparison are produced by this run; nothing is read from /tmp.
mkdir -p "$WORK/eq"
cp packaging/common/*.sh packaging/common/*.txt packaging/common/deps.* "$WORK/eq/"
sed 's/^\([^#].*[^[:space:]]\)[[:space:]]*$/\1    # inline note (PLAN 8.1 style)/' \
  packaging/common/deps.deb.bookworm > "$WORK/eq/deps.deb.bookworm"
if cmp -s "$WORK/eq/deps.deb.bookworm" packaging/common/deps.deb.bookworm; then no "the inline-comment variant is identical to the delivered file (mutation is vacuous)"; else ok "the inline-comment variant differs from the delivered file"; fi
chk "inline comments are a legal input: same Depends, 0 diff lines" \
  "$(diff <(sh "$WORK/eq/render.sh" --family deb --release bookworm --fixture | sed -n 's/^Depends: //p') \
          <(./packaging/common/render.sh --family deb --release bookworm --fixture | sed -n 's/^Depends: //p') | wc -l)" 0
chk "no '#' leaks into the rendered Depends" \
  "$(sh "$WORK/eq/render.sh" --family deb --release bookworm --fixture | sed -n 's/^Depends: //p' | grep -c '#' || true)" 0

sec "G-STATIC-6  stage.sh over the hostile-shape fixture"
rm -rf "$WORK/fix" && bash packaging/testdata/mkfixture.sh "$WORK/fix" >/dev/null && sh packaging/common/stage.sh "$WORK/fix/root" "$WORK/fix/out" >"$WORK/stage.log"
for a in files.all files.quoted files.emptydirs files.launcher files.runtime count.runtime count.launcher installed-size-kib; do
  [ -s "$WORK/fix/out/$a" ] || no "artifact missing/empty: $a"
done
ok "all 8 artifacts present and non-empty"
chk "files.runtime == expect-runtime (independent computation)" \
  "$(diff <(sort "$WORK/fix/out/files.runtime") <(sort "$WORK/fix/expect-runtime") | wc -l)" 0
chk "runtime + launcher == all" \
  "$(diff <(cat "$WORK/fix/out/files.runtime" "$WORK/fix/out/files.launcher" | sort) <(sort "$WORK/fix/out/files.all") | wc -l)" 0
chk "C18: files.runtime ∩ files.launcher = empty" \
  "$(comm -12 <(sort "$WORK/fix/out/files.runtime") <(sort "$WORK/fix/out/files.launcher") | wc -l)" 0
chk "files.launcher owns usr/lib/darling-lol (C18)" "$(grep -c '^/usr/lib/darling-lol/' "$WORK/fix/out/files.launcher")" 6
chk "count.runtime matches the file" "$(cat "$WORK/fix/out/count.runtime")" "$(wc -l < "$WORK/fix/out/files.runtime" | tr -d ' ')"
chk "count.launcher matches the file" "$(cat "$WORK/fix/out/count.launcher")" "$(wc -l < "$WORK/fix/out/files.launcher" | tr -d ' ')"
chk "no relative paths in files.all" "$(grep -cv '^/' "$WORK/fix/out/files.all")" 0
chk "the 4 %-escapes survive verbatim" "$(grep -cE '%(21\.menu|7c-i\.ri|3f-i\.ri|3d%3d%3d-i\.ri)' "$WORK/fix/out/files.quoted")" 4
chk "the space path survives quoted" "$(grep -cF '"/usr/libexec/darling/System/Library/User Template"' "$WORK/fix/out/files.quoted")" 1
n=0; while IFS= read -r p; do [ -n "$p" ] && grep -qxF "$p" "$WORK/fix/out/files.all" && n=$((n+1)); done < <(printf '%s\n' /usr/bin/darling '/usr/libexec/darling/usr/bin/write' '/usr/libexec/darling/System/Library/User Template' '/usr/libexec/darling/System/Library/CoreServices/Menu Extras/%21.menu' '/usr/libexec/darling/usr/share/ipv6only%7c-i.ri' '/usr/libexec/darling/usr/share/eql%3f-i.ri' '/usr/libexec/darling/usr/share/%3d%3d%3d-i.ri' '/usr/libexec/darling/private/etc/machine-id' '/usr/libexec/darling/private/tmp')
chk "all 9 hostile shapes listed" "$n" 9
chk "stage.sh exits non-zero on usr/local (step 1)" \
  "$(rm -rf "$WORK/neg" && cp -a "$WORK/fix" "$WORK/neg" && mkdir -p "$WORK/neg/root/usr/local/x"; sh packaging/common/stage.sh "$WORK/neg/root" "$WORK/neg/out2" >/dev/null 2>&1; echo $?)" 1
chk "stage.sh exits non-zero when darling is not 4755 (step 2)" \
  "$(rm -rf "$WORK/neg2" && cp -a "$WORK/fix" "$WORK/neg2" && chmod 755 "$WORK/neg2/root/usr/bin/darling"; sh packaging/common/stage.sh "$WORK/neg2/root" "$WORK/neg2/out2" >/dev/null 2>&1; echo $?)" 1
chk "files.quoted is NOT what files.all is (quotes are real)" "$(grep -c '^"' "$WORK/fix/out/files.quoted")" "$(wc -l < "$WORK/fix/out/files.quoted" | tr -d ' ')"

sec "determinism  stage.sh twice -> byte-identical lists (MINOR-2: measured by hand, now gated)"
sh packaging/common/stage.sh "$WORK/fix/root" "$WORK/det2/out" >/dev/null
chk "same fixture, 2 runs: the 8 artifacts are byte-identical" "$(diff -r "$WORK/fix/out" "$WORK/det2/out" | wc -l)" 0
chk "same fixture, 2 runs: sha256 of files.* + count.* identical" \
  "$( (cd "$WORK/fix/out" && sha256sum files.all files.quoted files.emptydirs files.launcher files.runtime count.runtime count.launcher) | diff - <(cd "$WORK/det2/out" && sha256sum files.all files.quoted files.emptydirs files.launcher files.runtime count.runtime count.launcher) | wc -l)" 0
rm -rf "$WORK/det3" && bash packaging/testdata/mkfixture.sh "$WORK/det3" >/dev/null
sh packaging/common/stage.sh "$WORK/det3/root" "$WORK/det3/out" >/dev/null
chk "two independently built fixtures: the 8 artifacts are byte-identical" "$(diff -r "$WORK/fix/out" "$WORK/det3/out" | wc -l)" 0

sec "G-PREFIX-1  check-prefix.sh: the positive run"
rm -rf "$WORK/pfx" && bash packaging/testdata/mkprefixfixture.sh "$WORK/pfx" >/dev/null
sh packaging/common/check-prefix.sh "$WORK/pfx/root" "$WORK/pfx/files.all" >"$WORK/pfx.log" 2>&1; chk "positive exit" "$?" 0
chk "'PREFIX: OK' printed" "$(grep -c '^PREFIX: OK$' "$WORK/pfx.log")" 1
chk "guest count reported" "$(grep -c 'guest-side files containing' "$WORK/pfx.log")" 1

sec "info  current-state probe: the fixture pre-applies T8's fix, the real file does not"
prc=0; sh packaging/testdata/state-probe.sh >"$WORK/probe.log" 2>&1 || prc=$?
sed 's/^/    /' "$WORK/probe.log"
if [ "$prc" = 0 ] && grep -qE 'documented state OK|T8-LANDED' "$WORK/probe.log"; then
  ok "probe reports a documented state (rc=$prc)"
else
  no "probe is in an undocumented state (rc=$prc)"
fi

sec "acceptance: C19 / step ordering / no hard-coded version"
chk "check-prefix.sh is called from step 3b (after files.all)" \
  "$(awk '/files.all$/ {a=NR} /check-prefix.sh/ {b=NR} END {print (b>a) ? "later" : "earlier"}' packaging/common/stage.sh)" later
chk "no recursive grep in any packaging script (C19)" "$(grep -hF "$c19pat" packaging/common/*.sh packaging/testdata/*.sh | grep -vc '^#' || true)" 0
# scoped to packaging/common/ on purpose: that is the TASKS T1 criterion ("No file in
# packaging/common/ contains a hard-coded version string"). The fixtures and this harness must
# name concrete versions -- that is what they assert against.
chk "no hard-coded package version in packaging/common (comments excluded)" \
  "$(grep -vE '^[[:space:]]*#' packaging/common/*.sh | grep -cE '[^0-9]0\.9\.9|0\.1\.0\+lol|v0\.1\.0')" 0
chk "every file ends with a newline" "$(for f in packaging/common/* packaging/testdata/*; do [ -n "$(tail -c1 "$f")" ] && echo x; done | wc -l)" 0

if [ -n "${T1_PLAN_FILE:-}" ] && [ -r "${T1_PLAN_FILE:-}" ]; then
  sec "G-STATIC-5c  deps.* + conflicts.txt == the PLAN's source-of-truth fences"
  cat > "$WORK/checkdeps.py" <<'PY'
#!/usr/bin/env python3
"""Compare packaging/common/deps.* and conflicts.txt against the PLAN.md fenced lists."""
import re, sys, pathlib

plan = pathlib.Path(sys.argv[1])
text = plan.read_text()
blocks = {}
inside, buf = False, []
for l in text.split("\n"):
    if l.strip().startswith("```"):
        if inside:
            inside = False
            if buf and buf[0].startswith("# packaging/common/"):
                blocks[buf[0].strip()] = buf[1:]
            buf = []
        else:
            inside, buf = True, []
        continue
    if inside:
        buf.append(l)

def clean(xs):
    out = []
    for l in xs:
        l = re.sub(r"\s*#.*$", "", l)
        l = re.sub(r"\s+$", "", l)
        if l:
            out.append(l)
    return out

rc = 0
for name in ("deps.deb.noble", "deps.deb.bookworm", "deps.rpm.fc41", "deps.arch"):
    key = "# packaging/common/" + name
    assert key in blocks, "fence not found in the PLAN: " + key
    want = clean(blocks[key])
    have = clean(pathlib.Path("packaging/common/" + name).read_text().split("\n"))
    print("%-20s PLAN=%3d ours=%3d  %s" % (name, len(want), len(have),
          "IDENTICAL (order+content)" if want == have else "DIFFERS"))
    if want != have:
        rc = 1

i = text.index("Conflicts: darling, darling-core")
seg = text[i:text.index("Breaks:", i)]
names = [n.strip() for n in seg.replace("Conflicts:", " ").replace("\n", " ").split(",") if n.strip()]
have = clean(pathlib.Path("packaging/common/conflicts.txt").read_text().split("\n"))
print("%-20s PLAN=%3d ours=%3d  %s" % ("conflicts.txt", len(names), len(have),
      "IDENTICAL" if names == have else "DIFFERS"))
if names != have:
    rc = 1

for p in pathlib.Path("packaging/common").glob("deps.*"):
    bad = [l for l in clean(p.read_text().split("\n")) if "pcre" in l.lower()]
    assert not bad, (p, bad)
print("libpcre absent from every deps.* entry (only in comments): OK")
sys.exit(rc)
PY
  python3 "$WORK/checkdeps.py" "$T1_PLAN_FILE" >"$WORK/deps.log" 2>&1 || true
  grep 'IDENTICAL' "$WORK/deps.log" | sed 's/^/    /'
  chk "deps.* + conflicts.txt == the PLAN source lists" "$(grep -c 'IDENTICAL' "$WORK/deps.log")" 5
else
  skip "no T1_PLAN_FILE: the PLAN-pin check (the PLAN is not in this repo)"
fi

sec "SUMMARY"
printf '  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ] || exit 1
