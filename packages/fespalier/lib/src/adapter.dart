import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:hooks_riverpod/misc.dart' show Override;

import 'inbound.dart';

/// What a package plugs into the generated `main()` when an app lists it under
/// `fespalier: adapters:` (since 0.9.0). The package exports one, a top-level named `adapter`,
/// from `lib/fespalier_adapter.dart`:
///
/// ```dart
/// // package:fespalier_connectivity/fespalier_adapter.dart
/// const adapter = ConnectivityAdapter();
/// ```
///
/// Every member has a default that adds nothing, so an adapter overrides what it needs. The
/// generated `main()` calls them in the pubspec's order: the first adapter's zone and wrapper
/// are the outermost. Rules, as for fespalier itself: no timer, sync stays sync, and nothing
/// touches a platform plugin until it is used, so `AppMain.root()` boots in a widget test.
abstract class FespalierAdapter {
  /// Constant, so an adapter with no state is `const`.
  const FespalierAdapter();

  /// Wraps all of `main()`, outside startup.dart's `zone()` and the zones of the adapters listed
  /// after this one: Sentry's `SentryFlutter.init(..., appRunner: body)`. Call [body] once and
  /// complete when it does. Runs before the binding exists.
  Future<void> zone(Future<void> Function() body) => body();

  /// Runs in `main()` after `WidgetsFlutterBinding.ensureInitialized()` and before `runApp`:
  /// installing a telemetry sink (`FespalierTelemetry.add`), opening a store. Return null when
  /// there is nothing to wait for (no `Future`, no microtask); a `Future` is awaited and delays
  /// the first frame (the native splash stays), so keep it to a local read, never the network.
  Future<void>? beforeRun() => null;

  /// Overrides for the app's `ProviderScope`, read once after `startup()` succeeded, before
  /// `startup()`'s own (`dataCacheStorage`, `reconnectSignal`, a flag source). Overriding a
  /// provider `startup()` also overrides is Riverpod's "Tried to override a provider twice" in
  /// debug.
  List<Override> overrides() => const [];

  /// Observers for the `ProviderScope`, before startup.dart's `providerObservers`.
  List<ProviderObserver> providerObservers() => const [];

  /// Observers for the router's root navigator (go_router forwards every shell's pushes to
  /// them), before startup.dart's `routerObservers`. Return new ones on each call: an observer
  /// belongs to one navigator, and a router is built per call.
  List<NavigatorObserver> routerObservers() => const [];

  /// Wraps the root widget, outside the `ProviderScope` and around the splash too
  /// (`SentryWidget`, `PostHogWidget`).
  Widget wrap(Widget root) => root;

  /// Called once per router, after the first frame that shows the router (since 0.11.0), when the
  /// app's `ProviderScope` exists: the generated `AppRoutes.attach` calls it, and the generated
  /// `main()` calls that. Changing a provider here is allowed.
  /// Subscribe here (a notification tap, a shortcut). Do not navigate synchronously. Hold what you
  /// subscribe in a provider of [container] (`container.listen`), so it goes with the
  /// `ProviderScope`. No timer. An adapter that throws here is reported and the app still runs.
  void attach(GoRouter router, ProviderContainer container) {}

  /// Where the app was opened from (since 0.11.0), asked once after [beforeRun] and before the
  /// router is built, never on the web: a notification tap that cold-started the app, a
  /// home-screen shortcut. Null (sync) when this adapter did not open it; every adapter is asked,
  /// in the pubspec's order, so each can clear its pending state, and the first answer wins. A
  /// `Future` delays the first frame like [beforeRun], so keep it to a local read.
  FutureOr<InboundLaunch?> launch() => null;

  /// A navigation is about to be parsed (go_router's `onEnter`, since 0.11.0): null to have no
  /// say, `Allow(then: ...)` to run something after it, `Block.then(...)` to stop it (rewriting a
  /// custom-scheme link: `Block.then(() => router.go('/orders/42'))`, which keeps the link's
  /// `source`). The first adapter to block wins. Never block [InboundNavigation.initial]
  /// (go_router has no route yet and shows an error page): fespalier allows it, reports it with
  /// `FlutterError.reportError`, and still runs the block's `then`; answer [launch] instead.
  ///
  /// A `then` runs after the navigation commits on go_router 17.2 and later; on 17.0 and 17.1
  /// (what Flutter 3.32 resolves) it runs inside the parse, before the commit, and may be lost.
  /// Any `onEnter` makes go_router parse every navigation asynchronously.
  FutureOr<OnEnterResult>? onEnter(InboundNavigation navigation) => null;
}
