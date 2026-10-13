// What differs on Flutter 3.35, the floor the package declares, and what the tests tolerate there.
// CI's `floor` job (and `just floor`) runs the package on 3.35 with `flutter pub downgrade`.
//
// Each flag names what it is about, and is true on every Flutter that has it, not only on the
// floor; on the Flutter the `dart` job runs (3.47, go_router 18) none is, so every test is strict.
import 'dart:io' show Platform;

import 'package:flutter_test/flutter_test.dart';

/// The Dart minor the tests run on (`3.9` is `9`), which tells the Flutter: 3.35 to 3.37 run Dart
/// 3.9, 3.38 to 3.43 run 3.10 and 3.11, and 3.44 runs 3.12.
final int _dartMinor = int.parse(
  RegExp(r'^3\.(\d+)').firstMatch(Platform.version)![1]!,
);

/// Whether the Flutter is older than 3.38 (Dart 3.9), which includes the floor, 3.35.
///
/// - go_router stops at 17.2.3 there (17.3.0 needs Flutter 3.38), and go_router 17.0 to 17.3
///   pop a whole `ShellRoute` page without asking its leaf's `onExit` (fixed in 17.4.0).
/// - `SemanticsConfiguration.absorb` drops a child's `linkUrl` (Flutter 3.38 keeps it).
final bool beforeFlutter338 = _dartMinor < 10;

/// Whether the Flutter is older than 3.44 (Dart below 3.12), which cannot resolve go_router 18.
///
/// go_router 17 builds the page a `go` lands on one frame after the location changes; go_router
/// 18 builds it in the same frame.
final bool onGoRouter17 = _dartMinor < 12;

/// A navigation's frame: one `pump` where go_router builds the page in the same frame, and
/// `pumpAndSettle` on go_router 17, which takes a second one to finish a `go`.
Future<void> pumpNavigation(WidgetTester tester) =>
    onGoRouter17 ? tester.pumpAndSettle() : tester.pump();
