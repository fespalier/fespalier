// The test double is what every other test reads, so its own contract is pinned here: the session
// keys merge a report's keys in, a report's snapshot does not change later, the lines keep the order
// of the calls, `clear()` forgets what was recorded and keeps the session's keys, and a broken reporter
// records before it fails.
import 'package:fespalier_crashlytics/fespalier_crashlytics.dart';
import 'package:fespalier_crashlytics/testing.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the session keys merge: a report adds its keys to those the session '
      'set', () {
    final crash = RecordingCrashlytics()
      ..setCustomKey(CrashlyticsKeys.screen, '/home')
      ..recordError(
        StateError('x'),
        null,
        reason: 'in data a.dart',
        keys: {CrashlyticsKeys.operation: 'data'},
      );
    expect(crash.keys, {
      CrashlyticsKeys.screen: '/home',
      CrashlyticsKeys.operation: 'data',
    });
  });

  test('a report keeps a snapshot of the keys, unchanged by a later key', () {
    final crash = RecordingCrashlytics()
      ..setCustomKey(CrashlyticsKeys.screen, '/home')
      ..recordError(
        StateError('x'),
        null,
        reason: 'in data a.dart',
        keys: {CrashlyticsKeys.route: '/items/:id'},
      )
      ..setCustomKey(CrashlyticsKeys.screen, '/other');
    expect(crash.errors.single.keys, {
      CrashlyticsKeys.screen: '/home',
      CrashlyticsKeys.route: '/items/:id',
    });
    expect(crash.keys[CrashlyticsKeys.screen], '/other');
  });

  test('lines are in the order of the calls, one per call', () {
    final crash = RecordingCrashlytics()
      ..setCustomKey('fespalier_screen', '/items/:id')
      ..log('navigation enter /items/:id')
      ..recordError(
        StateError('x'),
        null,
        reason: 'in data items/\$id/data.dart on /items/:id',
        keys: {CrashlyticsKeys.file: r'items/$id/data.dart'},
      );
    expect(crash.lines, [
      'key fespalier_screen=/items/:id',
      'log navigation enter /items/:id',
      r'error StateError in data items/$id/data.dart on /items/:id',
    ]);
  });

  test('strings holds every reason, every key value ever set and every log, '
      'and never an error object', () {
    final crash = RecordingCrashlytics()
      ..setCustomKey('fespalier_screen', '/a')
      ..setCustomKey('fespalier_screen', '/b')
      ..log('navigation enter /b')
      ..recordError(
        StateError('the app\'s own text'),
        null,
        reason: 'in action x.dart#rename on /a',
        keys: {'fespalier_action': 'rename'},
      );
    expect(crash.strings, [
      'in action x.dart#rename on /a',
      '/a',
      '/b',
      'rename',
      'navigation enter /b',
    ]);
    expect(crash.strings.join(), isNot(contains('own text')));
  });

  test('clear() forgets the reports, the lines and the logs, and keeps the '
      'session keys', () {
    final crash = RecordingCrashlytics()
      ..setCustomKey('fespalier_screen', '/home')
      ..log('navigation enter /home')
      ..recordError(StateError('x'), null, reason: 'r', keys: const {});
    crash.clear();
    expect(crash.errors, isEmpty);
    expect(crash.logs, isEmpty);
    expect(crash.lines, isEmpty);
    expect(crash.strings, isEmpty);
    expect(crash.keys, {'fespalier_screen': '/home'});
  });

  test('throwing records, then throws; failing records, then returns a failed '
      'Future', () async {
    final thrower = RecordingCrashlytics(throwing: true);
    expect(() => thrower.log('one'), throwsStateError);
    expect(thrower.logs, ['one']);

    final failer = RecordingCrashlytics(failing: true);
    final future = failer.setCustomKey('fespalier_screen', '/home');
    expect(future, isNotNull);
    await expectLater(future, throwsStateError);
    expect(failer.keys, {'fespalier_screen': '/home'});
  });

  test('a healthy reporter returns no Future', () {
    final crash = RecordingCrashlytics();
    expect(crash.log('x'), isNull);
    expect(crash.setCustomKey('k', 'v'), isNull);
  });
}
