import 'dart:async';
import 'dart:ui' show Brightness, PlatformDispatcher;

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:hooks_riverpod/misc.dart' show Override;

/// Runs the app's `startup()` and shows `splash.dart` meanwhile, then builds a `ProviderScope`
/// with the overrides it returned around [app] and the router [router] makes. What the
/// generated `AppMain.root()` returns (since 0.8.1).
///
/// With startup.dart's `ready(container)` (since 0.12.0) the gate makes the `ProviderContainer`
/// itself, with the same overrides, observers and retry policy, runs [ready] on it, and only then
/// hosts it (`UncontrolledProviderScope`) and builds the router. The order is `startup()`, the
/// container, `ready`, the router, then the `attach` callbacks after the router's first frame.
/// [ready] gets the same treatment as `startup()`: a sync one is done before the first frame, an
/// async one shows [splash] (or defers the first frame), and one that throws is reported and
/// shown with a retry, which disposes that container, makes a fresh one and runs [ready] again
/// (`startup()` is not run again: it had succeeded).
///
/// Sync stays sync: a `startup()` that does not return a `Future` is done before the first
/// frame, which is the app. A `Future` costs a frame, so with a [splash] it is shown meanwhile;
/// without one the first frame is deferred (`WidgetsBinding.deferFirstFrame`), so the native
/// splash (the launch screen, the web's loading page) stays until the app is ready. A
/// `startup()` that throws is reported (`FlutterError.reportError`, so `FlutterError.onError`
/// sees it) and shown: [splash] with the error and a retry, or a plain message.
///
/// No timer is involved anywhere: the gate follows the `Future` with `then`.
class StartupGate extends StatefulWidget {
  /// A gate for the code `fsp gen` writes; apps use `AppMain.root()` instead.
  const StartupGate({
    super.key,
    this.startup,
    this.overrides,
    this.extraOverrides,
    this.splash,
    this.observers,
    this.retry,
    this.ready,
    this.attach,
    this.appAttach,
    required this.router,
    required this.app,
  }) : assert(
         startup == null || overrides == null,
         'startup or overrides, not both',
       );

  /// startup.dart's `startup()` when it returns no overrides.
  final FutureOr<void> Function()? startup;

  /// startup.dart's `startup()` when it returns the providers to override.
  final FutureOr<List<Override>> Function()? overrides;

  /// Overrides the generated `main()` adds before `startup()`'s own (the adapters', since
  /// 0.9.0): read once, after `startup()` succeeded.
  final List<Override> Function()? extraOverrides;

  /// splash.dart: [error] is null while `startup()` runs, and [retry] too.
  final Widget Function(
    Object? error,
    StackTrace? stackTrace,
    VoidCallback? retry,
  )?
  splash;

  /// Read once, after `startup()`: the `ProviderScope`'s observers.
  final List<ProviderObserver> Function()? observers;

  /// The `ProviderScope`'s retry policy.
  final Duration? Function(int retryCount, Object error)? retry;

  /// startup.dart's `ready(container)` (since 0.12.0): run on the app's own container, which
  /// the gate then makes itself, before the router is built. A `Future` shows [splash] meanwhile;
  /// an error is reported and shown with a retry, which runs it on a fresh container.
  final FutureOr<void> Function(ProviderContainer container)? ready;

  /// Called once, right after [router] made the router, with the app's `ProviderContainer`: the
  /// generated `AppRoutes.attach`, which runs each adapter's `attach` (since 0.11.0). An error
  /// is reported and the app still shows.
  final void Function(GoRouter router, ProviderContainer container)? attach;

  /// startup.dart's `attach(router, container)` (since 0.12.0): called in the same post-frame
  /// callback as [attach], after it. An error is reported (and does not stop the rest), and the
  /// app still shows.
  final void Function(GoRouter router, ProviderContainer container)? appAttach;

  /// Called once, after `startup()`, inside the `ProviderScope`; the router is disposed with
  /// the gate.
  final GoRouter Function() router;

  /// app.dart's widget around the router.
  final Widget Function(GoRouter router) app;

  @override
  State<StartupGate> createState() => _StartupGateState();
}

class _StartupGateState extends State<StartupGate> {
  /// Counts the runs, so a retry's answer is the one that counts.
  int _run = 0;
  bool _ready = false;
  bool _deferred = false;
  Object? _error;
  StackTrace? _stackTrace;
  List<Override> _overrides = const [];
  List<ProviderObserver>? _observers;

  /// `startup()` has succeeded, so a retry runs [StartupGate.ready] alone.
  bool _startupDone = false;

  /// The container the gate owns, made after `startup()` when there is a `ready`.
  ProviderContainer? _container;

  @override
  void initState() {
    super.initState();
    _start(first: true);
  }

  /// Runs `startup()`. In `initState` the state is set directly: a sync result is there in the
  /// first frame.
  void _start({required bool first}) {
    final run = ++_run;
    final FutureOr<Object?> result;
    try {
      final overrides = widget.overrides;
      final startup = widget.startup;
      result = overrides != null ? overrides() : startup?.call();
    } catch (error, stackTrace) {
      _failed(error, stackTrace, direct: first);
      return;
    }
    if (result is! Future<Object?>) {
      _succeeded(result, direct: first, first: first);
      return;
    }
    _deferFirstFrame(first);
    result.then<void>(
      (value) {
        if (mounted && run == _run) {
          _succeeded(value, direct: false, first: first);
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        if (mounted && run == _run) _failed(error, stackTrace, direct: false);
      },
    );
  }

  /// Without a splash, the native one stays until the app is ready.
  void _deferFirstFrame(bool first) {
    final binding = WidgetsBinding.instance;
    if (first &&
        !_deferred &&
        widget.splash == null &&
        !binding.firstFrameRasterized) {
      binding.deferFirstFrame();
      _deferred = true;
    }
  }

  void _succeeded(Object? value, {required bool direct, required bool first}) {
    final List<Override> overrides;
    final List<ProviderObserver>? observers;
    try {
      final own = value is List<Override> ? value : const <Override>[];
      final extra = widget.extraOverrides?.call() ?? const <Override>[];
      overrides = extra.isEmpty ? own : [...extra, ...own];
      observers = widget.observers?.call();
    } catch (error, stackTrace) {
      _failed(error, stackTrace, direct: direct);
      return;
    }
    _overrides = overrides;
    _observers = observers;
    _startupDone = true;
    if (widget.ready == null) {
      _show(direct);
    } else {
      _runReady(direct: direct, first: first);
    }
  }

  /// Makes the container (as a `ProviderScope` would: same parent, overrides, observers and
  /// retry, and errors reported through `FlutterError`) and runs `ready` on it.
  void _runReady({required bool direct, required bool first}) {
    final run = _run;
    final FutureOr<void> result;
    final ProviderContainer container;
    try {
      container = _newContainer();
    } catch (error, stackTrace) {
      _failed(
        error,
        stackTrace,
        direct: direct,
        inReady: true,
        what: 'making the container',
      );
      return;
    }
    _container = container;
    try {
      result = widget.ready!(container);
    } catch (error, stackTrace) {
      _failed(error, stackTrace, direct: direct, inReady: true);
      return;
    }
    if (result is! Future<void>) {
      _show(direct);
      return;
    }
    _deferFirstFrame(first);
    result.then<void>(
      (_) {
        if (mounted && run == _run) _show(false);
      },
      onError: (Object error, StackTrace stackTrace) {
        if (mounted && run == _run) {
          _failed(error, stackTrace, direct: false, inReady: true);
        }
      },
    );
  }

  ProviderContainer _newContainer() {
    ProviderContainer? parent;
    try {
      parent = ProviderScope.containerOf(context, listen: false);
    } on StateError {
      // No ProviderScope above the gate.
    }
    return ProviderContainer(
      parent: parent,
      overrides: _overrides,
      observers: _observers,
      retry: widget.retry,
      // ignore: invalid_use_of_internal_member
      onError: (error, stackTrace) => FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'riverpod',
        ),
      ),
    );
  }

  void _disposeContainer() {
    final container = _container;
    _container = null;
    container?.dispose();
  }

  void _show(bool direct) {
    _set(direct, () {
      _error = null;
      _stackTrace = null;
      _ready = true;
    });
    _allowFirstFrame();
  }

  void _failed(
    Object error,
    StackTrace stackTrace, {
    required bool direct,
    bool inReady = false,
    String? what,
  }) {
    if (!inReady) _startupDone = false;
    _disposeContainer();
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stackTrace,
        library: 'fespalier',
        context: ErrorDescription(
          what != null
              ? 'while $what for ready() in startup.dart'
              : inReady
              ? 'while running ready() in startup.dart'
              : 'while running startup() in startup.dart',
        ),
      ),
    );
    _set(direct, () {
      _error = error;
      _stackTrace = stackTrace;
      _ready = false;
    });
    _allowFirstFrame();
  }

  void _set(bool direct, VoidCallback change) {
    if (direct) {
      change();
    } else {
      setState(change);
    }
  }

  void _retry() {
    setState(() {
      _error = null;
      _stackTrace = null;
    });
    if (_startupDone) {
      // startup() succeeded: only ready() failed, on a container that is gone now.
      ++_run;
      _runReady(direct: false, first: false);
    } else {
      _start(first: false);
    }
  }

  void _allowFirstFrame() {
    if (!_deferred) return;
    _deferred = false;
    WidgetsBinding.instance.allowFirstFrame();
  }

  @override
  void dispose() {
    _allowFirstFrame();
    _disposeContainer();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_ready) {
      final host = _RouterHost(
        router: widget.router,
        attach: widget.attach,
        appAttach: widget.appAttach,
        app: widget.app,
      );
      final container = _container;
      if (container != null) {
        return UncontrolledProviderScope(container: container, child: host);
      }
      return ProviderScope(
        overrides: _overrides,
        observers: _observers,
        retry: widget.retry,
        child: host,
      );
    }
    final error = _error;
    final splash = widget.splash;
    if (splash != null) {
      return _StartupFrame(
        child: splash(
          error,
          error == null ? null : _stackTrace,
          error == null ? null : _retry,
        ),
      );
    }
    if (error == null) return const SizedBox.shrink();
    return _StartupFrame(
      child: _StartupFailed(error: error, onRetry: _retry),
    );
  }
}

/// Makes the router once, after `startup()`, and disposes it with the app.
class _RouterHost extends StatefulWidget {
  const _RouterHost({
    required this.router,
    this.attach,
    this.appAttach,
    required this.app,
  });

  final GoRouter Function() router;
  final void Function(GoRouter router, ProviderContainer container)? attach;
  final void Function(GoRouter router, ProviderContainer container)? appAttach;
  final Widget Function(GoRouter router) app;

  @override
  State<_RouterHost> createState() => _RouterHostState();
}

class _RouterHostState extends State<_RouterHost> {
  late final GoRouter _router;

  @override
  void initState() {
    super.initState();
    _router = widget.router();
    _attach();
  }

  /// Hands the router and the scope's container to the adapters, after the frame that shows the
  /// router (Riverpod forbids changing a provider while the tree builds, and an adapter may).
  /// In `initState` the scope is found without listening to it; the callback is queued in the
  /// frame being built, so no extra frame is scheduled.
  void _attach() {
    final attach = widget.attach;
    final appAttach = widget.appAttach;
    if (attach == null && appAttach == null) return;
    final container = ProviderScope.containerOf(context, listen: false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // The adapters' first, then the app's; one that throws does not stop the other.
      if (attach != null) {
        _runAttach(
          attach,
          container,
          'while attaching the adapters to the router',
        );
      }
      if (appAttach != null) {
        _runAttach(
          appAttach,
          container,
          'while running attach() in startup.dart',
        );
      }
    });
  }

  void _runAttach(
    void Function(GoRouter router, ProviderContainer container) attach,
    ProviderContainer container,
    String what,
  ) {
    try {
      attach(_router, container);
    } catch (error, stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'fespalier',
          context: ErrorDescription(what),
        ),
      );
    }
  }

  @override
  void dispose() {
    try {
      _router.dispose();
    } on FlutterError {
      // Disposed by the app itself.
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.app(_router);
}

/// The languages written right to left: what the frame before the app guesses its text
/// direction from (there is no `Localizations` yet).
const _rightToLeft = {
  'ar',
  'fa',
  'he',
  'ps',
  'ur',
  'yi',
  'ckb',
  'dv',
  'sd',
  'ug',
};

TextDirection _platformDirection() =>
    _rightToLeft.contains(PlatformDispatcher.instance.locale.languageCode)
    ? TextDirection.rtl
    : TextDirection.ltr;

/// What splash.dart is built in: the app does not exist yet, so there is no `Theme`,
/// `Localizations` or `ProviderScope` above it, only a text direction.
class _StartupFrame extends StatelessWidget {
  const _StartupFrame({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) =>
      Directionality(textDirection: _platformDirection(), child: child);
}

/// The failure screen when there is no splash.dart: a message and a way to try again.
class _StartupFailed extends StatelessWidget {
  const _StartupFailed({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final dark = MediaQuery.platformBrightnessOf(context) == Brightness.dark;
    final ink = dark ? const Color(0xFFFFFFFF) : const Color(0xFF000000);
    final style = TextStyle(
      color: ink,
      fontSize: 16,
      decoration: TextDecoration.none,
    );
    return ColoredBox(
      color: dark ? const Color(0xFF000000) : const Color(0xFFFFFFFF),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text("Couldn't start the app.", style: style),
              if (kDebugMode) ...[
                const SizedBox(height: 8),
                Text('$error', style: style.copyWith(fontSize: 12)),
              ],
              const SizedBox(height: 16),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onRetry,
                child: Text(
                  'Try again',
                  style: style.copyWith(decoration: TextDecoration.underline),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
