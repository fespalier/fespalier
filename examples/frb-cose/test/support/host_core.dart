import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_io.dart'
    show ExternalLibrary;
import 'package:frb_cose_example/src/rust/frb_generated.dart';

/// Where Flutter's native-assets build put the core for a host test: `build/native_assets/<os>/`.
///
/// `flutter test` runs `hook/build.dart` before any test, so a missing file is a broken build. This throws, naming
/// the path, and never skips.
String hostCorePath() {
  final (folder, file) = switch (Platform.operatingSystem) {
    'linux' => ('linux', 'libfrb_cose_core.so'),
    'macos' => ('macos', 'libfrb_cose_core.dylib'),
    'windows' => ('windows', 'frb_cose_core.dll'),
    final other => throw UnsupportedError('no host core for $other'),
  };
  final path = File('build/native_assets/$folder/$file');
  if (!path.existsSync()) {
    throw StateError(
      'the core is not at ${path.absolute.path}: flutter test builds it through hook/build.dart',
    );
  }
  return path.absolute.path;
}

Future<void>? _initialized;

/// Loads the core into this test isolate, once.
///
/// The app calls `RustLib.init()` with no argument. A host test cannot: the bare library name does not resolve
/// there, so the test names the file the build put in place.
Future<void> initHostCore() => _initialized ??= RustLib.init(
  externalLibrary: ExternalLibrary.open(hostCorePath()),
);
