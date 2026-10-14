#!/usr/bin/env python3
"""Tests the manual run of .github/workflows/release.yml (`workflow_dispatch` with `tag` and `pins`).

    python3 scripts/test_release_dispatch.py

The recovery for a release PR that was merged before release-pins had pinned it (v0.17.1) is
workflow YAML, which nothing else exercises until the day it is needed. This takes the `run:` block
of each step that matters out of the workflow file, as written there, and runs it with bash in a
throwaway repository: a tag whose release_checksums.dart pins the previous version, and pin commits
that exist only as objects on the remote (release-please force-pushes the release branch, so the
pin commit is on no branch). `https://github.com/...` is redirected to that remote with git's
`url.<base>.insteadOf`. It proves the validation logic, not GitHub's behaviour. Needs bash and git;
skipped without them. Standard library only.
"""

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
sys.path.insert(0, str(HERE))
import packaging  # noqa: E402
import pin_checksums  # noqa: E402

WORKFLOW = ROOT / ".github/workflows/release.yml"
TOOLS = all(shutil.which(t) for t in ("bash", "git"))
REPO = "o/r"
TOKEN = "t0ken"
GITHUB_URL = f"https://x-access-token:{TOKEN}@github.com/{REPO}.git"
PINS_FILE = "packages/fespalier/lib/src/release_checksums.dart"

STEP_TAG = "Name the tag to release"
STEP_PINS = "The pin commit belongs to this tag"
STEP_READ = "Read the pins from the pin commit"
STEP_VERIFY_TAG = "Verify the staged archives against the pins in this tag"
STEP_VERIFY_PINS = "Verify the staged archives against the pins in the pin commit (manual run)"


def step_block(name: str) -> list:
    """The lines of the workflow step called `name` (from `- name:` to the next step or comment)."""
    lines = WORKFLOW.read_text().splitlines()
    for start, line in enumerate(lines):
        if re.fullmatch(r"\s*- name: " + re.escape(name), line):
            break
    else:
        raise AssertionError(f"{WORKFLOW.name} has no step named {name!r}")
    indent = len(lines[start]) - len(lines[start].lstrip())
    end = start + 1
    while end < len(lines) and not (lines[end].strip() and len(lines[end]) - len(lines[end].lstrip()) <= indent):
        end += 1
    return lines[start:end]


def step_script(name: str) -> str:
    """The `run: |` script of a step, dedented as the runner sees it."""
    block = step_block(name)
    for i, line in enumerate(block):
        m = re.fullmatch(r"(\s*)run: \|", line)
        if m:
            body = len(m[1]) + 2
            out = []
            for line in block[i + 1 :]:
                if line.strip() and len(line) - len(line.lstrip()) < body:
                    break
                out.append(line[body:] if line.strip() else "")
            return "\n".join(out) + "\n"
    raise AssertionError(f"step {name!r} has no `run: |` script")


def step_env(name: str) -> set:
    """The names a step declares under its own `env:`."""
    block = step_block(name)
    for i, line in enumerate(block):
        m = re.fullmatch(r"(\s*)env:", line)
        if m:
            keys = set()
            for line in block[i + 1 :]:
                k = re.fullmatch(r"\s{%d}([A-Z_]+): .*" % (len(m[1]) + 2), line)
                if not k:
                    break
                keys.add(k[1])
            return keys
    return set()


def git(cwd, *args, check=True, env=None):
    cmd = ["git", "-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false", *args]
    p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, env=env)
    if check and p.returncode != 0:
        raise AssertionError(f"{' '.join(args)} failed: {p.stderr}")
    return p.stdout.strip()


@unittest.skipUnless(TOOLS, "needs bash and git")
class ManualRelease(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls._tmp = tempfile.TemporaryDirectory()
        cls.tmp = Path(cls._tmp.name)
        cls.dist = cls.tmp / "dist"
        cls.dist.mkdir()
        for target, archive in packaging.ALL_ARCHIVES.items():
            (cls.dist / archive).write_bytes(b"built " + target.encode())
        cls.sums = pin_checksums.archive_sums(cls.dist)

        # What release-please and release-pins leave behind for 1.2.3: the tag has the PREVIOUS
        # release's pins, and the pin commit (made later, on the release branch) the right ones.
        src = cls.tmp / "src"
        src.mkdir()
        git(src, "init", "-q", "-b", "main")
        (src / "cli").mkdir()
        (src / "cli/main.rs").write_text("fn main() {}\n")
        (src / PINS_FILE).parent.mkdir(parents=True)
        (src / PINS_FILE).write_text(pin_checksums.render("1.2.2", cls.sums))
        git(src, "add", "-A")
        git(src, "commit", "-q", "-m", "chore: pin fsp 1.2.2 checksums")
        cls.prev_pin = git(src, "rev-parse", "HEAD")
        (src / "README.md").write_text("1.2.3\n")
        git(src, "add", "-A")
        git(src, "commit", "-q", "-m", "chore: release main")
        cls.tag_commit = git(src, "rev-parse", "HEAD")
        git(src, "tag", "v1.2.3")
        cls.cli_tree = git(src, "rev-parse", "HEAD:cli")

        def commit(subject, pins_for=None, cli=None, readme=None):
            git(src, "reset", "-q", "--hard", cls.tag_commit)
            if pins_for:
                (src / PINS_FILE).write_text(pin_checksums.render(pins_for, cls.sums))
            if cli:
                (src / "cli/main.rs").write_text(cli)
            if readme:
                (src / "README.md").write_text(readme)
            git(src, "add", "-A")
            git(src, "commit", "-q", "-m", subject)
            return git(src, "rev-parse", "HEAD")

        cls.pin = commit("chore: pin fsp 1.2.3 checksums", pins_for="1.2.3")
        cls.pin_with_other_cli = commit("chore: pin fsp 1.2.3 checksums", pins_for="1.2.3", cli="fn main() { println!(); }\n")
        cls.pin_without_pins = commit("chore: pin fsp 1.2.3 checksums", readme="no pins in here\n")
        git(src, "reset", "-q", "--hard", cls.tag_commit)

        # The remote has the tag and the main branch; the pin commits are on NO ref (the release
        # branch was force-pushed), so only a fetch of the SHA itself can find them.
        cls.remote = cls.tmp / "remote.git"
        git(cls.tmp, "init", "-q", "--bare", str(cls.remote))
        git(cls.remote, "config", "uploadpack.allowAnySHA1InWant", "true")
        git(src, "push", "-q", str(cls.remote), f"{cls.tag_commit}:refs/heads/main", "refs/tags/v1.2.3")
        for sha in (cls.pin, cls.pin_with_other_cli, cls.pin_without_pins):
            git(src, "push", "-q", str(cls.remote), f"{sha}:refs/heads/tmp")
            git(src, "push", "-q", str(cls.remote), ":refs/heads/tmp")

        # the staged binaries' record, and the pins file the pin commit carries
        cls.build_info = json.dumps({"version": "1.2.3", "cli_tree": cls.cli_tree})
        cls.pins_text = pin_checksums.render("1.2.3", cls.sums)

    @classmethod
    def tearDownClass(cls):
        cls._tmp.cleanup()

    def setUp(self):
        self.work = Path(tempfile.mkdtemp(dir=self.tmp))
        self.out = self.work.parent / (self.work.name + ".out")
        self.out.write_text("")
        self.runner_temp = Path(tempfile.mkdtemp(dir=self.tmp))

    def env(self, **extra):
        return {
            "PATH": os.environ["PATH"],
            "HOME": str(self.tmp),
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_COUNT": "1",
            "GIT_CONFIG_KEY_0": f"url.file://{self.remote}.insteadOf",
            "GIT_CONFIG_VALUE_0": GITHUB_URL,
            "GIT_TERMINAL_PROMPT": "0",
            "GH_TOKEN": TOKEN,
            "GITHUB_REPOSITORY": REPO,
            "GITHUB_OUTPUT": str(self.out),
            "RUNNER_TEMP": str(self.runner_temp),
            **extra,
        }

    def run_step(self, name, cwd=None, **env):
        # the names the step declares for itself must be exactly what the test supplies for it
        declared = step_env(name)
        missing = declared - set(env)
        self.assertFalse(missing, f"{name!r} declares {sorted(missing)}, which this test does not supply")
        return subprocess.run(
            ["bash", "--noprofile", "--norc", "-eo", "pipefail", "-c", step_script(name)],
            cwd=cwd or self.work, env=self.env(**env), capture_output=True, text=True, timeout=60,
        )

    def outputs(self):
        return dict(line.split("=", 1) for line in self.out.read_text().splitlines() if "=" in line)

    def checkout_tag(self):
        """What actions/checkout does for `ref: refs/tags/v1.2.3`: a shallow fetch of the tag."""
        git(self.work, "init", "-q")
        git(self.work, "fetch", "-q", "--depth=1", f"file://{self.remote}", "+refs/tags/v1.2.3:refs/tags/v1.2.3")
        git(self.work, "checkout", "-q", "--detach", "refs/tags/v1.2.3")

    # -- the workflow file itself ---------------------------------------------------------------

    def test_the_inputs_are_declared_and_required(self):
        text = WORKFLOW.read_text()
        m = re.search(r"workflow_dispatch:\n    inputs:\n((?:      .*\n|\n)+)", text)
        self.assertIsNotNone(m, "workflow_dispatch has no inputs")
        for name in ("tag", "pins"):
            self.assertRegex(m[1], rf"(?m)^      {name}:\n(?:        .*\n)*?        required: true\n")
        self.assertIn("INPUT_TAG: ${{ inputs.tag }}", text)
        self.assertIn("INPUT_PINS: ${{ inputs.pins }}", text)

    def test_a_tag_push_still_verifies_against_the_tags_own_pins(self):
        block = "\n".join(step_block(STEP_VERIFY_TAG))
        self.assertIn("if: github.event_name == 'push'", block)
        self.assertNotIn("PINS_FILE", block)
        manual = "\n".join(step_block(STEP_VERIFY_PINS))
        self.assertIn("if: github.event_name == 'workflow_dispatch'", manual)
        self.assertIn("PINS_FILE: ${{ runner.temp }}/release_checksums.dart", manual)

    # -- "Name the tag to release" ---------------------------------------------------------------

    def name_the_tag(self, tag="v1.2.3", pins=None, event="workflow_dispatch", ref="refs/heads/main"):
        return self.run_step(
            STEP_TAG, cwd=self.tmp, INPUT_TAG=tag, INPUT_PINS=pins or self.pin, EVENT=event, REF=ref, DEFAULT_BRANCH="main"
        )

    def test_a_tag_push_names_the_pushed_tag(self):
        p = self.name_the_tag(tag="", pins="", event="push", ref="refs/tags/v1.2.3")
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertEqual(self.outputs(), {"tag": "v1.2.3"})

    def test_a_manual_run_for_an_existing_tag_is_accepted(self):
        p = self.name_the_tag()
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertEqual(self.outputs(), {"tag": "v1.2.3"})
        self.assertIn(self.pin, p.stdout)

    def test_a_manual_run_from_another_branch_is_refused(self):
        p = self.name_the_tag(ref="refs/heads/claude/other")
        self.assertEqual(p.returncode, 1)
        self.assertIn("::error::start this workflow from main", p.stdout)

    def test_a_tag_that_is_not_a_release_tag_is_refused(self):
        for tag in ("1.2.3", "v1.2", "v1.2.3-rc.1", "V1.2.3", " v1.2.3", "v1.2.3 ", "main", "v1.2.3\n::error::injected", ""):
            with self.subTest(tag=tag):
                p = self.name_the_tag(tag=tag)
                self.assertEqual(p.returncode, 1, p.stdout)
                self.assertIn("::error::the 'tag' input must be a release tag", p.stdout)
                self.assertNotIn("injected", p.stdout)

    def test_pins_that_are_not_a_full_lowercase_sha_are_refused(self):
        for pins in (self.pin[:7], self.pin.upper(), self.pin + "0", "main", "release-please--branches--main", "", self.pin[:-1] + "g"):
            with self.subTest(pins=pins):
                p = self.name_the_tag(pins=pins or "x")
                self.assertEqual(p.returncode, 1, p.stdout)
                self.assertIn("::error::the 'pins' input must be the full 40-character lowercase SHA", p.stdout)

    def test_a_tag_that_does_not_exist_is_refused(self):
        p = self.name_the_tag(tag="v9.9.9")
        self.assertEqual(p.returncode, 1)
        self.assertIn("::error::v9.9.9 is not a tag of o/r", p.stdout)
        self.assertEqual(self.outputs(), {})

    # -- "The pin commit belongs to this tag" ----------------------------------------------------

    def pin_step(self, pins):
        return self.run_step(STEP_PINS, TAG="v1.2.3", INPUT_PINS=pins)

    def test_the_pin_commit_of_the_tag_is_accepted_though_it_is_on_no_branch(self):
        self.checkout_tag()
        self.assertNotEqual(git(self.work, "cat-file", "-t", self.pin, check=False), "commit")
        p = self.pin_step(self.pin)
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertEqual(self.outputs(), {"pins": self.pin})
        self.assertIn("'1.2.2'", p.stdout, "the log says what the tag's own pins are")
        self.assertIn(self.cli_tree, p.stdout)

    def test_the_tag_is_fetched_when_the_checkout_left_no_tag_ref(self):
        self.checkout_tag()
        git(self.work, "tag", "-d", "v1.2.3")
        p = self.pin_step(self.pin)
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertEqual(self.outputs(), {"pins": self.pin})

    def test_a_pin_commit_that_is_already_here_is_accepted(self):
        self.checkout_tag()
        git(self.work, "fetch", "-q", "--depth=1", f"file://{self.remote}", self.pin)
        p = self.pin_step(self.pin)
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)

    def test_the_previous_releases_pin_commit_is_refused(self):
        # a pin commit with the same cli/ tree, but for the version before
        self.checkout_tag()
        p = self.pin_step(self.prev_pin)
        self.assertEqual(p.returncode, 1)
        self.assertIn("is 'chore: pin fsp 1.2.2 checksums', not 'chore: pin fsp 1.2.3 checksums'", p.stdout)
        self.assertEqual(self.outputs(), {})

    def test_a_commit_that_is_not_a_pin_commit_is_refused(self):
        self.checkout_tag()
        p = self.pin_step(self.tag_commit)
        self.assertEqual(p.returncode, 1)
        self.assertIn("is 'chore: release main', not 'chore: pin fsp 1.2.3 checksums'", p.stdout)

    def test_pins_made_for_other_source_than_the_tag_are_refused(self):
        self.checkout_tag()
        p = self.pin_step(self.pin_with_other_cli)
        self.assertEqual(p.returncode, 1)
        self.assertIn("is not cli/ of v1.2.3", p.stdout)
        self.assertIn("other source than this tag", p.stdout)

    def test_a_pin_commit_that_does_not_pin_the_version_is_refused(self):
        self.checkout_tag()
        p = self.pin_step(self.pin_without_pins)
        self.assertEqual(p.returncode, 1)
        self.assertIn("does not pin 1.2.3", p.stdout)

    def test_a_sha_that_does_not_exist_is_refused(self):
        self.checkout_tag()
        p = self.pin_step("0" * 39 + "1")
        self.assertEqual(p.returncode, 1)
        self.assertIn("::error::cannot fetch " + "0" * 39 + "1 from o/r", p.stdout)

    def test_a_checkout_that_is_not_the_tag_is_refused(self):
        self.checkout_tag()
        git(self.work, "commit", "-q", "--allow-empty", "-m", "elsewhere")
        p = self.pin_step(self.pin)
        self.assertEqual(p.returncode, 1)
        self.assertIn("::error::the checkout is not v1.2.3", p.stdout)

    # -- the pins reach verify-staged.sh ---------------------------------------------------------

    @unittest.skipUnless(shutil.which("jq"), "verify-staged.sh needs jq")
    def test_the_staged_archives_pass_only_against_the_pin_commit(self):
        """The incident: the tag pins 1.2.2, the staged archives are 1.2.3's and the pin commit's."""
        self.checkout_tag()
        shutil.copytree(HERE, self.work / "scripts", ignore=shutil.ignore_patterns("__pycache__"))
        staged = self.work / "staged"
        shutil.copytree(self.dist, staged)
        (staged / "build-info.json").write_text(self.build_info)
        verify = ["bash", "scripts/verify-staged.sh", "1.2.3", "staged"]
        base = {"PATH": os.environ["PATH"], "HOME": str(self.tmp)}

        # a tag push (or a plain re-run) reads the tag's own pins, which are the previous release's
        p = subprocess.run(verify, cwd=self.work, env=base, capture_output=True, text=True)
        self.assertEqual(p.returncode, 1, p.stdout)
        self.assertIn("the committed pins are for 1.2.2, not 1.2.3", p.stderr)

        # the manual run reads the pin commit's file, as the "Read the pins" step writes it
        p = self.run_step(STEP_READ, PINS=self.pin, GH_TOKEN=TOKEN)
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        pins_file = self.runner_temp / "release_checksums.dart"
        self.assertEqual(pins_file.read_text(), self.pins_text)
        p = subprocess.run(verify, cwd=self.work, env={**base, "PINS_FILE": str(pins_file)}, capture_output=True, text=True)
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)

        # and still only the archives that file pins, from this tag's cli/
        (staged / "fsp-x86_64-unknown-linux-gnu.tar.gz").write_bytes(b"rebuilt")
        p = subprocess.run(verify, cwd=self.work, env={**base, "PINS_FILE": str(pins_file)}, capture_output=True, text=True)
        self.assertEqual(p.returncode, 1)
        self.assertIn("not the ones release_checksums.dart pins", p.stderr)


if __name__ == "__main__":
    unittest.main()
