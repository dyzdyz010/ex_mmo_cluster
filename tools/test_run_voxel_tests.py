"""只测试：运行器必须拒绝漏选和空结果，并保留 Mix 的失败状态。"""
import tempfile
import unittest
from pathlib import Path
from run_voxel_tests import validate_selection, passed_count


class SelectionTests(unittest.TestCase):
    def test_missing_file_does_not_hide_behind_existing_file(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'one_test.exs').touch()
            with self.assertRaisesRegex(ValueError, 'missing_test.exs'):
                validate_selection(['one_test.exs', 'missing_test.exs'], root)
            validate_selection(['one_test.exs:12', '--seed', '8'], root)

    def test_options_alone_do_not_select_the_whole_app(self):
        with self.assertRaises(ValueError):
            validate_selection(['--seed', '8'], Path('.'))
        validate_selection(['--only', 'b3'], Path('.'))
        validate_selection(['--only=b3'], Path('.'))

    def test_excluded_and_skipped_tests_are_not_passes(self):
        self.assertEqual(passed_count('Result: 0 tests, 5 excluded'), 0)
        self.assertEqual(passed_count('Result: 0 tests, 5 skipped'), 0)
        self.assertEqual(passed_count('5 tests, 0 failures, 5 excluded'), 0)
        self.assertEqual(passed_count('5 tests, 0 failures, 5 skipped'), 0)

    def test_current_and_ci_elixir_summaries(self):
        self.assertEqual(passed_count('Result: 5 passed, 1 excluded'), 5)
        self.assertEqual(passed_count('Result: 3/5 passed\nFailed: 2 tests'), 3)
        self.assertEqual(passed_count('7 tests, 0 failures, 2 excluded'), 5)
        self.assertEqual(passed_count('2 doctests, 7 tests, 0 failures, 2 excluded'), 7)
        self.assertEqual(passed_count('2 doctests, 0 failures'), 2)

    def test_missing_completion_is_not_success(self):
        self.assertIsNone(passed_count('Compiling 3 files\nRunning ExUnit'))


if __name__ == '__main__':
    unittest.main()
