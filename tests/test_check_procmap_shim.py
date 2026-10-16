"""Exercise the PROCMAP_QUERY fallback checker against the real patch.

The checker is the only thing that compiles the fallback guarded by
`#ifndef PROCMAP_QUERY` in patches/darlingserver.patch, so these tests pin both
its extraction contract and its ability to fail on a mutated copy of the patch.
"""
import contextlib
import importlib.util
import io
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'scripts' / 'check-procmap-shim.py'
sys.path.insert(0, str(SCRIPT.parent))

# The script is named with a hyphen (so it reads as a command) and therefore cannot
# be imported by name: load it by path under the module name the tests use.
spec = importlib.util.spec_from_file_location('check_procmap_shim', SCRIPT)
check_procmap_shim = importlib.util.module_from_spec(spec)
sys.modules['check_procmap_shim'] = check_procmap_shim
spec.loader.exec_module(check_procmap_shim)


PATCH = ROOT / 'patches' / 'darlingserver.patch'
COMPILER = check_procmap_shim.find_compiler()
FALLBACK_START = check_procmap_shim.FALLBACK_START
IOCTL_DEFINE = "#define PROCMAP_QUERY _IOWR('f', 17, struct procmap_query)"
SIZE_ASSERT = 'sizeof(struct procmap_query) == 104'
NUMBER_ASSERT = 'static_assert(PROCMAP_QUERY == 0xC0686611ul'
# Real g++ (12) diagnostics for headers that do not declare the UAPI at all.
PREDATES_OUTPUT = (
    "/tmp/harness.cpp:2:15: error: \u2018PROCMAP_QUERY\u2019 was not declared in this scope\n"
    "/tmp/harness.cpp:3:15: error: invalid application of \u2018sizeof\u2019 to incomplete "
    "type \u2018procmap_query\u2019\n")


def write_patch(directory, text):
    """Write `text` to a patch file inside `directory` and return its path."""
    path = Path(directory) / 'darlingserver.patch'
    path.write_text(text)
    return path


def swap_member_names(text, first, second):
    """Swap the two `__u64 <name>;` struct member declarations of `text`.

    A renamed member keeps sizeof, the ioctl number and every flag value identical,
    so only the offset asserts notice it. The placeholder step keeps the two
    sequential substitutions from collapsing into a single name.
    """
    swapped = (text
               .replace(f'__u64 {first};', '__u64 vma_swap_placeholder;')
               .replace(f'__u64 {second};', f'__u64 {first};')
               .replace('__u64 vma_swap_placeholder;', f'__u64 {second};'))
    assert swapped != text, 'the swap mutation must change the patch text'
    return swapped


def patch_without_block_end():
    """The real patch, minus the `+#endif` that closes the fallback guard."""
    lines = PATCH.read_text().splitlines(keepends=True)
    start = next(index for index, line in enumerate(lines)
                 if line.rstrip('\n') == '+' + FALLBACK_START)
    # The guard contains no nested preprocessor conditions, so the first `+#endif`
    # after the marker is the one that closes the block.
    end = next(index for index in range(start + 1, len(lines))
               if lines[index].rstrip('\n') == '+#endif')
    del lines[end]
    return ''.join(lines)


class ExtractFallbackTests(unittest.TestCase):
    def test_real_patch_block_has_the_uapi_and_the_asserts(self):
        block = check_procmap_shim.extract_fallback(PATCH)
        self.assertIn(IOCTL_DEFINE, block)
        self.assertIn('static_assert(' + SIZE_ASSERT, block)
        self.assertIn(NUMBER_ASSERT, block)

    def test_block_is_only_the_guarded_region(self):
        block = check_procmap_shim.extract_fallback(PATCH)
        lines = block.splitlines()
        self.assertEqual(lines[0].strip(), FALLBACK_START)
        self.assertEqual(lines[-1].strip(), '#endif')
        self.assertNotIn('#include', block)
        self.assertIn('struct procmap_query {', block)

    def test_path_override_reads_that_file(self):
        with tempfile.TemporaryDirectory() as directory:
            copy = write_patch(directory, PATCH.read_text())
            self.assertEqual(check_procmap_shim.extract_fallback(copy),
                             check_procmap_shim.extract_fallback(PATCH))

    def test_unclosed_marker_raises(self):
        with tempfile.TemporaryDirectory() as directory:
            path = write_patch(directory, patch_without_block_end())
            with self.assertRaises(check_procmap_shim.ExtractionError) as caught:
                check_procmap_shim.extract_fallback(path)
        self.assertIn('never closed', str(caught.exception))

    def test_missing_marker_raises(self):
        with tempfile.TemporaryDirectory() as directory:
            path = write_patch(directory,
                               'diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n+unrelated\n')
            with self.assertRaises(check_procmap_shim.ExtractionError) as caught:
                check_procmap_shim.extract_fallback(path)
        self.assertIn('no added', str(caught.exception))


class FallbackHarnessTests(unittest.TestCase):
    def captured_source(self):
        """Run check_fallback against a fake compiler and return the source it got."""
        captured = {}

        def fake_compile(compiler, source):
            captured['source'] = source
            return True, ''

        with mock.patch.object(check_procmap_shim, 'compile_source', side_effect=fake_compile):
            with contextlib.redirect_stdout(io.StringIO()):
                passed = check_procmap_shim.check_fallback('g++', '// block\n')
        self.assertTrue(passed)
        return captured['source']

    def test_flag_values_are_pinned(self):
        # The ioctl number is derived from the struct size, so a mutated flag value
        # is invisible to both the number and the size: only these asserts see it.
        source = self.captured_source()
        self.assertIn('static_assert(PROCMAP_QUERY_FILE_BACKED_VMA == 0x20', source)
        for name, value in check_procmap_shim.FLAGS:
            self.assertIn(f'static_assert({name} == {value}', source)
        self.assertEqual(len(check_procmap_shim.FLAGS), 6)
        # Counted by name: the harness also carries the field-offset asserts, so
        # `source.count('static_assert(')` is no longer six.
        self.assertEqual(source.count('static_assert(PROCMAP_QUERY_'), 6)

    def test_field_offsets_are_pinned(self):
        # N2: swapping two members keeps sizeof, the ioctl number and every flag value
        # identical, so only an offset assert can see it -- and a swap is worse than a
        # size mismatch, because the kernel fills the real layout while our copy reads
        # it back, crossing the data instead of failing.
        source = self.captured_source()
        self.assertIn(
            'static_assert(offsetof(struct procmap_query, vma_start) == 24', source)
        for name, offset in check_procmap_shim.FIELDS:
            self.assertIn(f'static_assert(offsetof(struct procmap_query, {name}) == {offset},',
                          source)
        self.assertEqual(len(check_procmap_shim.FIELDS), 15)
        self.assertEqual(source.count('static_assert(offsetof('), 15)
        self.assertIn('#include <cstddef>', source)  # offsetof lives there


class HostUapiTests(unittest.TestCase):
    def check_with(self, output):
        """Run check_host_uapi against a fake compiler result, output captured."""
        with mock.patch.object(check_procmap_shim, 'compile_source',
                               return_value=(False, output)):
            with contextlib.redirect_stdout(io.StringIO()) as stream:
                return check_procmap_shim.check_host_uapi('g++'), stream.getvalue()

    def test_headers_predating_6_11_are_skipped(self):
        passed, output = self.check_with(PREDATES_OUTPUT)
        self.assertTrue(passed)
        self.assertIn('skipped: host headers predate Linux 6.11', output)

    def test_unrelated_compile_error_is_not_swallowed(self):
        passed, output = self.check_with(
            PREDATES_OUTPUT + "/tmp/harness.cpp:9:1: error: expected ';' before '}'\n")
        self.assertFalse(passed)
        self.assertIn('FAIL: the host UAPI differs from the fallback we ship', output)

    def test_fatal_error_is_not_a_skip(self):
        output = '/tmp/harness.cpp:1:10: fatal error: linux/fs.h: No such file or directory\n'
        self.assertFalse(check_procmap_shim.host_uapi_predates_6_11(output))


@unittest.skipUnless(COMPILER, 'needs g++ or clang++')
class EndToEndTests(unittest.TestCase):
    def run_main(self, argument):
        stream = io.StringIO()
        with contextlib.redirect_stdout(stream):
            status = check_procmap_shim.main([str(argument)])
        return status, stream.getvalue()

    def test_real_patch_passes(self):
        status, output = self.run_main(PATCH)
        self.assertEqual(status, 0, output)
        self.assertIn('OK: the PROCMAP_QUERY fallback compiles with -Werror', output)

    def test_wrong_struct_size_fails_the_check(self):
        mutated_patch = PATCH.read_text().replace(SIZE_ASSERT, SIZE_ASSERT.replace('104', '100'))
        self.assertNotEqual(mutated_patch, PATCH.read_text())  # the mutation must bite
        with tempfile.TemporaryDirectory() as directory:
            status, output = self.run_main(write_patch(directory, mutated_patch))
        self.assertEqual(status, 1, output)
        self.assertIn('FAIL: the PROCMAP_QUERY fallback does not compile', output)

    def test_mutated_flag_value_fails_the_check(self):
        # N2: the ioctl number only encodes the struct size, so a mutated flag used to
        # compile and the check used to exit 0. The flag asserts are what catches it.
        mutated_patch = PATCH.read_text().replace('PROCMAP_QUERY_FILE_BACKED_VMA = 0x20,',
                                                 'PROCMAP_QUERY_FILE_BACKED_VMA = 0x40,')
        self.assertNotEqual(mutated_patch, PATCH.read_text())  # the mutation must bite
        with tempfile.TemporaryDirectory() as directory:
            status, output = self.run_main(write_patch(directory, mutated_patch))
        self.assertEqual(status, 1, output)
        self.assertIn('FAIL: the PROCMAP_QUERY fallback does not compile', output)

    def test_swapped_members_fail_the_check(self):
        # N2: swapping the two names keeps the size, the ioctl number and every flag
        # value identical, so the checker used to pass and the kernel then filled the
        # real layout while our copy read it back -- silently crossed data, not EINVAL.
        mutated_patch = swap_member_names(PATCH.read_text(), 'vma_start', 'vma_end')
        # The two member declarations really traded places (each line is a `+` line).
        self.assertIn('__u64 vma_end;\n+\t__u64 vma_start;', mutated_patch)
        with tempfile.TemporaryDirectory() as directory:
            status, output = self.run_main(write_patch(directory, mutated_patch))
        self.assertEqual(status, 1, output)
        self.assertIn('FAIL: the PROCMAP_QUERY fallback does not compile', output)

    def test_missing_patch_fails_with_a_message(self):
        missing = Path(tempfile.gettempdir()) / 'no-such-procmap-patch.patch'
        status, output = self.run_main(missing)
        self.assertEqual(status, 1, output)
        self.assertIn('FAIL:', output)


if __name__ == '__main__':
    unittest.main()
