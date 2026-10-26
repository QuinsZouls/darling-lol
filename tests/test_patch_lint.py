"""A patch must never add the same block twice: only the compiler would notice."""
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
import patchcheck  # noqa: E402


def patch(*files):
    """Render raw patch text from (target, lines) pairs."""
    return '\n'.join(
        f'diff --git a/{target} b/{target}\n--- a/{target}\n+++ b/{target}\n@@ -1,3 +1,3 @@\n'
        + '\n'.join(lines)
        for target, lines in files)


DUPLICATED = [
    '+    }',
    '+',
    "+    /* Keep Cocoa's process identifier available to cross-process activation. */",
    '+    unsigned long windowPID = (unsigned long)getpid();',
    '+    XChangeProperty(_display, _window, XInternAtom(_display, "_NET_WM_PID", False),',
    '+                    XA_CARDINAL, 32, PropModeReplace,',
    '+                    (unsigned char *)&windowPID, 1);',
    '+',
    "+    /* Keep Cocoa's process identifier available to cross-process activation. */",
    '+    unsigned long windowPID = (unsigned long)getpid();',
    '+    XChangeProperty(_display, _window, XInternAtom(_display, "_NET_WM_PID", False),',
    '+                    XA_CARDINAL, 32, PropModeReplace,',
    '+                    (unsigned char *)&windowPID, 1);',
    '+',
    '     [self syncDelegateProperties];',
]

# Two similar calls with different arguments: the shape of the real darlingserver patch.
SIBLING_CALLS = [
    '+        if ((flags & VM_FLAGS_ANYWHERE) != 0) {',
    '+            map_addr = dtape_hooks->task_map_file(',
    '+                target_map->dtape_task->context,',
    '+                desc->memfd,',
    '+                dtape_byte_count_to_page_count_round_up(initial_size),',
    '+                prot, 0, page_off, dtape_memory_flag_none);',
    '+        } else {',
    '+            map_addr = dtape_hooks->task_map_file(',
    '+                target_map->dtape_task->context,',
    '+                desc->memfd,',
    '+                dtape_byte_count_to_page_count_round_up(initial_size),',
    '+                prot, (uintptr_t)*address, page_off,',
    '+                dtape_memory_flag_fixed | dtape_memory_flag_overwrite);',
    '+        }',
]

# Two mirrored setters: the shape of the real metal patch.
MIRRORED_SETTERS = [
    '+static void RevokeLayoutItems(MTLVertexBufferLayoutDescriptorArray* array, uint32_t* word)',
    '+{',
    '+    if (!array) return;',
    '+    array->_owner = nil;',
    '+    for (uint32_t bits = array->_present; bits; bits &= bits - 1) {',
    '+        const int i = __builtin_ctz(bits);',
    '+    }',
    '+}',
    '+static void RevokeAttributeItems(MTLVertexAttributeDescriptorArray* array, uint32_t* word)',
    '+{',
    '+    if (!array) return;',
    '+    array->_owner = nil;',
    '+    for (uint32_t bits = array->_present; bits; bits &= bits - 1) {',
    '+        const int i = __builtin_ctz(bits);',
    '+    }',
    '+}',
]


class DuplicateBlockTests(unittest.TestCase):
    def test_kept_both_sides_block_is_reported_once(self):
        findings = patchcheck.duplicate_blocks(patch(('AppKit/X11Window.m', DUPLICATED)))
        self.assertEqual(len(findings), 1, findings)
        target, first, second, length, sample = findings[0]
        self.assertEqual(target, 'AppKit/X11Window.m')
        self.assertGreaterEqual(length, 4)
        self.assertLess(second - first, 10)
        self.assertIn('process identifier', sample)

    def test_similar_sibling_calls_are_not_reported(self):
        self.assertEqual(patchcheck.duplicate_blocks(patch(('xnu/vm.c', SIBLING_CALLS))), [])

    def test_mirrored_setters_are_not_reported(self):
        self.assertEqual(patchcheck.duplicate_blocks(patch(('metal/vertex.m', MIRRORED_SETTERS))), [])

    def test_the_same_block_in_two_files_is_not_reported(self):
        header = ['+/* Darling is free software: you can redistribute it and/or modify',
                  '+ * it under the terms of the GNU General Public License as published by',
                  '+ * the Free Software Foundation, either version 3 of the License, or',
                  '+ * (at your option) any later version. */']
        text = patch(('a/first.c', header), ('a/second.c', header))
        self.assertEqual(patchcheck.duplicate_blocks(text), [])

    def test_sibling_functions_with_the_same_body_are_not_reported(self):
        self.assertEqual(patchcheck.duplicate_blocks(patch(('src/sandbox/sandbox.c',
                                                            SIBLING_FUNCTIONS))), [])

    def test_a_context_line_between_the_copies_is_not_a_duplicate(self):
        body = ['+    if (!array) return;', '+    array->_owner = nil;',
                '+    word[0] = 0;', '+    word[1] = 0;']
        text = patch(('a/twice.c', body + ['     [self syncDelegateProperties];'] + body))
        self.assertEqual(patchcheck.duplicate_blocks(text), [])

    def test_three_repeated_lines_below_the_threshold_are_ignored(self):
        text = patch(('a/short.c', ['+    x = 1;', '+    y = 2;', '+    z = 3;', '+',
                                    '+    x = 1;', '+    y = 2;', '+    z = 3;']))
        self.assertEqual(patchcheck.duplicate_blocks(text), [])


# The same three-line body in four sibling functions: the real sandbox patch repeats it
# with each copied function's own signature between the copies.
SIBLING_FUNCTIONS = [
    '+    if (ext_token != NULL) {',
    '+        *ext_token = strdup("darling-sandbox-stub");',
    '+    }',
    '+    return 0;',
    ' }',
    ' ',
    ' int sandbox_issue_fs_extension(const char *path, uint64_t flags, char **ext_token)',
    ' {',
    '-    return -1;',
    '+    if (ext_token != NULL) {',
    '+        *ext_token = strdup("darling-sandbox-stub");',
    '+    }',
    '+    return 0;',
    ' }',
]


class RepositoryPatchTests(unittest.TestCase):
    def test_every_pinned_patch_is_free_of_duplicate_blocks(self):
        problems = []
        for path in sorted((ROOT / 'patches').glob('*.patch')):
            problems += [f'{path.name}: {patchcheck.describe(finding)}'
                         for finding in patchcheck.duplicate_blocks(path.read_text())]
        self.assertEqual(problems, [], '\n'.join(problems))


if __name__ == '__main__':
    unittest.main()
