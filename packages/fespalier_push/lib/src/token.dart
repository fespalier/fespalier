import 'package:flutter/foundation.dart';

/// Names for [PushToken.kind] (since 0.14.0). The kind is an open string: these are the spellings
/// the recipes in the fespalier-routing skill use, and an app may pass any other.
abstract final class PushTokenKind {
  /// Firebase Cloud Messaging (Android, iOS through APNs, web).
  static const String fcm = 'fcm';

  /// Apple Push Notification service, read directly (no Firebase).
  static const String apns = 'apns';

  /// Huawei Mobile Services Push Kit.
  static const String hms = 'hms';

  /// UnifiedPush: the endpoint of a distributor.
  static const String unifiedpush = 'unifiedpush';

  /// OneSignal.
  static const String onesignal = 'onesignal';

  /// Xiaomi Mi Push.
  static const String mipush = 'mipush';

  /// OPPO Push.
  static const String oppo = 'oppo';

  /// vivo Push.
  static const String vivo = 'vivo';

  /// Honor Push.
  static const String honor = 'honor';

  /// JPush (Aurora Mobile).
  static const String jpush = 'jpush';
}

Map<String, String> _frozen(Map<String, String> properties) =>
    properties.isEmpty
    ? const <String, String>{}
    : Map<String, String>.unmodifiable(Map<String, String>.of(properties));

int _hashProperties(Map<String, String> properties) => Object.hashAllUnordered(
  properties.entries.map((e) => Object.hash(e.key, e.value)),
);

/// A device's push token, whichever vendor issued it (since 0.14.0). Before 0.14.0 the token was
/// a bare `String`, which tied the package to FCM and APNs.
///
/// [kind] says which service [value] is for ([PushTokenKind]; any string). [properties] holds what
/// a backend needs beyond the token: OneSignal's subscription id, a UnifiedPush instance, ...
///
/// A token is a credential for sending to a device: [toString] prints the [kind] only, never
/// [value] or [properties], and nothing in this package reports either to telemetry.
@immutable
final class PushToken {
  /// A token of [kind]. [properties] is copied and becomes unmodifiable.
  PushToken({
    required this.kind,
    required this.value,
    Map<String, String> properties = const {},
  }) : properties = _frozen(properties);

  /// Which service issued the token, a [PushTokenKind] constant or any string the app chose.
  final String kind;

  /// The token itself. Never logged by this package.
  final String value;

  /// What a backend needs beyond [value], unmodifiable and empty by default.
  final Map<String, String> properties;

  @override
  bool operator ==(Object other) =>
      other is PushToken &&
      other.kind == kind &&
      other.value == value &&
      mapEquals(other.properties, properties);

  @override
  int get hashCode => Object.hash(kind, value, _hashProperties(properties));

  @override
  String toString() => 'PushToken($kind)';
}

/// The token of [kind] stopped being valid on this device: the user unregistered, the vendor
/// invalidated it, the app was signed out of the service (since 0.14.0). It is an event of its
/// own, not a null [PushToken]: [PushToken.value] is never null.
///
/// It carries no token value. [properties] holds what the backend needs to find the registration
/// to drop (an endpoint, a subscription id); like [PushToken.toString], [toString] prints the
/// [kind] only.
@immutable
final class PushTokenRevoked {
  /// A revocation of the token of [kind]. [properties] is copied and becomes unmodifiable.
  PushTokenRevoked({
    required this.kind,
    Map<String, String> properties = const {},
  }) : properties = _frozen(properties);

  /// Which service revoked it, as in [PushToken.kind].
  final String kind;

  /// What identifies the registration, unmodifiable and empty by default.
  final Map<String, String> properties;

  @override
  bool operator ==(Object other) =>
      other is PushTokenRevoked &&
      other.kind == kind &&
      mapEquals(other.properties, properties);

  @override
  int get hashCode => Object.hash(kind, _hashProperties(properties));

  @override
  String toString() => 'PushTokenRevoked($kind)';
}
