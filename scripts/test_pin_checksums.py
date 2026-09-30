#!/usr/bin/env python3
"""Tests scripts/pin_checksums.py with fake checksums.

    python3 scripts/test_pin_checksums.py
"""

import hashlib
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import packaging  # noqa: E402
import pin_checksums  # noqa: E402

def triple(version: str):
    return tuple(int(p) for p in version.split("-")[0].split("."))


FAKE = {t: f"{i:x}".rjust(64, "0") for i, t in enumerate(packaging.ALL_ARCHIVES, start=10)}


def write_dist(dist: Path, sums=FAKE):
    dist.mkdir(parents=True, exist_ok=True)
    for target, archive in packaging.ALL_ARCHIVES.items():
        if target in sums:
            (dist / f"{archive}.sha256").write_text(f"{sums[target].upper()}  {archive}\n")


class Render(unittest.TestCase):
    def test_pinned_file_round_trips(self):
        text = pin_checksums.render("1.2.3", FAKE)
        self.assertEqual(pin_checksums.parse(text), ("1.2.3", FAKE))
        self.assertIn("const pinnedVersion = '1.2.3';", text)

    def test_every_target_is_pinned_to_its_own_archive(self):
        parsed = pin_checksums.parse(pin_checksums.render("1.2.3", FAKE))[1]
        self.assertEqual(len(parsed), 5)
        self.assertEqual(len(set(parsed.values())), 5)

    def test_reset_has_no_pins(self):
        self.assertEqual(pin_checksums.parse(pin_checksums.render("", {})), ("", {}))
        self.assertIn("<String, String>{};", pin_checksums.render("", {}))

    def test_rejects_bad_input(self):
        with self.assertRaises(ValueError):
            pin_checksums.render("v1.2.3", FAKE)
        with self.assertRaises(ValueError):
            pin_checksums.render("1.2.3", {**FAKE, "x86_64-apple-darwin": "nothex"})
        with self.assertRaises(ValueError):
            pin_checksums.render("1.2.3", {t: s for t, s in FAKE.items() if "windows" not in t})
        with self.assertRaises(ValueError):
            pin_checksums.render("", FAKE)

    def test_the_committed_file_is_reset_or_pins_a_version_up_to_the_pubspecs(self):
        # Between releases the pins are the current version's; on an open release PR (the
        # pubspec already bumped by release-please, before the pin commit lands) they are the
        # previous release's. Never a version ahead of the package.
        version, sums = pin_checksums.parse(pin_checksums.OUT.read_text())
        if version:
            current = pin_checksums.pubspec_version(pin_checksums.PUBSPEC.read_text())
            self.assertLessEqual(triple(version), triple(current))
            self.assertEqual(set(sums), set(packaging.ALL_ARCHIVES))
        else:
            self.assertEqual(sums, {})

    def test_the_committed_file_is_what_the_script_writes(self):
        text = pin_checksums.OUT.read_text()
        self.assertEqual(text, pin_checksums.render(*pin_checksums.parse(text)), "hand-edited?")


class PubspecVersion(unittest.TestCase):
    def test_plain_quoted_and_annotated(self):
        read = pin_checksums.pubspec_version
        self.assertEqual(read("name: x\nversion: 1.2.3\n"), "1.2.3")
        self.assertEqual(read("name: x\nversion: '1.2.3'\n"), "1.2.3")
        self.assertEqual(read('version: "1.2.3-dev.1"'), "1.2.3-dev.1")
        # release-please's annotation, which is what the pubspec carries now
        self.assertEqual(read("name: x\nversion: 1.2.3 # x-release-please-version\n"), "1.2.3")
        self.assertEqual(read("version: 1.2.3 #x\n"), "1.2.3")

    def test_an_indented_version_is_not_the_packages(self):
        with self.assertRaises(ValueError):
            pin_checksums.pubspec_version("name: x\n  version: 9.9.9\n")


def write_archives(dist: Path, payload=b"x"):
    """Fake archives, returning target -> their real SHA-256."""
    dist.mkdir(parents=True, exist_ok=True)
    sums = {}
    for target, archive in packaging.ALL_ARCHIVES.items():
        data = payload + target.encode()
        (dist / archive).write_bytes(data)
        sums[target] = hashlib.sha256(data).hexdigest()
    return sums


class Archives(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.addCleanup(self._tmp.cleanup)
        self.pubspec = self.tmp / "pubspec.yaml"
        self.pubspec.write_text("name: x\nversion: 1.2.3 # x-release-please-version\n")
        self.out = self.tmp / "release_checksums.dart"
        self.dist = self.tmp / "dist"

    def run_main(self, *extra):
        return pin_checksums.main(["--pubspec", str(self.pubspec), "--out", str(self.out), "--dist", str(self.dist), *extra])

    def test_archives_are_hashed_not_trusted_to_their_sha256_files(self):
        sums = write_archives(self.dist)
        # a .sha256 file that lies: --archives must ignore it
        write_dist(self.dist, FAKE)
        self.assertEqual(self.run_main("--version", "1.2.3", "--archives"), 0)
        self.assertEqual(pin_checksums.parse(self.out.read_text()), ("1.2.3", sums))

    def test_check_passes_for_the_pinned_archives(self):
        write_archives(self.dist)
        self.run_main("--version", "1.2.3", "--archives")
        self.assertEqual(self.run_main("--check", "--version", "1.2.3"), 0)

    def test_check_fails_for_a_rebuilt_archive(self):
        write_archives(self.dist)
        self.run_main("--version", "1.2.3", "--archives")
        before = self.out.read_text()
        write_archives(self.dist, payload=b"rebuilt")  # same names, different bytes
        self.assertEqual(self.run_main("--check", "--version", "1.2.3"), 1)
        self.assertEqual(self.out.read_text(), before, "--check must not write")

    def test_check_fails_for_another_version_or_a_missing_archive(self):
        write_archives(self.dist)
        self.run_main("--version", "1.2.3", "--archives")
        self.assertEqual(self.run_main("--check", "--version", "1.2.4"), 1)
        (self.dist / packaging.ALL_ARCHIVES["x86_64-pc-windows-msvc"]).unlink()
        self.assertEqual(self.run_main("--check", "--version", "1.2.3"), 1)

    def test_check_fails_when_nothing_is_pinned(self):
        write_archives(self.dist)
        self.run_main("--reset")
        self.assertEqual(self.run_main("--check", "--version", "1.2.3"), 1)

    def test_pins_are_idempotent(self):
        write_archives(self.dist)
        self.run_main("--version", "1.2.3", "--archives")
        first = self.out.read_text()
        self.run_main("--version", "1.2.3", "--archives")
        self.assertEqual(self.out.read_text(), first)


class Main(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.addCleanup(self._tmp.cleanup)
        self.pubspec = self.tmp / "pubspec.yaml"
        self.pubspec.write_text("name: x\nversion: 1.2.3\n")
        self.out = self.tmp / "lib" / "release_checksums.dart"
        self.dist = self.tmp / "dist"

    def run_main(self, *extra):
        return pin_checksums.main(["--pubspec", str(self.pubspec), "--out", str(self.out), *extra])

    def test_writes_the_pins(self):
        write_dist(self.dist)
        self.assertEqual(self.run_main("--version", "1.2.3", "--dist", str(self.dist)), 0)
        self.assertEqual(pin_checksums.parse(self.out.read_text()), ("1.2.3", FAKE))

    def test_refuses_another_versions_binaries(self):
        write_dist(self.dist)
        self.assertEqual(self.run_main("--version", "1.2.4", "--dist", str(self.dist)), 1)
        self.assertFalse(self.out.exists())

    def test_a_missing_archive_checksum_fails_and_writes_nothing(self):
        write_dist(self.dist, {t: s for t, s in FAKE.items() if "windows" not in t})
        self.assertEqual(self.run_main("--version", "1.2.3", "--dist", str(self.dist)), 1)
        self.assertFalse(self.out.exists())

    def test_reset_overwrites_pins(self):
        write_dist(self.dist)
        self.run_main("--version", "1.2.3", "--dist", str(self.dist))
        self.assertEqual(self.run_main("--reset"), 0)
        self.assertEqual(pin_checksums.parse(self.out.read_text()), ("", {}))


if __name__ == "__main__":
    unittest.main()
