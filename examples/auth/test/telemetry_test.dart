// fespalier_auth reports to whatever sink is installed, with no `telemetry: true` in the pubspec:
// the restore, the sign-in and the renewal are spans, and none carries a token or a name.
import 'package:auth/app.g.dart';
import 'package:auth/demo/demo_server.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_oidc/fespalier_oidc.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

void main() {
  late RecordingTelemetry rec;
  setUp(() {
    rec = RecordingTelemetry();
    FespalierTelemetry.install(rec);
  });
  tearDown(() => FespalierTelemetry.install(null));

  testWidgets('the restore, the sign-in and the renewal are auth spans', (
    tester,
  ) async {
    final server = DemoServer();
    final container = await pumpRouter(
      tester,
      AppRoutes.router(initialLocation: '/sign-in'),
      overrides: demoOverrides(server),
    );
    await container
        .read(authSession.notifier)
        .signIn(const PasswordSignIn(username: 'ada', password: 'ada'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(minutes: 6));
    await container.read(authSession.notifier).credential();

    expect(rec.log, [
      '#1 start auth restore backend=demo scheme=bearer',
      '#1 end auth none',
      '#2 start auth sign_in backend=demo scheme=bearer',
      '#2 end auth ok async',
      '#3 start auth renew backend=demo trigger=expired scheme=bearer',
      '#3 end auth ok async',
    ]);
    final text = rec.log.join('\n');
    for (final private in [
      'demo-access',
      'demo-refresh',
      'ada',
      'Ada',
      'example.com',
    ]) {
      expect(text, isNot(contains(private)));
    }
  });

  testWidgets('a refused renewal is rejected, not an error', (tester) async {
    final server = DemoServer();
    final container = await pumpRouter(
      tester,
      AppRoutes.router(initialLocation: '/sign-in'),
      overrides: demoOverrides(server),
    );
    final notifier = container.read(authSession.notifier);
    await notifier.signIn(
      const PasswordSignIn(username: 'bob', password: 'bob'),
    );
    server.endSessions();
    await tester.pumpAndSettle();
    await expectLater(
      notifier.credential(forceRenew: true),
      throwsA(isA<AuthRejected>()),
    );
    expect(rec.log.last, '#3 end auth rejected async');
    expect(
      container.read(authSession),
      const SignedOut(reason: SignOutReason.expired),
    );
  });
}
