// The screen as a custom key: the pattern of the page the person is on, sent when it changes (never
// the URL), and each page change as a line in the log.
import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

void main() {
  setUp(() {
    checkout = () => null;
    load = (id) async => 'item $id';
  });
  tearDown(() => FespalierTelemetry.install(null));

  testWidgets('each navigation sets the screen to its pattern, and a pop sets '
      'the page below', (tester) async {
    final rig = Rig();
    final r = await rig.boot(tester);
    unawaited(r.push('/items/7'));
    await tester.pumpAndSettle();
    expect(rig.crash.keys['fespalier_screen'], '/items/:id');
    r.pop();
    await tester.pumpAndSettle();
    expect(rig.crash.keys['fespalier_screen'], '/home');
  });

  testWidgets('the same screen again sends no second key line', (tester) async {
    final rig = Rig();
    final r = await rig.boot(tester);
    r.go('/other');
    await tester.pumpAndSettle();
    r.go('/other');
    await tester.pumpAndSettle();
    expect(
      rig.crash.lines.where((line) => line.startsWith('key fespalier_screen=')),
      ['key fespalier_screen=/other'],
    );
  });

  testWidgets('a location that matches no route sets the screen to empty and '
      'logs it', (tester) async {
    final rig = Rig();
    final r = await rig.boot(tester);
    r.go('/nowhere');
    await tester.pumpAndSettle();
    expect(rig.crash.keys['fespalier_screen'], '');
    expect(rig.crash.logs, contains('navigation not found'));
  });

  testWidgets('a page entered is a log line by its pattern, and a leave '
      'writes none', (tester) async {
    final rig = Rig();
    final r = await rig.boot(tester);
    unawaited(r.push('/items/7'));
    await tester.pumpAndSettle();
    expect(rig.crash.logs, contains('navigation enter /items/:id'));
    r.pop();
    await tester.pumpAndSettle();
    expect(rig.crash.lines.where((line) => line.contains('leave')), isEmpty);
  });

  testWidgets('logs: false writes no log, while the screen and the reports '
      'stay', (tester) async {
    load = (_) => Future<String>.error(StateError('no such item'));
    final rig = Rig(logs: false);
    final r = await rig.boot(tester);
    r.go('/items/7');
    await tester.pumpAndSettle();
    expect(rig.crash.logs, isEmpty);
    expect(rig.crash.keys['fespalier_screen'], '/items/:id');
    expect(rig.crash.errors, hasLength(1));
  });
}
