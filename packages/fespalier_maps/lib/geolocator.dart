/// The device position for the pin picker (since 0.12.0): the one library of this package that
/// imports `geolocator`.
///
/// Nothing here runs in a widget test (it reaches a platform channel): tests use
/// `FakePositionSource` from `package:fespalier_maps/testing.dart`.
library;

import 'package:geolocator/geolocator.dart';

import 'fespalier_maps.dart';

/// A [PositionSource] over `geolocator`'s one-shot fix.
///
/// The permission prompt is the platform's own (`requestPermission`); the package opens no
/// dialog, and the app declares the permission in its manifest and `Info.plist` as geolocator's
/// README says. Every outcome is a [PositionFix], never an exception.
class GeolocatorPositionSource implements PositionSource {
  /// A source asking for [accuracy], giving up after [timeLimit] (the plugin's own limit:
  /// this package starts no timer).
  const GeolocatorPositionSource({
    this.accuracy = LocationAccuracy.high,
    this.timeLimit = const Duration(seconds: 15),
  });

  /// The accuracy to ask for.
  final LocationAccuracy accuracy;

  /// How long to wait for a fix.
  final Duration timeLimit;

  @override
  Future<PositionFix> current() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        return const ServiceOff();
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      switch (permission) {
        case LocationPermission.deniedForever:
          return const Denied(permanent: true);
        case LocationPermission.denied:
          return const Denied();
        case LocationPermission.unableToDetermine:
          return const Unavailable();
        case LocationPermission.whileInUse:
        case LocationPermission.always:
          break;
      }
      final position = await Geolocator.getCurrentPosition(
        locationSettings: LocationSettings(
          accuracy: accuracy,
          timeLimit: timeLimit,
        ),
      );
      return Fixed(
        GeoPoint(position.latitude, position.longitude),
        accuracyMeters: position.accuracy,
      );
    } catch (_) {
      return const Unavailable();
    }
  }
}
