#!/usr/bin/env python3
"""Build the G-LAUNCH-1 launcher-detection fixture: a /usr-prefixed
darlingserver / darling-coredump / darling, string-patched from the REAL published
v0.1.0 x86-64 host ELFs, length-preserving (NUL-padded) so no other .rodata slot
shifts. Same technique as the G-PREFIX-1 sweep (PLAN 7.5).

Nothing here executes or understands the binaries: it is a byte patch, so it runs on
any architecture, and it is deliberately a HARDER input than a real build would be --
the concatenated literals keep /usr/local, so both prefixes are present as substrings
in one binary (that is the C28 property the wrapper's anchored cross-check must survive).

usage: launch-mkusr.py SRC_BIN_DIR OUT_DIR
  SRC_BIN_DIR holds the published tarball's usr/local/bin/{darling,darlingserver,darling-coredump}.
  The harness extracts those three from the release tarball before calling this.
"""
import pathlib
import sys

if len(sys.argv) != 3:
    sys.exit("usage: launch-mkusr.py SRC_BIN_DIR OUT_DIR")
SRC = pathlib.Path(sys.argv[1])
OUT = pathlib.Path(sys.argv[2])
OUT.mkdir(parents=True, exist_ok=True)


def pad(old: bytes, new: bytes) -> bytes:
    assert len(new) <= len(old), (old, new)
    return new + b"\x00" * (len(old) - len(new))


RULES = {
    "darlingserver": [(b"/usr/local/libexec/darling", b"/usr/libexec/darling")],
    "darling-coredump": [(b"/usr/local/libexec/darling", b"/usr/libexec/darling")],
    # `darling`: ONLY the execl() target moves; the three guest literals stay byte-identical.
    "darling": [(b"/usr/local/bin/darlingserver", b"/usr/bin/darlingserver")],
}

for name, rules in RULES.items():
    src = SRC / name
    if not src.is_file():
        sys.exit("launch-mkusr: FATAL missing fixture ELF: %s (extract the published tarball first)" % src)
    data = src.read_bytes()
    n = 0
    for old, new in rules:
        # replace the STANDALONE literal only: NUL-delimited, so the concatenated
        # "mldr!<LIBEXEC>/usr/libexec/darling/vchroot" keeps its guest half intact.
        needle = b"\x00" + old + b"\x00"
        n += data.count(needle)
        data = data.replace(needle, b"\x00" + pad(old, new) + b"\x00")
    if n == 0:
        # A fixture that silently stays /usr/local-compiled makes case I inconclusive
        # (the cross-check rejects it) -- that was the PASS=64 FAIL=5 run, so fail loudly.
        sys.exit("launch-mkusr: FATAL no standalone %r in %s: wrong or already-patched input"
                 % (rules[0][0], src))
    (OUT / name).write_bytes(data)
    (OUT / name).chmod(0o755)
    print(f"{name}: {n} standalone literal(s) patched, {len(data)} bytes")
