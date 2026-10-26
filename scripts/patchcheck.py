#!/usr/bin/env python3
"""Reject patches that add the same block twice, back to back.

A merge that keeps both sides of a hunk leaves the patch applying cleanly, so
`git apply --check` passes and only the compiler notices: the patched source declares
the same block twice (`X11Window.m: error: redefinition of 'windowPID'`, run #66).

The two copies of a kept-both-sides merge are adjacent: nothing but blank added lines
separates them. Repetition that a patch legitimately carries (the same three-line body
in four sibling functions, a licence header in two new files) always has the copied
function's own lines in between, which is what keeps those cases quiet.
"""
import sys
from pathlib import Path

# Four lines is long enough that an accidental repeat is a real duplicate: two
# sibling calls or two mirrored setters differ within their first four lines.
MIN_LINES = 4
# Adjacent copies sit a handful of lines apart; this only bounds the search.
MAX_DISTANCE = 40


def sections(text):
    """Split a patch into (target file, [(0-based patch line, line)]) per diff section."""
    sections = []
    for number, line in enumerate(text.split('\n')):
        if line.startswith('diff --git '):
            fields = line.split()
            sections.append((fields[-1][2:] if len(fields) >= 4 else '?', []))
        elif sections:
            sections[-1][1].append((number, line))
    return sections


def added_lines(entries):
    """The added lines of a section as (0-based patch line, content without the marker)."""
    return [(number, line[1:]) for number, line in entries
            if line.startswith('+') and not line.startswith('+++')]


def _separated_by_blank_added_lines(lines, after, before):
    """True when patch lines [after, before) are blank additions only."""
    return all(line == '+' for line in lines[after:before])


def duplicate_blocks(text, min_lines=MIN_LINES, max_distance=MAX_DISTANCE):
    """Added blocks repeated back to back, with no other patch line in between.

    Returns (target file, first patch line, second patch line, block length, first line
    text) with 1-based line numbers, one entry per duplicated block.
    """
    lines = text.split('\n')
    found = {}
    for target, entries in sections(text):
        added = added_lines(entries)
        positions = {}
        for position, (number, content) in enumerate(added):
            if content.strip():
                positions.setdefault(content, []).append(position)
        for content, places in positions.items():
            for first, second in zip(places, places[1:]):
                if added[second][0] - added[first][0] > max_distance:
                    continue
                length = 0
                while (second + length < len(added)
                       and added[first + length][1] == added[second + length][1]
                       and added[first + length][1].strip()):
                    length += 1
                # Overlapping matches come from periodic content, not from a doubled block.
                if length < min_lines or second < first + length:
                    continue
                if not _separated_by_blank_added_lines(lines, added[first][0] + length,
                                                       added[second][0]):
                    continue
                key = (target, added[first][0] + 1)
                found.setdefault(key, (target, added[first][0] + 1, added[second][0] + 1,
                                       length, content.strip()))
    return [found[key] for key in sorted(found)]


def describe(finding):
    target, first, second, length, sample = finding
    return (f'{target}: the same {length}-line block is added at patch lines {first} and {second} '
            f'("{sample[:60]}"): a merge kept both copies')


def main(argv):
    if not argv:
        print(__doc__.strip().splitlines()[0] + '\nusage: patchcheck.py PATCH...', file=sys.stderr)
        return 2
    problems = [(path, describe(finding)) for path in map(Path, argv)
                for finding in duplicate_blocks(path.read_text())]
    for path, problem in problems:
        print(f'{path}: {problem}')
    if problems:
        return 1
    print(f'PASS: {len(argv)} patch(es) add no block twice')
    return 0


if __name__ == '__main__':
    raise SystemExit(main(sys.argv[1:]))
