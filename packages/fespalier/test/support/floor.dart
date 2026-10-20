// What differs on Flutter 3.35, the floor the package declares, and what the tests tolerate there.
// CI's `floor` job (and `just floor`) runs the package on 3.35 with `flutter pub downgrade`.
//
// Each flag names what it is about, and is true on every Flutter that has it, not only on the
// floor; on the Flutter the `dart` job runs (3.47, the newest go_router) none is, so every test is
// strict.
import 'dart:convert' show jsonDecode;
import 'dart:io' show Directory, File, Platform;

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

/// The go_router the tests run on, `[18, 1, 1]`, read from the package config the resolution wrote
/// (the first `.dart_tool/package_config.json` from the working directory up, which is the
/// workspace's root in the checkout and the copy's own folder in the `floor` job) and the
/// `pubspec.yaml` of the go_router it names. Null when that cannot be read: every flag below then
/// answers for the newest go_router, so a test is strict rather than skipped.
final List<int>? goRouterVersion = _goRouterVersion();

List<int>? _goRouterVersion() {
  try {
    for (var dir = Directory.current; ; dir = dir.parent) {
      final config = File('${dir.path}/.dart_tool/package_config.json');
      if (config.existsSync()) {
        final packages =
            (jsonDecode(config.readAsStringSync()) as Map)['packages']
                as List<dynamic>;
        for (final package in packages.cast<Map<String, dynamic>>()) {
          if (package['name'] != 'go_router') continue;
          // pub writes a hosted package's `rootUri` with no trailing slash, which `resolve`
          // would take for a file name.
          var root = package['rootUri'] as String;
          if (!root.endsWith('/')) root = '$root/';
          final pubspec = File.fromUri(
            config.uri.resolve(root).resolve('pubspec.yaml'),
          );
          final match = RegExp(
            r'^version:\s*(\d+)\.(\d+)\.(\d+)',
            multiLine: true,
          ).firstMatch(pubspec.readAsStringSync());
          if (match == null) return null;
          return [for (var i = 1; i <= 3; i++) int.parse(match[i]!)];
        }
        return null;
      }
      if (dir.parent.path == dir.path) return null;
    }
  } on Object {
    return null;
  }
}

/// Whether go_router is older than 18.1.1, which includes the floor's 17.2.3 and 18.0 to 18.1.0
/// (released 2026-10-14; 18.1.1 came on 2026-10-20).
///
/// - A redirect that fails after an `await` (a guard whose `Future` completes with an error) never
///   reaches `errorBuilder` or `onException`: go_router ran every redirect in a `runZonedGuarded`
///   zone, which is an error zone, so the failure is reported there and is not passed on to the
///   `Future`s go_router waits on. It rethrew it as an uncaught `GoException` ("Exception during
///   redirect: ..."), and the navigation never finished: the router stayed on the page it was
///   on. 18.1.1 forks a plain zone for the router's context, so the same failure is a
///   `GoException` ("Exception during route redirect: ..." for a route's redirect, "Exception
///   during redirect: ..." for the top-level one) in the error route, which `errorBuilder` or
///   `onException` gets, as a redirect that throws before an `await` always did. Nothing is
///   uncaught. What a test can tell both apart by is `GoRouterState.error` and the zone's errors,
///   never the exception's message.
/// - A `StatefulShellRoute` that is replaced (`GoRouter.routingConfig`, a hot reload's swap) keeps
///   the loaded branches that are not on screen when its branches reuse their navigator keys, and
///   parses their saved locations again (18.1.1 keys the branch state by the navigator key, where
///   it was keyed by the `StatefulShellBranch` object, which a new table makes again). Before it,
///   only the branch on screen kept its stack and the others started over at their first page.
final bool beforeGoRouter1811 = _olderThan(goRouterVersion, const [18, 1, 1]);

bool _olderThan(List<int>? version, List<int> than) {
  if (version == null) return false;
  for (var i = 0; i < than.length; i++) {
    if (version[i] != than[i]) return version[i] < than[i];
  }
  return false;
}
