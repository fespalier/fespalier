#!/usr/bin/env python3
"""Tests scripts/verify-staged.sh in a throwaway repository with fake archives.

    python3 scripts/test_verify_staged.py
"""

import hashlib
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import packaging  # noqa: E402

TOOLS = all(shutil.which(t) for t in ("bash", "jq", "git"))


def run(cmd, cwd, **kw):
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, **kw)


@unittest.skipUnless(TOOLS, "needs bash, jq and git")
class VerifyStaged(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.repo = Path(self._tmp.name) / "repo"
        shutil.copytree(HERE, self.repo / "scripts", ignore=shutil.ignore_patterns("__pycache__"))
        (self.repo / "packages/fespalier").mkdir(parents=True)
        (self.repo / "packages/fespalier/pubspec.yaml").write_text("name: x\nversion: 1.2.3 # x-release-please-version\n")
        (self.repo / "cli").mkdir()
        (self.repo / "cli/main.rs").write_text("fn main() {}\n")
        self.git("init", "-q")
        self.commit("build")
        self.dist = self.repo / "dist"
        self.dist.mkdir()
        self.pins = self.repo / "pins.dart"
        self.write_archives()
        self.pin()

    def git(self, *args):
        p = run(["git", "-c", "user.name=t", "-c", "user.email=t@example.com", *args], self.repo)
        self.assertEqual(p.returncode, 0, p.stderr)
        return p.stdout.strip()

    def commit(self, message):
        self.git("add", "-A")
        self.git("commit", "-q", "-m", message)

    def write_archives(self, payload=b"built"):
        for target, archive in packaging.ALL_ARCHIVES.items():
            (self.dist / archive).write_bytes(payload + target.encode())

    def write_info(self, version="1.2.3", tree=None):
        tree = tree or self.git("rev-parse", "HEAD:cli")
        (self.dist / "build-info.json").write_text(json.dumps({"version": version, "cli_tree": tree}))

    def pin(self):
        self.write_info()
        p = run([sys.executable, "scripts/pin_checksums.py", "--version", "1.2.3", "--dist", str(self.dist), "--archives",
                 "--out", str(self.pins), "--pubspec", "packages/fespalier/pubspec.yaml"], self.repo)
        self.assertEqual(p.returncode, 0, p.stderr)

    def verify(self, version="1.2.3"):
        return run(["bash", "scripts/verify-staged.sh", version, str(self.dist)], self.repo, env={"PATH": subprocess.os.environ["PATH"], "PINS_FILE": str(self.pins)})

    def test_the_staged_binaries_pass(self):
        p = self.verify()
        self.assertEqual(p.returncode, 0, p.stderr)

    def test_a_change_outside_cli_does_not_matter(self):
        (self.repo / "README.md").write_text("docs\n")
        (self.repo / "packages/fespalier/release_checksums.dart").write_text("pins\n")
        self.commit("docs: readme")
        self.assertEqual(self.verify().returncode, 0)

    def test_a_change_inside_cli_is_refused(self):
        (self.repo / "cli/main.rs").write_text("fn main() { println!(); }\n")
        self.commit("fix: cli")
        p = self.verify()
        self.assertEqual(p.returncode, 1)
        self.assertIn("cli/ changed", p.stderr)

    def test_a_rebuilt_archive_is_refused(self):
        self.write_archives(payload=b"rebuilt")
        p = self.verify()
        self.assertEqual(p.returncode, 1)
        self.assertIn("not the ones release_checksums.dart pins", p.stderr)

    def test_binaries_of_another_version_are_refused(self):
        self.write_info(version="1.2.2")
        p = self.verify()
        self.assertEqual(p.returncode, 1)
        self.assertIn("another version", p.stderr)

    def test_a_missing_build_info_is_refused(self):
        (self.dist / "build-info.json").unlink()
        p = self.verify()
        self.assertEqual(p.returncode, 1)
        self.assertIn("build-info.json is missing", p.stderr)

    def test_no_pins_for_the_version_is_refused(self):
        run([sys.executable, "scripts/pin_checksums.py", "--reset", "--out", str(self.pins)], self.repo)
        p = self.verify()
        self.assertEqual(p.returncode, 1)


if __name__ == "__main__":
    unittest.main()
