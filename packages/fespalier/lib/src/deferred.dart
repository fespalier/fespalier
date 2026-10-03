import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'telemetry.dart' show telemetryDeferredEnd, telemetryDeferredStart;

/// The code of one deferred route: its `page.dart`, which the generated file imports
/// `deferred as` (`const deferred = true;` in a `route.dart`, or `deferred: true` in
/// pubspec.yaml). Loaded once, the first time the page is built or ahead of time
/// (`preload`, `RouteLink`, `AppRoutes.loadDeferred`), and loaded for good (since 0.7.0).
///
/// On the web (dart2js) each deferred page is a file of its own that the browser fetches
/// on demand; elsewhere the code is already in the binary and loading it takes one turn of
/// the event loop.
final class DeferredLibrary {
  /// The library behind a deferred import: pass its `loadLibrary` (`_i7.loadLibrary`) and
  /// the [file] it stands for. The generated code builds these.
  DeferredLibrary(
    Future<void> Function() loadLibrary,
    this.file, {
    this.loadsInFakeAsync = false,
    this.route,
  }) : _loadLibrary = loadLibrary;

  final Future<void> Function() _loadLibrary;

  /// The `page.dart`, relative to the app folder: `products/$id/page.dart`.
  final String file;

  /// Whether the load can complete while a widget test pumps. False (the default) for a
  /// deferred import's `loadLibrary`, which only completes on the real event loop. True
  /// for a load a test controls itself (a `Completer`'s future). In a debug build,
  /// starting a load that can't complete under the widget-test binding throws.
  final bool loadsInFakeAsync;

  /// The page's pattern (`/products/:id`), which the generator passes only in an app made with
  /// `telemetry: true` (since 0.8.0): it is what makes a load a telemetry span.
  final String? route;

  static final Set<DeferredLibrary> _registered = {};

  bool _loaded = false;
  Future<void>? _loading;

  /// Whether the code is loaded: once true, a deferred page builds synchronously.
  bool get isLoaded => _loaded;

  /// Loads the code, once. Calls made while it loads share one future. A failed load is
  /// forgotten, so the next call tries again. Completes at once (no `loadLibrary` call, no
  /// timer) when the code is already loaded.
  Future<void> load() {
    if (_loaded) return Future<void>.value();
    final pending = _loading;
    if (pending != null) return pending;
    // A call that joins a load in flight starts no span of its own.
    final page = route;
    final Object? span = page == null
        ? null
        : telemetryDeferredStart(file, page);
    return _loading = Future<void>.sync(_loadLibrary).then(
      (_) {
        _loaded = true;
        _loading = null;
        if (page != null) telemetryDeferredEnd(span);
      },
      onError: (Object error, StackTrace stackTrace) {
        _loading = null;
        if (page != null) {
          telemetryDeferredEnd(
            span,
            failed: true,
            error: error,
            stackTrace: stackTrace,
          );
        }
        Error.throwWithStackTrace(error, stackTrace);
      },
    );
  }

  /// [load], for a caller that doesn't wait: an error is ignored (a page that is reached
  /// later tries again, and shows `error.dart`). Does nothing once loaded.
  void preload() {
    if (_loaded) return;
    assert(_debugCheckCanLoad());
    load().ignore();
  }

  /// In debug builds: a load that only the real event loop can complete must not start
  /// under a widget test's fake async, where it would never finish and leave a timer
  /// behind.
  bool _debugCheckCanLoad() {
    if (loadsInFakeAsync || _loaded) return true;
    if (BindingBase.debugBindingType().toString() !=
        'AutomatedTestWidgetsFlutterBinding') {
      return true;
    }
    throw FlutterError.fromParts([
      ErrorSummary(
        "The code of $file is not loaded, and a widget test can't load it "
        'while it pumps.',
      ),
      ErrorDescription(
        '`$file` is a deferred route (`const deferred = true`): its '
        "`loadLibrary()` completes only on the real event loop, which "
        "`tester.pump()` doesn't run, so the page would show its loading view "
        'and leave a timer pending.',
      ),
      ErrorHint(
        'Boot the router with `pumpRouter`, which loads the code of every '
        'deferred route first, or call '
        '`await tester.runAsync(AppRoutes.loadDeferred)` before pumping a '
        'router of your own.',
      ),
    ]);
  }

  /// Remembers [libraries], so [loadAll] without arguments (what `pumpRouter` calls)
  /// loads them. The generated `AppRoutes.mount()` registers its own.
  static void register(Iterable<DeferredLibrary> libraries) =>
      _registered.addAll(libraries);

  /// Loads [libraries], or every registered one. Completes when all of them are loaded.
  static Future<void> loadAll([Iterable<DeferredLibrary>? libraries]) =>
      Future.wait([
        for (final l in libraries ?? _registered.toList()) l.load(),
      ]);

  /// Whether a registered library is not loaded yet.
  static bool get anyPending => _registered.any((l) => !l._loaded);

  @override
  String toString() => 'DeferredLibrary($file)';
}

/// What the generated code builds a deferred route's page with: [page] once [library] is
/// loaded, synchronously when it already is; [loading] until then; [error] (with a retry
/// that loads again) when loading failed. Always in the tree for a deferred page, so the
/// page's `State` survives the load.
class DeferredView extends StatefulWidget {
  /// Shows [page] when [library] is loaded, loading it first if it isn't.
  const DeferredView({
    super.key,
    required this.library,
    required this.page,
    required this.loading,
    required this.error,
  });

  /// The code the page lives in.
  final DeferredLibrary library;

  /// Builds the page; only called once [library] is loaded.
  final Widget Function() page;

  /// Builds the view while the code loads.
  final Widget Function() loading;

  /// Builds the view when loading failed; `retry` loads the code again (and does nothing
  /// once the view is gone).
  final Widget Function(Object error, StackTrace stackTrace, VoidCallback retry)
  error;

  @override
  State<DeferredView> createState() => _DeferredViewState();
}

class _DeferredViewState extends State<DeferredView> {
  Future<void>? _pending;
  Object? _error;
  StackTrace? _stackTrace;

  @override
  void initState() {
    super.initState();
    if (!widget.library.isLoaded) _start();
  }

  @override
  void didUpdateWidget(DeferredView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.library != widget.library) {
      _pending = null;
      _error = null;
      _stackTrace = null;
      if (!widget.library.isLoaded) _start();
    }
  }

  void _start() {
    assert(widget.library._debugCheckCanLoad());
    _error = null;
    _stackTrace = null;
    final future = _pending = widget.library.load();
    unawaited(
      future.then<void>(
        (_) {
          if (mounted && identical(_pending, future)) setState(() {});
        },
        onError: (Object error, StackTrace stackTrace) {
          if (mounted && identical(_pending, future)) {
            setState(() {
              _error = error;
              _stackTrace = stackTrace;
            });
          }
        },
      ),
    );
  }

  void _retry() {
    if (!mounted) return;
    setState(_start);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.library.isLoaded) return widget.page();
    final error = _error;
    if (error != null) return widget.error(error, _stackTrace!, _retry);
    return widget.loading();
  }
}
