// The rule, in code: the layout reads the window's width and the menu when it builds, and nothing
// runs in between. No timer, no delay, no listener the framework owns, no wall clock. This reads
// every file under lib/ and fails on the constructs that would break the rule, naming the file and
// the line.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Each construct, and why it is not allowed.
const forbidden = <String, String>{
  'Timer(': 'a timer keeps the radio busy and makes a test flaky',
  'Timer.periodic': 'a periodic timer is work on a schedule',
  'Timer.run': 'scheduled work',
  'Future.delayed': 'a delay is a timer',
  'Stream.periodic': 'a periodic stream is a timer',
  '.timeout(': 'Future.timeout starts a timer',
  'scheduleMicrotask': 'work nobody asked for',
  'addPostFrameCallback':
      'work after the frame: the layout is built from the width',
  'DateTime.now()': 'the wall clock makes a test flaky',
  '.listen(': 'a listener outlives the call that made it',
  'addListener(': 'a listener the framework owns',
  'WidgetsBindingObserver': 'a binding observer the framework owns',
  'didChangeMetrics':
      'the width is read with MediaQuery.sizeOf when the layout builds',
  'MediaQuery.of(': 'MediaQuery.sizeOf rebuilds on the size alone',
};

/// The problems in [lines], one per forbidden construct on a line of code (comments are not code).
List<String> violations(String path, List<String> lines) {
  final problems = <String>[];
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].trimLeft().startsWith('//')) continue;
    final code = lines[i].split(' // ').first;
    for (final entry in forbidden.entries) {
      if (code.contains(entry.key)) {
        problems.add('$path:${i + 1}: ${entry.key} (${entry.value})');
      }
    }
  }
  return problems;
}

void main() {
  test('no file under lib/ starts a timer, a delay or a listener', () {
    final files = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .toList();
    expect(files, isNotEmpty);
    final problems = [
      for (final file in files)
        ...violations(file.path, file.readAsLinesSync()),
    ];
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  test('the model library imports no Material', () {
    // package:fespalier_adaptive/fespalier_adaptive.dart is widgets only, so an app on
    // material_ui or Cupertino can use it without Flutter's Material widgets.
    final model = [
      'lib/fespalier_adaptive.dart',
      'lib/src/adaptive_nav.dart',
      'lib/src/breakpoints.dart',
      'lib/src/builder.dart',
      'lib/src/messages.dart',
    ];
    for (final path in model) {
      final text = File(path).readAsStringSync();
      expect(
        text,
        isNot(contains('package:flutter/material.dart')),
        reason: '$path imports Material',
      );
      expect(
        text,
        isNot(contains('material_scaffold.dart')),
        reason: '$path reaches the Material scaffold',
      );
    }
  });

  test('the check catches each construct, and ignores comments', () {
    for (final line in [
      'final t = Timer(d, f);',
      'Timer.periodic(d, f);',
      'await Future.delayed(d);',
      'Stream.periodic(d);',
      'x.timeout(d);',
      'scheduleMicrotask(f);',
      'WidgetsBinding.instance.addPostFrameCallback((_) {});',
      'final now = DateTime.now();',
      'stream.listen(print);',
      'notifier.addListener(f);',
      'class A with WidgetsBindingObserver {}',
      'void didChangeMetrics() {}',
      'final s = MediaQuery.of(context).size;',
    ]) {
      expect(violations('f.dart', [line]), isNotEmpty, reason: line);
    }
    expect(
      violations('f.dart', [
        '/// Timer(d, f) is not used.',
        '// DateTime.now()',
      ]),
      isEmpty,
    );
    expect(violations('f.dart', ['final x = 1; // not a Timer(']), isEmpty);
    expect(
      violations('f.dart', ['final w = MediaQuery.sizeOf(context).width;']),
      isEmpty,
    );
  });
}
