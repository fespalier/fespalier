// stream_action.dart (since 0.25.0) makes no timer, no microtask and no listener of its own: the one
// subscription is on the stream the action returned, a run's end is its stream's own event, and its
// lifetime is Riverpod's keep-alive link and `onDispose`. This test reads the source, as the other
// no_timers tests do.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final source = File('lib/src/stream_action.dart').readAsStringSync();
  // The code, with the comment lines taken out.
  final code = source
      .split('\n')
      .where((line) => !line.trimLeft().startsWith('//'))
      .join('\n');

  for (final (forbidden, why) in [
    (r'Timer', 'a timer'),
    (r'Future\.delayed', 'a delay'),
    (r'Stream\.periodic', 'a periodic stream'),
    (r'\.timeout\(', 'a timeout, which is a timer'),
    (r'scheduleMicrotask', 'a microtask'),
    (r'Future\.microtask', 'a microtask'),
    (r'Future(?:<[^>]*>)?\(', 'a Future of our own'),
    (r'addListener\(', 'a listener'),
    (r'listenSelf\(', 'a listener on its own state'),
    (r'\bref\.listen\(', 'a provider listener'),
    (r'addPostFrameCallback', 'work after the frame'),
    (r'DateTime\.now', 'the wall clock'),
    (r'retry', 'a retry: a stream action is never run again by itself'),
  ]) {
    test('stream_action.dart has $why nowhere ($forbidden)', () {
      expect(RegExp(forbidden).hasMatch(code), isFalse);
    });
  }

  test('the only subscription is the one on the action\'s stream', () {
    final listens = RegExp(r'\.listen\(').allMatches(code).toList();
    expect(listens, hasLength(1));
    expect(code, contains('_run(ref, input).listen('));
  });
}
