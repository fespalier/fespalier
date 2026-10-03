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
    this.splash,
    this.observers,
    this.retry,
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
      _succeeded(result, direct: first);
      return;
    }
    final binding = WidgetsBinding.instance;
    if (first && widget.splash == null && !binding.firstFrameRasterized) {
      // The native splash stays until the app is ready.
      binding.deferFirstFrame();
      _deferred = true;
    }
    result.then<void>(
      (value) {
        if (mounted && run == _run) _succeeded(value, direct: false);
      },
      onError: (Object error, StackTrace stackTrace) {
        if (mounted && run == _run) _failed(error, stackTrace, direct: false);
      },
    );
  }

  void _succeeded(Object? value, {required bool direct}) {
    final List<Override> overrides;
    final List<ProviderObserver>? observers;
    try {
      overrides = value is List<Override> ? value : const [];
      observers = widget.observers?.call();
    } catch (error, stackTrace) {
      _failed(error, stackTrace, direct: direct);
      return;
    }
    _set(direct, () {
      _overrides = overrides;
      _observers = observers;
      _error = null;
      _stackTrace = null;
      _ready = true;
    });
    _allowFirstFrame();
  }

  void _failed(Object error, StackTrace stackTrace, {required bool direct}) {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stackTrace,
        library: 'fespalier',
        context: ErrorDescription('while running startup() in startup.dart'),
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
    _start(first: false);
  }

  void _allowFirstFrame() {
    if (!_deferred) return;
    _deferred = false;
    WidgetsBinding.instance.allowFirstFrame();
  }

  @override
  void dispose() {
    _allowFirstFrame();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_ready) {
      return ProviderScope(
        overrides: _overrides,
        observers: _observers,
        retry: widget.retry,
        child: _RouterHost(router: widget.router, app: widget.app),
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
  const _RouterHost({required this.router, required this.app});

  final GoRouter Function() router;
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
