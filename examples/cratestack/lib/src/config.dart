/// Where this build's server is and what its signatures are for. `startup()` reads it from the
/// build's `--dart-define`s; a test passes its own.
final class OrdersConfig {
  /// A server at [server], whose signatures name [audience].
  const OrdersConfig({required this.server, required this.audience});

  /// The build's defaults: `server/` on this machine, started with `cargo run`.
  factory OrdersConfig.fromEnvironment() => OrdersConfig(
    server: Uri.parse(
      const String.fromEnvironment(
        'ORDERS_SERVER_URL',
        defaultValue: 'http://127.0.0.1:8788',
      ),
    ),
    audience: const String.fromEnvironment(
      'ORDERS_AUDIENCE',
      defaultValue: 'fespalier-cratestack',
    ),
  );

  /// The origin the generated client calls, and the only one whose requests are signed.
  final Uri server;

  /// The `aud` of every signature: the API it is for (`--audience` of the server).
  final String audience;
}
