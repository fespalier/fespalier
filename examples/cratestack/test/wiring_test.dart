// The wiring, without a network or a key: one transport built in startup() in the order docs/transport.md
// gives, a session that signs only for the server's origin, and the generated client's two seams
// overridden with that session and the origin.
import 'dart:io';

import 'package:cratestack_example/src/errors.dart';
import 'package:cratestack_example/src/wiring.dart';
import 'package:fespalier/fespalier.dart' show ProviderContainer;
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_cratestack/fespalier_cratestack.dart';
import 'package:fespalier_sign_keypair/fespalier_sign_keypair.dart';
import 'package:fespalier_transport/fespalier_transport.dart'
    show TransportAborted, TransportUnsent;
import 'package:flutter_test/flutter_test.dart';
import 'package:orders_client/orders_client.dart';

import 'fake_server.dart';
import 'support.dart';

void main() {
  test(
    'startup() builds PortalTransport over WriteGuardTransport over HttpClientTransport',
    () {
      // The code, without its comments.
      final source = File('lib/app/startup.dart')
          .readAsLinesSync()
          .where((line) => !line.trimLeft().startsWith('//'))
          .join('\n');
      expect(
        source,
        matches(
          RegExp(
            r'PortalTransport\(\s*WriteGuardTransport\(HttpClientTransport\(http\.Client\(\)\)\)\s*,?\s*\)',
          ),
        ),
      );
      // One chain: built once, and handed to the session and the ceremonies.
      expect(RegExp(r'PortalTransport\(').allMatches(source), hasLength(1));
      expect(RegExp(r'http\.Client\(\)').allMatches(source), hasLength(1));
    },
  );

  test(
    'the app signs in with a DeviceAuthBackend, and signs only for its server',
    () {
      final server = FakeOrdersServer();
      final config = authSetup(
        network(server),
        testConfig,
        store: MemoryTokenStore(),
      );
      expect(config.backend, isA<DeviceAuthBackend>());
      expect(config.backend.name, 'device');
      expect(config.apiOrigins, [testConfig.server]);
      expect(server.served, isEmpty);
    },
  );

  test(
    'the generated client sends through the session, to the server\'s origin',
    () async {
      final server = FakeOrdersServer();
      final container = ProviderContainer(
        overrides: [...await appOverrides(server, FakeDevice())],
      );
      addTearDown(container.dispose);
      final transport = container.read(ordersClientTransportProvider);
      expect(
        transport,
        same(container.read(authTransport)),
        reason: 'the session itself: nothing above it asks for a key',
      );
      expect(container.read(ordersClientBaseUriProvider), testConfig.server);
      expect(
        container.read(ordersClientAdapterProvider),
        isA<CratestackRpcHttpAdapter>(),
      );
      expect(container.read(crateStackErrors), same(ordersErrors));
    },
  );

  test('what the generated client throws is classified', () {
    final unsent = CratestackTransportUnsent(
      cause: TransportUnsent(null, Uri.parse('http://x/')),
    );
    expect(ordersErrors.classify(unsent), isA<CrateStackOffline>());
    expect(
      ordersErrors.classify(
        CratestackTransportAborted(
          cause: TransportAborted(null, Uri.parse('http://x/')),
        ),
      ),
      isA<CrateStackCancelled>(),
    );
    expect(
      ordersErrors.classify(
        CratestackRpcException(
          status: 422,
          body: const RpcErrorBody(
            code: 'invalid_argument',
            message: "field 'item' is bad",
          ),
        ),
      ),
      isA<CrateStackRefused>().having(
        (r) => r.code,
        'code',
        'invalid_argument',
      ),
    );
    expect(
      ordersErrors.classify(
        CratestackRpcException(
          status: 403,
          body: const RpcErrorBody(
            code: 'permission_denied',
            message: 'user_presence_required',
          ),
        ),
      ),
      isA<CrateStackRefused>().having(
        (r) => r.code,
        'code',
        'permission_denied',
      ),
    );
  });
}
