/// What a generated `lib/app.main.g.dart` uses, and what a startup.dart imports (since 0.8.1).
///
/// A separate library, so `package:fespalier/fespalier.dart` gains no names an app might
/// already have. [StartupGate] is what `AppMain.root()` returns; `Override`, `ProviderObserver`
/// and `NavigatorObserver` are the types `startup.dart` names in `startup()` and the observer lists:
///
/// ```dart
/// // lib/app/startup.dart
/// import 'package:fespalier/startup.dart';
///
/// Future<List<Override>> startup() async => [/* prefsProvider.overrideWithValue(...) */];
/// List<ProviderObserver> get providerObservers => [];
/// ```
library;

export 'package:flutter/widgets.dart' show NavigatorObserver;
export 'package:hooks_riverpod/hooks_riverpod.dart' show ProviderObserver;
export 'package:hooks_riverpod/misc.dart' show Override;

// What a package plugs into the generated main() (since 0.9.0).
export 'src/adapter.dart' show FespalierAdapter;

// The adapters as one: what the generated `AppAdapters` forwards to (since 0.11.0).
export 'src/adapters.dart' show FespalierAdapters;
export 'src/startup.dart' show StartupGate;
