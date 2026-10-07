// The rule, in code: the package starts no timer, schedules no work for later and never reads the
// wall clock. A form is built on a text controller and the hook that owns and disposes it, so
// listeners are allowed (the hook removes each one); a timer is not, because a test could not pump
// past it. This reads every file under lib/ and fails on the constructs that would break the rule,
// naming the file and the line.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Each construct, and why it is not allowed.
const forbidden = <String, String>{
  'Timer(':
      'a timer makes a test flaky: a form changes on an event, never on a schedule',
  'Timer.periodic': 'a periodic timer is work on a schedule',
  'Timer.run': 'scheduled work',
  'Future.delayed': 'a delay is a timer',
  'Stream.periodic': 'a periodic stream is a timer',
  '.timeout(': 'Future.timeout starts a timer',
  'scheduleMicrotask': 'work nobody asked for: a sync submit stays sync',
  'Future.microtask': 'work nobody asked for: a sync submit stays sync',
  'DateTime.now()': 'the form reads no clock',
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
  test('no file under lib/ starts a timer, a delay or a microtask', () {
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

  test('the check catches each construct, and ignores comments', () {
    for (final line in [
      'final t = Timer(d, f);',
      'Timer.periodic(d, f);',
      'Timer.run(f);',
      'await Future.delayed(d);',
      'Stream.periodic(d);',
      'x.timeout(d);',
      'scheduleMicrotask(f);',
      'Future.microtask(f);',
      'final now = DateTime.now();',
    ]) {
      expect(violations('f.dart', [line]), hasLength(1), reason: line);
    }
    expect(
      violations('f.dart', [
        '/// Timer(d, f) is not used.',
        '// DateTime.now()',
      ]),
      isEmpty,
    );
    expect(violations('f.dart', ['final x = 1; // not a Timer(']), isEmpty);
    expect(violations('f.dart', ['controller.addListener(f);']), isEmpty);
  });
}
