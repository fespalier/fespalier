// The rule for the motion files, in code: a page's motion tag is a value, so it starts no
// timer, no delay, no listener and no frame callback, and reads no wall clock. Core's other files
// are outside this rule; this reads the files that are about motion.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Each construct, and why it is not allowed.
const forbidden = <String, String>{
  'Timer(': 'a timer makes a test flaky',
  'Timer.periodic': 'a periodic timer is work on a schedule',
  'Timer.run': 'scheduled work',
  'Future.delayed': 'a delay is a timer',
  'Stream.periodic': 'a periodic stream is a timer',
  '.timeout(': 'Future.timeout starts a timer',
  'scheduleMicrotask': 'work nobody asked for',
  'addPostFrameCallback': 'work after the frame',
  'scheduleFrame': 'a motion tag never asks for a frame',
  'DateTime.now()': 'the wall clock makes a test flaky',
  '.listen(': 'a listener outlives the call that made it',
  'addListener(': 'a listener the framework owns',
  'addStatusListener(': 'a status listener the framework owns',
  'Ticker(': 'a raw ticker',
  'ProviderScope': 'a tag reads no provider',
  'ref.read': 'a tag reads no provider',
  'ref.watch': 'a tag reads no provider',
};

/// The motion files under lib/.
const motionFiles = [
  'lib/src/page_motion.dart',
  'lib/src/transitions.dart',
  'lib/src/heroes.dart',
  'lib/src/reduced_motion.dart',
];

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
  test(
    'no motion file (the tag, the transitions, the heroes) starts a timer, a delay, a listener or a frame',
    () {
      final problems = [
        for (final path in motionFiles)
          ...violations(path, File(path).readAsLinesSync()),
      ];
      expect(problems, isEmpty, reason: problems.join('\n'));
    },
  );

  test('the check catches each construct, and ignores comments', () {
    for (final line in forbidden.keys.map((k) => 'x = $k;')) {
      expect(violations('f.dart', [line]), isNotEmpty, reason: line);
    }
    expect(violations('f.dart', ['/// Timer(d, f) is not used.']), isEmpty);
    expect(violations('f.dart', ['final x = 1; // not a Timer(']), isEmpty);
  });
}
