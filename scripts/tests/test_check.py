"""Wrapper regressions without Docker or network access."""

import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location("checker_wrapper", Path(__file__).resolve().parents[1] / "check.py")
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)


class CheckerWrapperTests(unittest.TestCase):
    def test_refuses_missing_checkout(self):
        """verify_checker must fail clearly if the repo has not been cloned yet."""
        with tempfile.TemporaryDirectory() as directory:
            cache = Path(directory)
            with self.assertRaises(RuntimeError) as ctx:
                checker.verify_checker(3, cache)
            self.assertIn("Clone it first", str(ctx.exception))

    def test_refuses_wrong_revision(self):
        name, revision = checker.CHECKERS[3]
        with tempfile.TemporaryDirectory() as directory:
            cache = Path(directory)
            (cache / name).mkdir()
            with patch.object(checker, "git", side_effect=["0" * 40]):
                with self.assertRaises(RuntimeError) as ctx:
                    checker.verify_checker(3, cache)
            self.assertIn("Wrong revision", str(ctx.exception))

    def test_refuses_local_changes(self):
        name, revision = checker.CHECKERS[3]
        with tempfile.TemporaryDirectory() as directory:
            cache = Path(directory)
            (cache / name).mkdir()
            for dirty in [" M autocheck/public_check.py", "?? autocheck/untracked.py"]:
                with self.subTest(dirty=dirty):
                    with patch.object(checker, "git", side_effect=[revision, dirty]):
                        with self.assertRaises(RuntimeError):
                            checker.verify_checker(3, cache)

    def test_accepts_clean_pinned_checkout(self):
        name, revision = checker.CHECKERS[3]
        with tempfile.TemporaryDirectory() as directory:
            cache = Path(directory)
            (cache / name).mkdir()
            with patch.object(checker, "git", side_effect=[revision, ""]):
                checkout, actual = checker.verify_checker(3, cache)
                self.assertEqual(actual, revision)
                self.assertEqual(checkout, cache / name)

    def test_passes_solution_and_fixtures_as_separate_arguments(self):
        repo = Path("solution with spaces")
        checkout = Path("checker with spaces")
        for week in checker.CHECKERS:
            with self.subTest(week=week):
                command = checker.checker_command(week, checkout, repo, True)
                self.assertEqual(command[command.index("--repo") + 1], str(repo))
                self.assertEqual(command[command.index("--fixtures") + 1], str(checkout / "autocheck/fixtures"))
                self.assertEqual(command[command.index("--output") + 1], str(repo / f"week-{week}-public-report.json"))
                self.assertEqual("--compose-wrapper" in command, week >= 2)
                self.assertIn("--keep-stack", command)


if __name__ == "__main__":
    unittest.main()
