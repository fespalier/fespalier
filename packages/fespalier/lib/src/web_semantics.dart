import 'package:flutter/foundation.dart';
import 'package:flutter/semantics.dart';

SemanticsHandle? _handle;

/// Turns Flutter's semantics tree on for good when running on the web, where it is off until a
/// screen reader asks: without it, a test driver that reads the page from the outside (Maestro)
/// finds nothing.
///
/// Off the web it does nothing. The generated `AppRoutes.mount()` calls it when the pubspec says
/// `semantics_ids: true`; calling it again does nothing more. [isWeb] is for tests: it stands in
/// for `kIsWeb`.
void ensureWebSemantics({@visibleForTesting bool isWeb = kIsWeb}) {
  if (!isWeb || _handle != null) return;
  _handle = SemanticsBinding.instance.ensureSemantics();
}

/// Releases what [ensureWebSemantics] turned on, so a test leaves no handle behind.
@visibleForTesting
void debugResetWebSemantics() {
  _handle?.dispose();
  _handle = null;
}
