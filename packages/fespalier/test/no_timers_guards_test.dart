// guards.dart makes no timer, no microtask and no listener of its own (invariant 11 of the guards,
// since 0.21.0): everything a pushed page's guard does later is a post-frame callback, a callback of
// a Future the guard returned (go_router's own redirect), or a callback of a provider the guard
// watches. Identity comes from go_router's completers and requests, so there is no provider
// listener (#264), no zone that tells a re-run and no count of notifications. This test reads the source, as
// the other no_timers tests do.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final source = File('lib/src/guards.dart').readAsStringSync();
  // The code, with the comment lines taken out.
  final code = source
      .split('\n')
      .where((line) => !line.trimLeft().startsWith('//'))
      .join('\n');

  for (final (forbidden, why) in [
    (r'Timer', 'a timer'),
    (r'Timer.periodic', 'a periodic timer'),
    (r'Future.delayed', 'a delay'),
    (r'scheduleMicrotask', 'a microtask'),
    (r'Future.microtask', 'a microtask'),
    (r'Future(?:<[^>]*>)?\(', 'a Future of our own'),
    (r'routeInformationProvider\s*\.\s*addListener', 'a provider listener'),
    (r'runZoned', 'a zone that tells a re-run'),
    (r'DateTime.now', 'the wall clock'),
    (r'addListener\(_requested', 'a listener on the requests'),
  ]) {
    test('guards.dart has $why nowhere ($forbidden)', () {
      expect(RegExp(forbidden).hasMatch(code), isFalse);
    });
  }

  test('the only listener guards.dart adds is on the delegate', () {
    final adds = RegExp(
      r'(\w+(?:\s*\.\s*\w+)*)\s*\.addListener\(',
    ).allMatches(code).toList();
    expect(adds, hasLength(1));
    expect(adds.single.group(1), endsWith('routerDelegate'));
  });

  test('the only zone guards.dart touches is the one a redirect runs in', () {
    // `runRedirect` forks the zone that called go_router for go_router 17.2.3 to 18.1.0, whose
    // redirect error zone loses the failure of a Future; a re-run starts in the zone it started in.
    final forks = RegExp(r'\.fork\(').allMatches(code).length;
    expect(forks, 1);
    expect(RegExp(r'zone\.run\(').allMatches(code).length, 1);
  });

  test('every deferred callback is a post-frame callback', () {
    final deferred = RegExp(r'addPostFrameCallback').allMatches(code).length;
    expect(deferred, greaterThanOrEqualTo(3));
  });
}
