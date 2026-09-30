#!/usr/bin/env python3
"""Tests scripts/pin_checksums.py with fake checksums.

    python3 scripts/test_pin_checksums.py
"""

import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import packaging  # noqa: E402
import pin_checksums  # noqa: E402

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

    def test_the_committed_file_is_reset_or_pins_the_pubspec_version(self):
        version, sums = pin_checksums.parse(pin_checksums.OUT.read_text())
        if version:
            self.assertEqual(version, pin_checksums.pubspec_version(pin_checksums.PUBSPEC.read_text()))
            self.assertEqual(set(sums), set(packaging.ALL_ARCHIVES))
        else:
            self.assertEqual(sums, {})

    def test_the_committed_file_is_what_the_script_writes(self):
        text = pin_checksums.OUT.read_text()
        self.assertEqual(text, pin_checksums.render(*pin_checksums.parse(text)), "hand-edited?")


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
