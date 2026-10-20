#!/usr/bin/env python3
"""Writes an app that depends on every package of the pub workspace (the floor job's app check).

    python3 scripts/floor_app.py [--only <package>] <tree> <app>
    python3 scripts/floor_app.py [--only <package>] --plugins <app>
    python3 scripts/floor_app.py --web <app>

`<tree>` is what `scripts/floor_copy.py` wrote: each workspace package, resolvable on its own. The
first form writes `<app>`, a Flutter app with a path dependency on every one of them (the names are
the root pubspec.yaml's `workspace:` list, read by floor_copy.py, never a hand list), a
`dependency_overrides` entry for each (so the git dependencies the packages keep on fespalier resolve
to the copies, as an app's own do to the release tag), `test/imports_test.dart`, which imports every
public library of every package (each `lib/*.dart`, not `lib/src`), and a `lib/main.dart` with the
same imports and `web/index.html`, which a web build needs. With `--only <package>` the app depends
on that package alone, and overrides it and the workspace packages it reaches (floor_copy.reached):
what an app that uses that one package resolves, where the union of all of them is steered by every
member's constraints at once.

    cd <app> && flutter pub downgrade && flutter pub get

is what an app resolves to at its floor. The second form, run after that, reads
`.flutter-plugins-dependencies` and writes `test/plugins_test.dart`, which imports the Dart
implementation of every plugin the app resolved for Android, iOS, Linux, macOS and Windows
(`flutter.plugin.platforms.<os>.dartPluginClass` and `dartFileName` in each plugin's pubspec).
`flutter test` then compiles them all. The third runs `flutter build web` in the app, and skips when
the SDK has no web artifacts unless FSP_REQUIRE_WEB=1 (CI sets it, so it fails there instead).

Why an app, and not the packages' own floors: a package's own floor also resolves its
`dev_dependencies` (storage's `platform` dev dependency hid platform 3.0.0), and its tests compile
only what they import. An app resolves only the regular dependencies, and a build compiles the plugin
registrant (every `dartPluginClass` of the resolved plugins, which `flutter test` does not) and, on
the web, every import.
"""

import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

# Importing floor_copy must not leave a __pycache__ in scripts/ (no ignore rule covers it).
sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))

from floor_copy import ROOT, reached, workspace  # noqa: E402

# What `flutter build web` needs of web/: an index.html that loads the bootstrap script.
INDEX_HTML = """<!DOCTYPE html>
<html>
  <head>
    <base href="$FLUTTER_BASE_HREF">
    <meta charset="UTF-8">
    <title>floor_app</title>
  </head>
  <body>
    <script src="flutter_bootstrap.js" async></script>
  </body>
</html>
"""

# The platforms whose plugins a build registers from Dart (the web's are `web`, compiled by a web build).
NATIVE = ("android", "ios", "linux", "macos", "windows")


def libraries(package_dir):
    """The public libraries of a package: each `lib/*.dart` file, never `lib/src`."""
    return sorted(p.name for p in (package_dir / "lib").glob("*.dart"))


def import_lines(names, dirs):
    """`import 'package:<name>/<file>' as pN;` for every public library of every package."""
    lines, n = [], 0
    for name in names:
        for file in libraries(ROOT / dirs[name]):
            lines.append(f"import 'package:{name}/{file}' as p{n};")
            n += 1
    return lines


def mapping(text):
    """The nested `key: value` mappings of a YAML file, read line by line (lists and comments skipped)."""
    root = {}
    stack = [(-1, root)]
    for raw in text.splitlines():
        line = raw.split(" #")[0].rstrip()
        if not line.strip() or line.lstrip().startswith(("#", "- ")):
            continue
        indent = len(line) - len(line.lstrip())
        key, sep, value = line.strip().partition(":")
        if not sep:
            continue
        while stack[-1][0] >= indent:
            stack.pop()
        value = value.strip().strip("'\"")
        if value:
            stack[-1][1][key] = value
        else:
            stack[-1][1][key] = node = {}
            stack.append((indent, node))
    return root


def plugin_imports(app):
    """The Dart plugin implementations of the resolved app: {(package, file): [(os, class), ...]}."""
    deps = app / ".flutter-plugins-dependencies"
    if not deps.is_file():
        sys.exit(f"floor_app.py: {deps} is missing: run `flutter pub get` in {app} first")
    found = {}
    for os_name, plugins in json.loads(deps.read_text(encoding="utf-8"))["plugins"].items():
        if os_name not in NATIVE:
            continue
        for plugin in plugins:
            pubspec = mapping((Path(plugin["path"]) / "pubspec.yaml").read_text(encoding="utf-8"))
            entry = pubspec
            for key in ("flutter", "plugin", "platforms", os_name):
                entry = entry.get(key) if isinstance(entry, dict) else None
            if isinstance(entry, dict) and entry.get("dartPluginClass"):
                file = entry.get("dartFileName") or f"{plugin['name']}.dart"
                uses = found.setdefault((plugin["name"], file), [])
                uses.append((os_name, entry["dartPluginClass"]))
    return found


def write_plugins(app, required):
    found = plugin_imports(app)
    if not found:
        # The app with every package has plugins (storage's alone); a package alone may have none.
        if required:
            sys.exit(f"floor_app.py: {app} resolved no plugin with a dartPluginClass: the check proves nothing")
        print(f"floor_app.py: {app} resolved no Dart plugin implementation", file=sys.stderr)
        return
    test = [
        "// Written by scripts/floor_app.py --plugins: the Dart implementation of every plugin this app resolved,",
        "// as the generated dart_plugin_registrant of a Linux, Windows, macOS, iOS or Android build imports it",
        "// (`flutter test` does not compile the registrant, so nothing else here would).",
        "import 'package:flutter_test/flutter_test.dart';",
        "",
    ]
    for n, (key, uses) in enumerate(sorted(found.items())):
        name, file = key
        what = ", ".join(f"{os_name}: {cls}" for os_name, cls in uses)
        test.append(f"import 'package:{name}/{file}' as p{n}; // {what}")
    test += [
        "",
        "void main() {",
        f"  test('the {len(found)} Dart plugin implementations compile', () {{",
        "    expect(true, isTrue);",
        "  });",
        "}",
    ]
    (app / "test").mkdir(exist_ok=True)
    (app / "test" / "plugins_test.dart").write_text("\n".join(test) + "\n", encoding="utf-8")
    print(app / "test" / "plugins_test.dart")


def write_app(tree, app, only=None):
    if app.exists() and any(app.iterdir()):
        sys.exit(f"floor_app.py: {app} is not empty")
    dirs = {Path(d).name: d for d in workspace(ROOT)}
    if only is not None and only not in dirs:
        sys.exit(f"floor_app.py: --only {only}: not a workspace package ({', '.join(dirs)})")
    for name, d in dirs.items():
        if not (tree / d / "pubspec.yaml").is_file():
            sys.exit(f"floor_app.py: {tree} has no copy of {name}: run scripts/floor_copy.py first")
        if not libraries(ROOT / d):
            sys.exit(f"floor_app.py: {d} has no lib/*.dart to import")
    # Every package, or one: a path dependency on it, and an override for it and for the workspace packages it
    # reaches (floor_copy.reached, as floor_copy.py overrides for a package), so a git dependency on a sibling
    # resolves to the copy. Not for the ones only its tests reach: an app resolves regular dependencies only,
    # and an override pulls its package into the resolution (fespalier_dio's tests reach fespalier_auth,
    # whose own constraints would hide a missing one of fespalier_dio's).
    names = [only] if only else list(dirs)
    if only:
        overridden = [only, *reached(only, {n: ROOT / d for n, d in dirs.items()}, dev=False)]
    else:
        overridden = names
    app.mkdir(parents=True, exist_ok=True)

    def path_of(name):
        return json.dumps(os.path.relpath(tree / dirs[name], app))

    what = f"{only} alone" if only else "every workspace package"
    lines = [
        f"# Written by scripts/floor_app.py: an app with {what}, at its lowest versions.",
        "name: floor_app",
        "description: An app that depends on fespalier packages at their floor.",
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
    for name in overridden:
        lines += [f"  {name}:", f"    path: {path_of(name)}"]
    (app / "pubspec.yaml").write_text("\n".join(lines) + "\n", encoding="utf-8")

    test = [
        f"// Written by scripts/floor_app.py: compiling this file compiles every public library of {what}.",
        "import 'package:flutter_test/flutter_test.dart';",
        "",
    ]
    test += import_lines(names, dirs)
    test += [
        "",
        "void main() {",
        f"  test('{what} imports in one app', () {{",
        "    expect(true, isTrue);",
        "  });",
        "}",
    ]
    (app / "test").mkdir(exist_ok=True)
    (app / "test" / "imports_test.dart").write_text("\n".join(test) + "\n", encoding="utf-8")

    # A web build compiles every import, used or not: the app imports every public library.
    main = [
        f"// Written by scripts/floor_app.py: a web build of this file compiles every public library of {what}.",
        "import 'package:flutter/widgets.dart';",
        "",
    ]
    main += import_lines(names, dirs)
    main += ["", "void main() => runApp(const SizedBox());"]
    (app / "lib").mkdir(exist_ok=True)
    (app / "lib" / "main.dart").write_text("\n".join(main) + "\n", encoding="utf-8")
    (app / "web").mkdir(exist_ok=True)
    (app / "web" / "index.html").write_text(INDEX_HTML, encoding="utf-8")
    print(app)


def build_web(app):
    """`flutter build web` in the app: it compiles every import, as a web app's users' build does."""
    flutter = shutil.which("flutter")
    if flutter is None:
        sys.exit("floor_app.py: no flutter on PATH")
    # A Flutter SDK downloads its web artifacts on the first web build, so only an SDK that has none and
    # a run that does not require the build skip it (CI sets FSP_REQUIRE_WEB=1 and downloads them).
    web_sdk = Path(flutter).resolve().parent / "cache" / "flutter_web_sdk"
    if not web_sdk.is_dir() and os.environ.get("FSP_REQUIRE_WEB") != "1":
        print(
            f"floor_app.py: skipping the web build: {web_sdk} is missing, so this Flutter SDK has no web "
            "support (`flutter precache --web` adds it; CI sets FSP_REQUIRE_WEB=1 and fails instead)",
            file=sys.stderr,
        )
        return
    # --no-wasm-dry-run: the dry run of a Wasm build only prints warnings, and takes minutes.
    command = [flutter, "build", "web", "--release", "--no-wasm-dry-run"]
    sys.exit(subprocess.run(command, cwd=app, check=False).returncode)


def main():
    args = sys.argv[1:]
    only = None
    if len(args) >= 2 and args[0] == "--only":
        only, args = args[1], args[2:]
    if len(args) == 2 and args[0] == "--web" and only is None:
        build_web(Path(args[1]).resolve())
    elif len(args) == 2 and args[0] == "--plugins":
        write_plugins(Path(args[1]).resolve(), required=only is None)
    elif len(args) == 2 and not args[0].startswith("-"):
        write_app(Path(args[0]).resolve(), Path(args[1]).resolve(), only)
    else:
        sys.exit(
            "usage: python3 scripts/floor_app.py [--only <package>] <tree> <app>\n"
            "       python3 scripts/floor_app.py [--only <package>] --plugins <app>\n"
            "       python3 scripts/floor_app.py --web <app>"
        )


if __name__ == "__main__":
    main()
