// What the reporter is given is the route pattern, the app file and constants, never a value: not a
// segment, not a query, not an error's text, not a validation message, not an action's input. The
// exception objects go to the reporter as the app's own, and `strings` is everything it was told as
// text, so it is what this checks.
import 'package:fespalier/fespalier.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

void main() {
  setUp(() {
    checkout = () => null;
    load = (id) async => 'item $id';
  });
  tearDown(() => FespalierTelemetry.install(null));

  testWidgets('never sends a segment value, a query value or error text in a '
      'log, a key or a reason', (tester) async {
    load = (_) => Future<String>.error(StateError('item 4242 hunter2'));
    final rig = Rig();
    final r = await rig.boot(tester);
    r.go('/items/4242?q=hunter2');
    await tester.pumpAndSettle();
    final c = ProviderContainer();
    addTearDown(c.dispose);
    c.listen(rename, (_, _) {});
    await expectLater(
      c.read(rename.notifier).call('invalid'),
      throwsA(isA<FieldErrors>()),
    );
    await expectLater(c.read(rename.notifier).call('fail'), throwsStateError);
    await c.read(rename.notifier).call('a secret name');

    // The data's report and the action's report are both there, so the check is not vacuous.
    expect(rig.crash.errors, hasLength(2));
    final text = [...rig.crash.strings, ...rig.crash.lines].join('\n');
    expect(text, contains('/items/:id'));
    for (final private in [
      '4242',
      'hunter2',
      'bob@example.com',
      'secret',
      'Bad state',
      'refused',
    ]) {
      expect(text, isNot(contains(private)), reason: private);
    }
  });
}
