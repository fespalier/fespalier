// The rule, in code: the framework starts no timer, schedules nothing for later and listens to
// nothing. Sentry's own timers (`autoFinishAfter` of a transaction, the time to full display
// deadline) are the SDK's, and this sink never asks for one: a screen's transaction ends when its
// data arrives or when the next navigation starts. The clock is read through `package:clock`, never
// `DateTime.now()`, so a test's fake clock decides the repeat window. This reads every file under
// lib/ and fails on the constructs that would break the rule, naming the file and the line.
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
  'scheduleFrame': 'a frame nobody asked for',
  'addPostFrameCallback': 'a callback after a frame nobody asked for',
  'DateTime.now()': 'read clock.now(), so a test can move time',
  '.listen(': 'a listener outlives the call that made it',
  '.addListener(': 'a listener outlives the call that made it',
  'autoFinishAfter':
      'Sentry starts a timer for it: end the transaction ourselves',
  'waitForChildren': 'Sentry waits with a timer: end the transaction ourselves',
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
  test('no file under lib/ starts a timer, a delay or a listener, schedules a '
      'frame or reads the wall clock', () {
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
      'await Future.delayed(d);',
      'Stream.periodic(d);',
      'x.timeout(d);',
      'scheduleMicrotask(f);',
      'binding.scheduleFrame();',
      'binding.addPostFrameCallback((_) {});',
      'final now = DateTime.now();',
      'stream.listen(print);',
      'notifier.addListener(f);',
      'hub.startTransaction(a, b, autoFinishAfter: d);',
      'hub.startTransaction(a, b, waitForChildren: true);',
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
    expect(violations('f.dart', ['final now = clock.now();']), isEmpty);
  });
}
