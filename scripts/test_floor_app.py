#!/usr/bin/env python3
"""Tests scripts/floor_app.py's reading of the plugin list of a resolved app.

    python3 scripts/test_floor_app.py
"""

import io
import json
import sys
import tempfile
import unittest
from contextlib import redirect_stderr
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).parent))
import floor_app  # noqa: E402


class PluginImports(unittest.TestCase):
    def app(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        return Path(tmp.name)

    def test_no_pub_get_is_an_error(self):
        # Neither the plugin list nor the package config: `flutter pub get` did not run.
        with self.assertRaises(SystemExit) as raised, redirect_stderr(io.StringIO()):
            floor_app.plugin_imports(self.app())
        self.assertIn("is missing", str(raised.exception))

    def test_pure_dart_app_has_no_plugin_list_and_no_plugins(self):
        # `flutter pub get` writes no `.flutter-plugins-dependencies` when nothing resolved is a plugin.
        app = self.app()
        (app / ".dart_tool").mkdir()
        (app / ".dart_tool" / "package_config.json").write_text("{}", encoding="utf-8")
        self.assertEqual(floor_app.plugin_imports(app), {})

    def test_pure_dart_app_alone_passes_and_all_packages_app_still_demands_a_plugin(self):
        app = self.app()
        (app / ".dart_tool").mkdir()
        (app / ".dart_tool" / "package_config.json").write_text("{}", encoding="utf-8")
        with redirect_stderr(io.StringIO()):
            floor_app.write_plugins(app, required=False)
        with self.assertRaises(SystemExit) as raised:
            floor_app.write_plugins(app, required=True)
        self.assertIn("resolved no plugin", str(raised.exception))

    def test_a_plugin_with_a_dart_implementation_is_listed(self):
        app = self.app()
        plugin = app / "plugin_pkg"
        plugin.mkdir()
        (plugin / "pubspec.yaml").write_text(
            "name: plugin_pkg\n"
            "flutter:\n"
            "  plugin:\n"
            "    platforms:\n"
            "      linux:\n"
            "        dartPluginClass: PluginPkgLinux\n",
            encoding="utf-8",
        )
        (app / ".flutter-plugins-dependencies").write_text(
            json.dumps({"plugins": {"linux": [{"name": "plugin_pkg", "path": str(plugin)}], "web": []}}),
            encoding="utf-8",
        )
        self.assertEqual(
            floor_app.plugin_imports(app),
            {("plugin_pkg", "plugin_pkg.dart"): [("linux", "PluginPkgLinux")]},
        )


if __name__ == "__main__":
    unittest.main()
