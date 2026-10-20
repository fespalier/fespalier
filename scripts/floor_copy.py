#!/usr/bin/env python3
"""Copies the pub workspace's packages out of it, each one resolvable on its own (the floor job).

    python3 scripts/floor_copy.py <dest>

Inside the workspace (the root pubspec.yaml) every package shares one resolution, so a
`flutter pub downgrade` in a package downgrades all of them together and tests the highest of
their lower bounds, not that package's own. This copies every package of the root's
`workspace:` list to `<dest>/packages/<name>` (without `.dart_tool`, `build`, `pubspec.lock` or
`pubspec_overrides.yaml` at its top) and `examples/minimal` to `<dest>/examples/minimal`, with no
root pubspec above them, and writes a `pubspec_overrides.yaml` next to each package's pubspec:

- an empty `resolution:`, so the package is its own root again (dart.dev/tools/pub/workspaces,
  "Temporarily resolving a package outside its workspace");
- a path override for each workspace package it reaches (its dependencies and dev dependencies,
  then their dependencies), so a git dependency on a sibling at `ref: v...` (what an app reads)
  resolves to the checkout's copy. Only those: pub adds every override to the resolution as a
  direct dependency, so overriding a package the package does not use would pull that package's
  constraints into its floor.

The pubspecs are read line by line (standard library only): a top-level `dependencies:` or
`dev_dependencies:` key and its two-space-indented names. cli/tests/versions.rs runs this script
and checks every override set against a real YAML parse.
"""

import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SKIP_AT_TOP = {".dart_tool", "build", "pubspec.lock", "pubspec_overrides.yaml"}
EXAMPLE = "examples/minimal"


def workspace(root):
    """The `workspace:` entries of the root pubspec.yaml, in order (no globs: Dart 3.9 has none)."""
    dirs, inside = [], False
    for line in (root / "pubspec.yaml").read_text(encoding="utf-8").splitlines():
        if line.startswith("workspace:"):
            inside = True
        elif inside and line.startswith("  - "):
            dirs.append(line[4:].split("#")[0].strip())
        elif inside and line.strip() and not line.lstrip().startswith("#"):
            break
    if not dirs:
        sys.exit("floor_copy.py: the root pubspec.yaml has no `workspace:` list")
    return dirs


def dependencies(pubspec, sections):
    """The names under the given top-level sections of a pubspec."""
    names, section = set(), None
    for line in pubspec.read_text(encoding="utf-8").splitlines():
        if line and not line[0].isspace() and not line.startswith("#"):
            section = line.split(":")[0].strip()
        elif section in sections and line.startswith("  ") and not line.startswith("   "):
            name = line.strip().split(":")[0]
            if name and not name.startswith("#"):
                names.add(name)
    return names


def reached(name, members, dev=True):
    """The workspace packages `name` resolves: its (dev) dependencies, then their dependencies.

    `dev=False` leaves out its own dev dependencies: an app that depends on `name` resolves its regular
    dependencies only (scripts/floor_app.py)."""
    found = set()
    sections = {"dependencies", "dev_dependencies"} if dev else {"dependencies"}
    todo = dependencies(members[name] / "pubspec.yaml", sections)
    while todo:
        dep = todo.pop()
        if dep in members and dep != name and dep not in found:
            found.add(dep)
            todo |= dependencies(members[dep] / "pubspec.yaml", {"dependencies"})
    return sorted(found)


def copy(src, dst):
    def ignore(directory, names):
        return [n for n in names if n in SKIP_AT_TOP] if Path(directory) == src else []

    shutil.copytree(src, dst, ignore=ignore, symlinks=True)


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: python3 scripts/floor_copy.py <dest>")
    dest = Path(sys.argv[1]).resolve()
    if dest.exists() and any(dest.iterdir()):
        sys.exit(f"floor_copy.py: {dest} is not empty")
    dirs = workspace(ROOT)
    members = {Path(d).name: ROOT / d for d in dirs}
    for d in [*dirs, EXAMPLE]:
        copy(ROOT / d, dest / d)
    for d in dirs:
        name = Path(d).name
        lines = [
            "# Written by scripts/floor_copy.py: this package on its own, outside the workspace,",
            "# against the checkout's copies of the workspace packages it uses.",
            "resolution:",
        ]
        overrides = reached(name, members)
        if overrides:
            lines.append("dependency_overrides:")
            for dep in overrides:
                lines += [f"  {dep}:", f"    path: ../{dep}"]
        (dest / d / "pubspec_overrides.yaml").write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(dest)


if __name__ == "__main__":
    main()
