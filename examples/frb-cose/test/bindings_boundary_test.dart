import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The generated bindings are reached through two files, and nothing else in `lib/` names them.
///
/// `lib/src/core.dart` exports the data types of the core (the seam's), and `lib/src/frb_core.dart` is the one file
/// that wraps the generated opaque object and loads the library. The rest of the app sees `NotesCore` and the plain
/// classes, so the core could be replaced (a fake, the web's) without touching a page.
void main() {
  final app = [
    for (final file in Directory('lib').listSync(recursive: true))
      if (file is File &&
          file.path.endsWith('.dart') &&
          !file.path.contains('lib/src/rust/'))
        file,
  ];
  // The code of a file: its comment lines are left out, so a comment may name what it talks about.
  String read(File file) => file
      .readAsLinesSync()
      .where((line) => !line.trimLeft().startsWith('//'))
      .join('\n');

  test('only core.dart and frb_core.dart import the generated bindings', () {
    final importers = [
      for (final file in app)
        if (RegExp(r"import '(\.\./)*(src/)?rust/").hasMatch(read(file)))
          file.path.replaceAll(r'\', '/'),
    ]..sort();

    expect(importers, ['lib/src/core.dart', 'lib/src/frb_core.dart']);
  });

  test(
    'the library is loaded, and the generated object opened, in frb_core.dart alone',
    () {
      final namers = [
        for (final file in app)
          if (read(file).contains('RustLib') ||
              read(file).contains('NotesCore.open('))
            file.path.replaceAll(r'\', '/'),
      ]..sort();

      expect(namers, ['lib/src/frb_core.dart']);
    },
  );

  test('startup() returns the web fallback before it touches the core', () {
    final startup = read(File('lib/app/startup.dart'));
    final web = startup.indexOf('if (kIsWeb) return unavailableOverrides();');
    final load = startup.indexOf('initRustCore(loadRustCore)');

    expect(web, greaterThanOrEqualTo(0), reason: 'the web branch exists');
    expect(
      load,
      greaterThan(web),
      reason: 'the core loads after the web branch',
    );
  });
}
