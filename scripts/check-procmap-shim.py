#!/usr/bin/env python3
"""Compile the PROCMAP_QUERY fallback that patches/darlingserver.patch injects.

`src/process.cpp` uses the PROCMAP_QUERY ioctl when the kernel headers declare it
(Linux >= 6.11) and otherwise compiles a locally declared copy of that UAPI. The
fallback is therefore only built on hosts whose headers predate 6.11 -- the CI
runner, but not a modern dev box -- so nothing else in the repository compiles it
and a typo there can only surface hours into the heavy build (run 38857602258
failed exactly that way, in process.cpp).

This script extracts the guarded block from the patch, wraps it in a harness that
keeps the fallback enabled (no <linux/fs.h>) and compiles it with -Werror, so the
asserts it carries -- sizeof == 104, ioctl number 0xC0686611 and the six
PROCMAP_QUERY_* flag values -- all have to hold. Where the host headers do define
the UAPI it also compares the kernel's own ioctl number and struct size with the
ones we ship, turning "dead code on the dev box" into a drift check; the flag
values are pinned by the fallback harness instead, because the host check cannot
compare them without weakening the pre-6.11 skip detection.

Usage: python3 scripts/check-procmap-shim.py [patches/darlingserver.patch]
"""
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
DEFAULT_PATCH = ROOT / 'patches' / 'darlingserver.patch'
FALLBACK_START = '#ifndef PROCMAP_QUERY'
CXXFLAGS = ('-std=c++17', '-Wall', '-Wextra', '-Werror')
IOCTL_NUMBER = '0xC0686611ul'
STRUCT_SIZE = 104

# The encoded ioctl number only depends on the struct *size*, so neither it nor
# sizeof() would notice a mutated flag: pin every constant the kernel is handed.
FLAGS = (
    ('PROCMAP_QUERY_VMA_READABLE', '0x01'),
    ('PROCMAP_QUERY_VMA_WRITABLE', '0x02'),
    ('PROCMAP_QUERY_VMA_EXECUTABLE', '0x04'),
    ('PROCMAP_QUERY_VMA_SHARED', '0x08'),
    ('PROCMAP_QUERY_COVERING_OR_NEXT_VMA', '0x10'),
    ('PROCMAP_QUERY_FILE_BACKED_VMA', '0x20'),
)
FLAG_ASSERTS = ''.join(f'static_assert({name} == {value}, "{name} changed");\n'
                       for name, value in FLAGS)

# Compiler diagnostics that mean "these headers simply do not have the Linux 6.11
# UAPI" rather than "the code we ship is broken". g++ and clang++ both quote the
# identifier, and g++ uses typographic quotes in a UTF-8 locale, hence the loose
# separators. Everything else must survive as a real failure.
QUOTE = r'[\u2018\u2019\'\"]?'
UAPI_MISSING = re.compile(
    r'PROCMAP_QUERY' + QUOTE + r'\s+was not declared'
    r'|undeclared identifier\s*' + QUOTE + r'PROCMAP_QUERY'
    r'|incomplete type\s*' + QUOTE + r'(?:struct )?procmap_query'
    r'|(?:struct )?procmap_query' + QUOTE + r'\s+used in sizeof')


class ExtractionError(ValueError):
    """The patch does not contain the balanced PROCMAP_QUERY guard block."""


def added_lines(patch_text):
    """Yield the `+`-prefixed lines of a unified diff, `+++` headers excluded."""
    for line in patch_text.splitlines():
        if line.startswith('+') and not line.startswith('+++'):
            yield line[1:]


def extract_fallback(patch_path=DEFAULT_PATCH):
    """Return the added `#ifndef PROCMAP_QUERY` ... `#endif` block of the patch."""
    block = []
    depth = 0
    for line in added_lines(pathlib.Path(patch_path).read_text()):
        stripped = line.strip()
        if not block:
            if stripped != FALLBACK_START:
                continue
            block.append(line)
            depth = 1
            continue
        block.append(line)
        if re.match(r'#\s*(?:if|ifdef|ifndef)\b', stripped):
            depth += 1
        elif re.match(r'#\s*endif\b', stripped):
            depth -= 1
            if depth == 0:
                return '\n'.join(block) + '\n'
    if not block:
        raise ExtractionError(f'{patch_path}: no added "{FALLBACK_START}" line to extract')
    raise ExtractionError(f'{patch_path}: "{FALLBACK_START}" is never closed by a matching #endif')


def find_compiler():
    """Return the first available C++ compiler, or None."""
    return next((found for found in (shutil.which('g++'), shutil.which('clang++')) if found), None)


def compile_source(compiler, source):
    """Compile `source` in a scratch directory; return (ok, combined output)."""
    with tempfile.TemporaryDirectory(prefix='procmap-shim-') as directory:
        path = pathlib.Path(directory) / 'harness.cpp'
        path.write_text(source)
        done = subprocess.run([compiler, *CXXFLAGS, '-o', str(path.with_suffix('.bin')), str(path)],
                              capture_output=True, text=True)
        return done.returncode == 0, (done.stdout + done.stderr).strip()


def host_uapi_predates_6_11(output):
    """True when every error says the headers do not declare the UAPI at all."""
    errors = [line for line in output.splitlines() if re.search(r'\berror:', line)]
    return bool(errors) and all(UAPI_MISSING.search(line) for line in errors)


def check_fallback(compiler, block):
    """Compile the extracted block with the fallback enabled (no <linux/fs.h>)."""
    source = ('#include <sys/ioctl.h>      /* _IOWR */\n'
              '#include <linux/types.h>    /* __u64 / __u32 */\n'
              + block + FLAG_ASSERTS + 'int main() { return 0; }\n')
    ok, output = compile_source(compiler, source)
    if output:
        print(output)
    if not ok:
        print('FAIL: the PROCMAP_QUERY fallback does not compile with -Werror')
        return False
    print('OK: the PROCMAP_QUERY fallback compiles with -Werror')
    return True


def check_host_uapi(compiler):
    """Compare the host's ioctl number and struct size with ours, or skip it.

    The flag values are not compared here: on a pre-6.11 host the identifiers are
    simply absent and a reference to them would turn the expected "skip" into a
    hard failure. The fallback harness pins them instead.
    """
    source = ('#include <linux/fs.h>\n'
              f'static_assert(PROCMAP_QUERY == {IOCTL_NUMBER}, "host ioctl number differs from the fallback");\n'
              f'static_assert(sizeof(struct procmap_query) == {STRUCT_SIZE}, "host struct size differs from the fallback");\n'
              'int main() { return 0; }\n')
    ok, output = compile_source(compiler, source)
    if ok:
        print('OK: host UAPI (>= 6.11) matches the fallback')
        return True
    if host_uapi_predates_6_11(output):
        print('skipped: host headers predate Linux 6.11')
        return True
    print(output)
    print('FAIL: the host UAPI differs from the fallback we ship')
    return False


def main(argv=None):
    arguments = sys.argv[1:] if argv is None else list(argv)
    patch = pathlib.Path(arguments[0]) if arguments else DEFAULT_PATCH
    try:
        block = extract_fallback(patch)
    except (ExtractionError, OSError) as error:
        print(f'FAIL: {error}')
        return 1
    print(f'Extracted {len(block.splitlines())} lines from {patch}')
    compiler = find_compiler()
    if compiler is None:
        print('FAIL: neither g++ nor clang++ is available')
        return 1
    print(f'Using {compiler}')
    if not check_fallback(compiler, block):
        return 1
    return 0 if check_host_uapi(compiler) else 1


if __name__ == '__main__':
    sys.exit(main())
