import 'dart:async';

import 'segments.dart';

/// Generated redirects call this to chain guards: they run in order and the
/// first one to return a location wins. It stays synchronous until a guard
/// returns a `Future`.
FutureOr<String?> firstRedirect(List<GuardResult Function()> guards) {
  for (var i = 0; i < guards.length; i++) {
    final result = guards[i]();
    if (result is Future<String?>) {
      final rest = guards.sublist(i + 1);
      return result.then((location) => location ?? firstRedirect(rest));
    }
    if (result != null) return result;
  }
  return null;
}

/// Where to go after logging in: [from] (the `?from=` a guard sent along) if
/// it is a location inside this app, otherwise [fallback].
///
/// A guard redirects with `LoginRoute(from: uri.toString()).location`; the
/// login page calls `returnTo(from)` when it is done. Anything that isn't an
/// absolute path in the app (`https://…`, `//host/…`, `javascript:…`) is
/// ignored, so a crafted link can't send people elsewhere.
String returnTo(String? from, {String fallback = '/'}) {
  if (from == null || !from.startsWith('/') || from.startsWith('//')) {
    return fallback;
  }
  if (from.startsWith(r'/\')) return fallback;
  return from;
}
