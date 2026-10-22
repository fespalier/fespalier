import 'fespalier_transport.dart';
import 'package:fespalier_transport/fespalier_transport.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'procedures.dart';
import 'runtime.dart';

class OrdersClientCratestackClient {
  OrdersClientCratestackClient(this._adapter);

  final CratestackRpcAdapter _adapter;

  CratestackRpcAdapter get adapter => _adapter;

  ProceduresApi get procedures => ProceduresApi(this);
}

/// The transport every generated call sends through: your `fespalier_transport`
/// chain. No default; the app provides it once.
///
/// ```dart
/// ProviderScope(
///   overrides: [
///     ordersClientTransportProvider.overrideWith(
///       (ref) => SessionTransport(
///         WriteGuardTransport(HttpClientTransport(client)),
///         ref.watch(credentialsProvider),
///       ),
///     ),
///     ordersClientBaseUriProvider.overrideWithValue(
///       Uri.parse('https://api.example.com'),
///     ),
///   ],
///   child: const MyApp(),
/// )
/// ```
final ordersClientTransportProvider = Provider<HttpTransport>((ref) {
  throw UnimplementedError(
      'Override ordersClientTransportProvider with your fespalier_transport chain before reading the generated CrateStack client.');
});

/// The server's origin, with an optional path prefix, that request paths are
/// joined onto: `https://api.example.com` or `https://example.com/v1`. No
/// default.
final ordersClientBaseUriProvider = Provider<Uri>((ref) {
  throw UnimplementedError(
      'Override ordersClientBaseUriProvider with the server\'s origin before reading the generated CrateStack client.');
});

/// The adapter every generated API sends through: the HTTP adapter over
/// [ordersClientTransportProvider]. Override it only to change the wire
/// format or to use another adapter.
final ordersClientAdapterProvider = Provider<CratestackRpcAdapter>((ref) {
  return CratestackRpcHttpAdapter(
    CratestackFespalierTransport(ref.watch(ordersClientTransportProvider)),
    baseUri: ref.watch(ordersClientBaseUriProvider),
  );
});

final ordersClientClientProvider =
    Provider<OrdersClientCratestackClient>((ref) {
  return OrdersClientCratestackClient(ref.watch(ordersClientAdapterProvider));
});
