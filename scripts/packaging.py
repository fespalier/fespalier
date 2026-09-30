#!/usr/bin/env python3
"""Renders the package-manager files for a fespalier release.

    scripts/packaging.py --version 0.2.0 --dist dist --out dist

reads the `fsp-<target>.tar.gz.sha256` / `.zip.sha256` files the release workflow builds
and writes

  fsp.rb    Homebrew formula (macOS x64/arm64, Linux x64/arm64)
  fsp.json  Scoop manifest (Windows x64)

Both point at the GitHub Release assets for `v<version>`. See "Releasing" in the README for
how they reach a Homebrew tap and a Scoop bucket. Standard library only.
"""

import argparse
import json
import re
import sys
from pathlib import Path

REPO = "vaam-apps/fespalier"
DESCRIPTION = "File-tree routing for Flutter: the fsp code generator"
LICENSE = "MIT"

# Homebrew: (block, cpu, target)
BREW_TARGETS = [
    ("macos", "arm", "aarch64-apple-darwin"),
    ("macos", "intel", "x86_64-apple-darwin"),
    ("linux", "arm", "aarch64-unknown-linux-gnu"),
    ("linux", "intel", "x86_64-unknown-linux-gnu"),
]
SCOOP_TARGET = "x86_64-pc-windows-msvc"

ALL_ARCHIVES = {t: f"fsp-{t}.tar.gz" for _, _, t in BREW_TARGETS}
ALL_ARCHIVES[SCOOP_TARGET] = f"fsp-{SCOOP_TARGET}.zip"


def release_url(version: str, asset: str) -> str:
    return f"https://github.com/{REPO}/releases/download/v{version}/{asset}"


def check_version(version: str) -> str:
    if not re.fullmatch(r"\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?", version):
        raise ValueError(f"not a version: {version!r} (expected 1.2.3, without the leading v)")
    return version


def check_sha(target: str, sha: str) -> str:
    if not re.fullmatch(r"[0-9a-f]{64}", sha):
        raise ValueError(f"{target}: not a SHA-256: {sha!r}")
    return sha


def formula(version: str, sha: dict) -> str:
    """The Homebrew formula. `sha` maps a target triple to its archive's SHA-256."""
    version = check_version(version)

    def platform(block: str) -> str:
        cpus = [(cpu, t) for b, cpu, t in BREW_TARGETS if b == block]
        parts = []
        for i, (cpu, target) in enumerate(cpus):
            cond = "Hardware::CPU.arm?" if cpu == "arm" else "Hardware::CPU.intel?"
            kw = "if" if i == 0 else "elsif"
            asset = ALL_ARCHIVES[target]
            parts.append(
                f"    {kw} {cond}\n"
                f'      url "{release_url(version, asset)}"\n'
                f'      sha256 "{check_sha(target, sha[target])}"'
            )
        return f"  on_{block} do\n" + "\n".join(parts) + "\n    end\n  end\n"

    return (
        f"class Fsp < Formula\n"
        f'  desc "{DESCRIPTION}"\n'
        f'  homepage "https://github.com/{REPO}"\n'
        f'  version "{version}"\n'
        f'  license "{LICENSE}"\n'
        f"\n"
        f"{platform('macos')}\n"
        f"{platform('linux')}\n"
        f"  def install\n"
        f'    bin.install "fsp"\n'
        f"  end\n"
        f"\n"
        f"  test do\n"
        f'    assert_match version.to_s, shell_output("#{{bin}}/fsp --version")\n'
        f"  end\n"
        f"end\n"
    )


def scoop_manifest(version: str, sha: dict) -> str:
    """The Scoop manifest for Windows x64, as JSON text."""
    version = check_version(version)
    asset = ALL_ARCHIVES[SCOOP_TARGET]
    url = release_url(version, asset)
    manifest = {
        "version": version,
        "description": DESCRIPTION,
        "homepage": f"https://github.com/{REPO}",
        "license": LICENSE,
        "architecture": {"64bit": {"url": url, "hash": check_sha(SCOOP_TARGET, sha[SCOOP_TARGET])}},
        "bin": "fsp.exe",
        "checkver": {"github": f"https://github.com/{REPO}"},
        "autoupdate": {
            "architecture": {
                "64bit": {
                    "url": release_url("$version", asset),
                    "hash": {"url": "$url.sha256"},
                }
            }
        },
    }
    return json.dumps(manifest, indent=2) + "\n"


def read_checksums(dist: Path) -> dict:
    """target -> sha256, from the `<archive>.sha256` files (`<hash>  <name>`) in `dist`."""
    sums = {}
    for target, archive in ALL_ARCHIVES.items():
        path = dist / f"{archive}.sha256"
        if not path.is_file():
            raise FileNotFoundError(f"missing {path}")
        fields = path.read_text().split()
        if not fields:
            raise ValueError(f"{path} is empty")
        sums[target] = fields[0].lower()
    return sums


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--version", required=True, help="release version without the v, e.g. 0.2.0")
    ap.add_argument("--dist", type=Path, default=Path("dist"), help="folder with the .sha256 files")
    ap.add_argument("--out", type=Path, default=Path("dist"), help="where to write fsp.rb and fsp.json")
    args = ap.parse_args(argv)
    try:
        sums = read_checksums(args.dist)
        rb = formula(args.version, sums)
        js = scoop_manifest(args.version, sums)
    except (OSError, ValueError, KeyError) as e:
        print(f"error: {e}", file=sys.stderr)
        return 1
    args.out.mkdir(parents=True, exist_ok=True)
    (args.out / "fsp.rb").write_text(rb)
    (args.out / "fsp.json").write_text(js)
    print(f"wrote {args.out / 'fsp.rb'} and {args.out / 'fsp.json'} for v{args.version}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
