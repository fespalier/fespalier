/// A notification as fespalier_push sees it, whatever sent it (since 0.13.0).
final class PushMessage {
  /// A message with the payload's custom keys in [data].
  const PushMessage({this.id, this.data = const {}, this.category, this.raw});

  /// The provider's message id. It dedupes a tap that some Android and plugin combinations deliver
  /// twice (once as the launch, once on the tap stream); null when the provider has none.
  final String? id;

  /// The payload's custom keys. Never reported to telemetry.
  final Map<String, Object?> data;

  /// The APNs category or the Android `click_action`, when there is one.
  final String? category;

  /// The vendor's own object (a `RemoteMessage`), for the app's mapping only. The package never
  /// reads it.
  final Object? raw;

  @override
  String toString() => 'PushMessage(id: $id)';
}
