"""Renders the Homebrew formula and Scoop manifest from fake checksums.

    python3 scripts/test_packaging.py
"""

import json
import re
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import packaging  # noqa: E402

# A distinct fake SHA-256 per archive, so a swapped one shows up.
FAKE = {t: f"{i:x}".rjust(64, "0") for i, t in enumerate(packaging.ALL_ARCHIVES, start=10)}
BASE = "https://github.com/fespalier/fespalier/releases/download/v1.2.3"


class Formula(unittest.TestCase):
    def setUp(self):
        self.rb = packaging.formula("1.2.3", FAKE)

    def test_every_platform_has_its_url_and_sha(self):
        for target, archive in packaging.ALL_ARCHIVES.items():
            if archive.endswith(".zip"):
                continue
            url = f'url "{BASE}/{archive}"\n      sha256 "{FAKE[target]}"'
            self.assertIn(url, self.rb, target)

    def test_shape(self):
        self.assertTrue(self.rb.startswith("class Fsp < Formula\n"))
        self.assertIn('version "1.2.3"', self.rb)
        self.assertIn('bin.install "fsp"', self.rb)
        self.assertNotIn(".zip", self.rb)
        # Balanced blocks: every `do`/`if`/`def`/`class` closes with an `end`.
        opens = len(re.findall(r"\bdo$|^\s*if |^class |^\s*def ", self.rb, re.M))
        self.assertEqual(opens, len(re.findall(r"^\s*end$", self.rb, re.M)))

    def test_macos_and_linux_pick_by_cpu(self):
        macos = self.rb.split("on_macos do")[1].split("on_linux do")[0]
        linux = self.rb.split("on_linux do")[1]
        self.assertIn("aarch64-apple-darwin", macos.split("elsif")[0])
        self.assertIn("x86_64-apple-darwin", macos.split("elsif")[1])
        self.assertIn("aarch64-unknown-linux-gnu", linux.split("elsif")[0])
        self.assertIn("x86_64-unknown-linux-gnu", linux.split("elsif")[1].split("def install")[0])


class Scoop(unittest.TestCase):
    def test_manifest(self):
        m = json.loads(packaging.scoop_manifest("1.2.3", FAKE))
        arch = m["architecture"]["64bit"]
        self.assertEqual(m["version"], "1.2.3")
        self.assertEqual(arch["url"], f"{BASE}/fsp-x86_64-pc-windows-msvc.zip")
        self.assertEqual(arch["hash"], FAKE["x86_64-pc-windows-msvc"])
        self.assertEqual(m["bin"], "fsp.exe")
        auto = m["autoupdate"]["architecture"]["64bit"]
        self.assertEqual(
            auto["url"],
            "https://github.com/fespalier/fespalier/releases/download/v$version/fsp-x86_64-pc-windows-msvc.zip",
        )


class Validation(unittest.TestCase):
    def test_rejects_a_bad_version_or_checksum(self):
        with self.assertRaises(ValueError):
            packaging.formula("v1.2.3", FAKE)
        with self.assertRaises(ValueError):
            packaging.scoop_manifest("1.2", FAKE)
        bad = dict(FAKE, **{"x86_64-apple-darwin": "nothex"})
        with self.assertRaises(ValueError):
            packaging.formula("1.2.3", bad)


class Cli(unittest.TestCase):
    def test_reads_sha256_files_and_writes_both_manifests(self):
        with tempfile.TemporaryDirectory() as d:
            dist = Path(d) / "dist"
            dist.mkdir()
            for target, archive in packaging.ALL_ARCHIVES.items():
                # `sha256sum` output, and PowerShell's (upper-case input is accepted).
                (dist / f"{archive}.sha256").write_text(f"{FAKE[target].upper()}  {archive}\n")
            out = Path(d) / "out"
            self.assertEqual(packaging.main(["--version", "1.2.3", "--dist", str(dist), "--out", str(out)]), 0)
            self.assertEqual((out / "fsp.rb").read_text(), packaging.formula("1.2.3", FAKE))
            self.assertEqual((out / "fsp.json").read_text(), packaging.scoop_manifest("1.2.3", FAKE))

    def test_a_missing_checksum_file_fails(self):
        with tempfile.TemporaryDirectory() as d:
            self.assertEqual(packaging.main(["--version", "1.2.3", "--dist", d, "--out", d]), 1)


if __name__ == "__main__":
    unittest.main()
