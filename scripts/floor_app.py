#!/usr/bin/env python3
"""Writes an app that depends on every package of the pub workspace (the floor job's app check).

    python3 scripts/floor_app.py <tree> <app>

`<tree>` is what `scripts/floor_copy.py` wrote: each workspace package, resolvable on its own. This
writes `<app>`, a Flutter app with a path dependency on every one of them (the names are the root
pubspec.yaml's `workspace:` list, read by floor_copy.py, never a hand list), a `dependency_overrides`
entry for each (so the git dependencies the packages keep on fespalier resolve to the copies, as an
app's own do to the release tag), and `test/imports_test.dart`, which imports every package's main
library.

    cd <app> && flutter pub downgrade && flutter test

is what an app that depends on all of them resolves to at its floor, with one resolution for them all.
A package's own copy (`flutter pub downgrade` in <tree>/packages/<name>) does not test that: it resolves
only that package's graph, and the packages meet in an app. The floor job runs both.
"""

import json
import os
import sys
from pathlib import Path

# Importing floor_copy must not leave a __pycache__ in scripts/ (no ignore rule covers it).
sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))

from floor_copy import ROOT, workspace  # noqa: E402


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: python3 scripts/floor_app.py <tree> <app>")
    tree = Path(sys.argv[1]).resolve()
    app = Path(sys.argv[2]).resolve()
    if app.exists() and any(app.iterdir()):
        sys.exit(f"floor_app.py: {app} is not empty")
    names = [Path(d).name for d in workspace(ROOT)]
    for name in names:
        if not (tree / "packages" / name / "pubspec.yaml").is_file():
            sys.exit(f"floor_app.py: {tree} has no copy of {name}: run scripts/floor_copy.py first")
        if not (ROOT / "packages" / name / "lib" / f"{name}.dart").is_file():
            sys.exit(f"floor_app.py: packages/{name} has no lib/{name}.dart to import")
    app.mkdir(parents=True, exist_ok=True)

    def path_of(name):
        return json.dumps(os.path.relpath(tree / "packages" / name, app))

    lines = [
        "# Written by scripts/floor_app.py: an app with every workspace package, at its lowest versions.",
        "name: floor_app",
        "description: An app that depends on every fespalier package at its floor.",
        "publish_to: none",
        "environment:",
        "  sdk: ^3.9.0",
        '  flutter: ">=3.35.0"',
        "dependencies:",
        "  flutter:",
        "    sdk: flutter",
    ]
    for name in names:
        lines += [f"  {name}:", f"    path: {path_of(name)}"]
    lines += ["dev_dependencies:", "  flutter_test:", "    sdk: flutter", "dependency_overrides:"]
    for name in names:
        lines += [f"  {name}:", f"    path: {path_of(name)}"]
    (app / "pubspec.yaml").write_text("\n".join(lines) + "\n", encoding="utf-8")

    test = [
        "// Written by scripts/floor_app.py: compiling this file compiles every package's main library.",
        "import 'package:flutter_test/flutter_test.dart';",
        "",
    ]
    test += [f"import 'package:{name}/{name}.dart';" for name in names]
    test += [
        "",
        "void main() {",
        "  test('every package imports in one app', () {",
        "    expect(true, isTrue);",
        "  });",
        "}",
    ]
    (app / "test").mkdir(exist_ok=True)
    (app / "test" / "imports_test.dart").write_text("\n".join(test) + "\n", encoding="utf-8")
    print(app)


if __name__ == "__main__":
    main()
