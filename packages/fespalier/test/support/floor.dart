// What differs on Flutter 3.32, the floor the package declares, and what the tests tolerate there.
// CI's `floor` job (and `just floor`) runs the package on 3.32 with `flutter pub downgrade`.
import 'dart:io' show Platform;

import 'package:flutter_test/flutter_test.dart';

/// Whether the tests run on Flutter 3.32 (Dart 3.8), the oldest Flutter the package supports.
///
/// Flutter 3.32 resolves go_router 17.0.0 and no newer one (17.0.1 needs Flutter 3.35), so the
/// go_router behaviour of that release is the one the floor has.
final bool onFlutterFloor = Platform.version.startsWith('3.8.');

/// A navigation's frame: one `pump` where go_router settles in one, and `pumpAndSettle` on the
/// floor, where go_router 17.0.0 takes a second one to finish a `go`.
Future<void> pumpNavigation(WidgetTester tester) =>
    onFlutterFloor ? tester.pumpAndSettle() : tester.pump();
