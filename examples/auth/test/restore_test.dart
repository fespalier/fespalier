// startup.dart reads the stored session before the first frame: with a synchronous store the first
// frame is the app, never a splash and never a redirect; with the keychain it is one async read
// behind splash.dart.
import 'dart:convert';

import 'package:auth/api.dart';
import 'package:auth/app.g.dart';
import 'package:auth/app.main.g.dart';
import 'package:auth/auth_setup.dart';
import 'package:auth/demo/demo_backend.dart';
import 'package:auth/demo/demo_server.dart';
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

/// A store that cannot be read: a locked keychain.
final class _Locked implements TokenStore {
  _Locked(this.inner);

  final TokenStore inner;
  bool locked = true;

  @override
  Future<String?> read() async {
    if (locked) throw StateError('keychain locked');
    return inner.read();
  }

  @override
  Future<void> write(String value) async => inner.write(value);

  @override
  Future<void> delete() async => inner.delete();
}

void useStore(DemoServer server, TokenStore store) {
  debugAuthSetup = () => AuthConfig(
    backend: DemoBackend(apiOrigin, server.client),
    store: store,
    apiOrigins: [apiOrigin],
  );
  debugApiClient = () => server.client;
}

void main() {
  tearDown(() {
    debugAuthSetup = null;
    debugApiClient = null;
  });

  testWidgets('a synchronous store: the very first frame is the app', (
    tester,
  ) async {
    final server = DemoServer();
    useStore(server, await signedInStore(server, 'ada'));
    await tester.pumpWidget(AppMain.root());
    // One frame, no pump of the event loop: the session was there before it.
    expect(find.text('Restoring your session...'), findsNothing);
    expect(find.text('Signed in as Ada Example'), findsOneWidget);
  });

  testWidgets(
    'a cold deep link to a signed-in page opens it: no splash, no redirect',
    (tester) async {
      final server = DemoServer();
      useStore(server, await signedInStore(server, 'ada'));
      await tester.pumpWidget(
        AppMain.root(
          router: () => AppRoutes.router(initialLocation: '/orders/1'),
        ),
      );
      expect(find.text('Restoring your session...'), findsNothing);
      await tester.pumpAndSettle();
      expect(find.text('Ada Example: order 1'), findsOneWidget);
      expect(server.requests, isNot(contains('POST /auth/refresh')));
    },
  );

  testWidgets(
    'nothing stored: the app starts signed out, and a guarded link asks for sign-in',
    (tester) async {
      final server = DemoServer();
      useStore(server, MemoryTokenStore());
      await tester.pumpWidget(
        AppMain.root(
          router: () => AppRoutes.router(initialLocation: '/orders'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Sign in to see /orders'), findsOneWidget);
    },
  );

  testWidgets(
    'the keychain is one async read: the splash shows, then the app',
    (tester) async {
      final server = DemoServer();
      final session = await DemoBackend(
        apiOrigin,
        server.client,
      ).signIn(const PasswordSignIn(username: 'bob', password: 'bob'));
      FlutterSecureStorage.setMockInitialValues({
        'fespalier_auth.session': jsonEncode(session.toJson()),
      });
      useStore(server, const SecureTokenStore());
      await tester.pumpWidget(AppMain.root());
      expect(find.text('Restoring your session...'), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.text('Restoring your session...'), findsNothing);
      expect(find.text('Signed in as Bob Example'), findsOneWidget);
    },
  );

  testWidgets(
    'a locked keychain fails startup: the splash says so, and retries',
    (tester) async {
      final server = DemoServer();
      final store = _Locked(await signedInStore(server, 'ada'));
      useStore(server, store);
      await tester.pumpWidget(AppMain.root());
      await tester.pumpAndSettle();
      // Reported to FlutterError.onError, where a crash reporter listens.
      expect(tester.takeException(), isA<StateError>());
      expect(
        find.text("Couldn't restore your session: Bad state: keychain locked"),
        findsOneWidget,
      );
      store.locked = false;
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(find.text('Signed in as Ada Example'), findsOneWidget);
    },
  );

  testWidgets('a session that has expired is dropped without a request', (
    tester,
  ) async {
    final server = DemoServer();
    final store = await signedInStore(server, 'ada');
    final json = jsonDecode(store.value!) as Map<String, Object?>;
    final tokens = json['tokens']! as Map<String, Object?>;
    tokens['refreshExpiresAt'] = DateTime.utc(2000).toIso8601String();
    store.value = jsonEncode(json);
    server.requests.clear();
    useStore(server, store);
    await tester.pumpWidget(AppMain.root());
    expect(find.text('Signed out'), findsOneWidget);
    expect(server.requests, isEmpty, reason: 'restore never asks the network');
    expect(store.value, isNull);
  });
}
