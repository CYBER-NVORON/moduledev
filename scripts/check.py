"""Download, verify and run the pinned public checker for a given week."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]
CHECKERS = {
    1: ("moduledev-week-1-gateway-task", "51fbca54412ceb42964048fb0b19354d51488a22"),
    2: ("moduledev-week-2-workflow-task", "0db15e2ee8e6722369425439cc44946d9a049bd5"),
    3: ("moduledev-week-3-python-perimeter-task", "563e2fcf5ada68e71e88675fc7740ab81083126d"),
    4: ("moduledev-week-4-reliability-task", "e1ae7e03c6a4f2da5dc2ee9f02ebe3f26b2d16a3"),
}


def git(*args):
    result = subprocess.run(["git", "--no-optional-locks", *map(str, args)],
                            check=False, capture_output=True, text=True)
    if result.returncode != 0:
        if result.stderr:
            print(result.stderr.rstrip(), file=sys.stderr)
        raise subprocess.CalledProcessError(result.returncode, result.args)
    return result.stdout.strip()


def prepare_checker(week, directory):
    """Install a missing checkout without modifying an existing one."""
    name, revision = CHECKERS[week]
    checkout = directory / name
    if not checkout.exists():
        directory.mkdir(parents=True, exist_ok=True)
        # Publish only a fully downloaded and verified repository. A failed
        # download leaves the final path available for a subsequent retry.
        with tempfile.TemporaryDirectory(prefix=f".{name}-", dir=directory) as temporary:
            staging = Path(temporary)
            git("clone", "--config", "core.autocrlf=false", "--no-checkout",
                f"https://github.com/fintech-dev-lab/{name}.git", staging / name)
            git("-C", staging / name, "checkout", "--detach", revision)
            verify_checker(week, staging)
            (staging / name).rename(checkout)
    return verify_checker(week, directory)


def verify_checker(week, directory):
    """Verify the checker repo exists at the pinned commit. Does not clone."""
    name, revision = CHECKERS[week]
    checkout = directory / name
    if not checkout.exists():
        raise RuntimeError(f"Checker not found: {checkout}")
    actual = git("-C", checkout, "rev-parse", "HEAD")
    if actual != revision:
        raise RuntimeError(
            f"Wrong revision in {checkout}:\n"
            f"  got:      {actual}\n"
            f"  expected: {revision}\n"
            f"Run: git -C {checkout} checkout {revision}"
        )
    if git("-C", checkout, "status", "--porcelain", "--untracked-files=all"):
        raise RuntimeError(f"Checker has local changes: {checkout}. Use a clean checkout.")
    return checkout, revision


def checker_command(week, checkout, repo, keep_stack):
    # Week 1/2 shell entrypoints use their own repository as --repo (week 2
    # even reserves that option). Call the official Python CLI with explicit paths.
    command = [sys.executable, str(checkout / "autocheck/public_check.py"),
               "--repo", str(repo), "--fixtures", str(checkout / "autocheck/fixtures"),
               "--output", str(repo / f"week-{week}-public-report.json")]
    if week >= 2:
        command += ["--compose-wrapper", str(checkout / "autocheck/safe_compose.sh")]
    if keep_stack:
        command.append("--keep-stack")
    return command


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--week", type=int, choices=CHECKERS, default=4)
    parser.add_argument("--repo", type=Path, default=ROOT)
    parser.add_argument("--checkers-dir", "--cache-dir", dest="checkers_dir", type=Path,
                        default=ROOT / "scripts/repo",
                        help="Directory for verified checker downloads (default: scripts/repo).")
    parser.add_argument("--keep-stack", action="store_true")
    args = parser.parse_args()
    if os.name == "nt":
        parser.error("Use check.ps1 with WSL; upstream checkers require POSIX/Bash.")
    if args.week == 4 and sys.version_info < (3, 11):
        parser.error("Week 4 checker requires Python 3.11+.")
    programs = ("git", "bash", "docker", "psql") if args.week == 4 else ("git", "bash", "docker")
    for program in programs:
        if shutil.which(program) is None:
            parser.error(f"Required program is not on PATH: {program}")
    repo = args.repo.expanduser().resolve()
    directory = args.checkers_dir.expanduser().resolve()
    if not repo.is_dir():
        parser.error("--repo must be an existing solution directory")
    try:
        checkout, revision = prepare_checker(args.week, directory)
        print(f"Week {args.week} checker revision: {revision}", flush=True)
        return subprocess.run(checker_command(args.week, checkout, repo, args.keep_stack),
                              cwd=repo).returncode
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"Checker setup failed: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
