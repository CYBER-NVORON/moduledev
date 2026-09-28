"""Wrapper regressions without Docker or network access."""

import importlib.util
from pathlib import Path
import tempfile
import subprocess
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
            self.assertIn("Checker not found", str(ctx.exception))

    def test_downloads_pinned_commit_and_reuses_it_offline(self):
        name, _ = checker.CHECKERS[3]
        real_git = checker.git
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "local upstream"
            real_git("init", source)
            probe = source / "probe.txt"
            probe.write_text("pinned\n", encoding="utf-8")
            real_git("-C", source, "add", "probe.txt")
            real_git("-C", source, "-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                     "-c", "commit.gpgsign=false", "commit", "-m", "Pinned fixture")
            revision = real_git("-C", source, "rev-parse", "HEAD")
            probe.write_text("newer\n", encoding="utf-8")
            real_git("-C", source, "-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                     "-c", "commit.gpgsign=false", "commit", "-am", "Newer fixture")
            destination = Path(directory) / "checkers with spaces"

            def local_download(*args):
                url = f"https://github.com/fintech-dev-lab/{name}.git"
                return real_git(*(source if arg == url else arg for arg in args))

            with patch.dict(checker.CHECKERS, {3: (name, revision)}):
                with patch.object(checker, "git", side_effect=local_download):
                    checkout, actual = checker.prepare_checker(3, destination)
                self.assertEqual(actual, revision)
                self.assertEqual((checkout / "probe.txt").read_text(encoding="utf-8"), "pinned\n")
                self.assertEqual(real_git("-C", checkout, "config", "core.autocrlf"), "false")

                def offline(*args):
                    self.assertNotIn("clone", args)
                    self.assertNotIn("fetch", args)
                    return real_git(*args)

                with patch.object(checker, "git", side_effect=offline):
                    self.assertEqual(checker.prepare_checker(3, destination), (checkout, revision))

    def test_failed_download_does_not_publish_or_remove_existing_files(self):
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory)
            sentinel = destination / "keep.txt"
            sentinel.write_text("keep", encoding="utf-8")

            def interrupted_download(*args):
                partial = Path(args[-1])
                partial.mkdir()
                (partial / "partial.txt").write_text("incomplete", encoding="utf-8")
                raise subprocess.CalledProcessError(128, ["git", "clone"])

            with patch.object(checker, "git", side_effect=interrupted_download):
                with self.assertRaises(subprocess.CalledProcessError):
                    checker.prepare_checker(3, destination)
            self.assertEqual(list(destination.iterdir()), [sentinel])
            self.assertEqual(sentinel.read_text(encoding="utf-8"), "keep")

    def test_refuses_wrong_revision(self):
        name, revision = checker.CHECKERS[3]
        with tempfile.TemporaryDirectory() as directory:
            cache = Path(directory)
            (cache / name).mkdir()
            with patch.object(checker, "git", side_effect=["0" * 40]):
                with self.assertRaises(RuntimeError) as ctx:
                    checker.prepare_checker(3, cache)
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
                            checker.prepare_checker(3, cache)

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
