import 'package:fespalier/fespalier.dart';
import 'package:flutter/foundation.dart' show kDebugMode, visibleForTesting;
import 'package:flutter/widgets.dart';

import 'in_context/editor.dart' show kTolgeeInContext;
import 'in_context/panel.dart';
import 'locale.dart';
import 'providers.dart';
import 'translator.dart';

class _ScopeData extends InheritedWidget {
  const _ScopeData({
    required this.translator,
    required this.recorder,
    required super.child,
  });

  final Translator translator;
  final KeyRecorder? recorder;

  @override
  bool updateShouldNotify(_ScopeData old) =>
      !identical(translator, old.translator) || recorder != old.recorder;
}

_ScopeData _dataOf(BuildContext context) {
  final data = context.dependOnInheritedWidgetOfExactType<_ScopeData>();
  if (data == null) {
    throw FlutterError.fromParts([
      ErrorSummary('No TranslationScope found above this widget.'),
      ErrorDescription(
        '`context.tr`, `TrText` and `TranslationScope.of` read the translator of the nearest '
        'TranslationScope, and ${context.widget.runtimeType} has none above it.',
      ),
      ErrorHint(
        'Give `MaterialApp.router` `routerConfig: TranslationScope.routerConfig(router, ...)`, or wrap the '
        'subtree in `TranslationScope(locale: ..., child: ...)`.',
      ),
    ]);
  }
  return data;
}

/// Provides the `Translator` for [locale] below it, and `Localizations.override(locale:)` so
/// Material strings and text direction (RTL) follow it (since 0.10.0).
///
/// The app needs `localizationsDelegates: GlobalMaterialLocalizations.delegates` (and
/// `supportedLocales`) on its `MaterialApp`: without them a locale such as `fr` has no
/// `MaterialLocalizations` and an `AppBar` throws.
class TranslationScope extends ConsumerStatefulWidget {
  /// A fixed locale (tests, a subtree in another language).
  const TranslationScope({super.key, required this.locale, required this.child})
    : _epoch = null;

  const TranslationScope._({
    required this.locale,
    required this.child,
    required Object? epoch,
  }) : _epoch = epoch;

  /// The config to give `MaterialApp.router(routerConfig: ...)` in place of [router] itself:
  /// go_router's own, with the root Navigator wrapped in a scope whose locale is
  /// `localeOf(uri)` resolved against `translationsConfig`, else the previous one, else
  /// `preferredLocale` (since 0.10.0).
  ///
  /// The scope is built inside the Router's own build, so the first frame has the route's
  /// locale (a redirect included), a location change updates it in the same frame, and root
  /// navigator pages (dialogs, `present.dart`) are under it. This package adds no listener: the
  /// Router's own is forwarded to go_router's delegate. One config is made per [router].
  static RouterConfig<RouteMatchList> routerConfig(
    GoRouter router, {
    required LocaleOfUri localeOf,
  }) => _configs[router] ??= RouterConfig<RouteMatchList>(
    routeInformationProvider: router.routeInformationProvider,
    routeInformationParser: router.routeInformationParser,
    backButtonDispatcher: router.backButtonDispatcher,
    routerDelegate: _TranslatedDelegate(router.routerDelegate, localeOf),
  );

  static final _configs = Expando<RouterConfig<RouteMatchList>>(
    'fespalier_tolgee',
  );

  /// For this package's tests: builds the in-context handle and panel in a debug build without
  /// `--dart-define=fespalier_tolgee.in_context=true`. Read only under `kDebugMode`, so a release
  /// build never builds the panel whatever this holds.
  @visibleForTesting
  static bool debugInContext = false;

  /// The locale shown.
  final String locale;

  /// The subtree.
  final Widget child;

  final Object? _epoch;

  /// The nearest Translator; throws a FlutterError naming TranslationScope when there is none.
  static Translator of(BuildContext context) => _dataOf(context).translator;

  /// The nearest scope's locale tag (the resolved one: `fr` for `fr-CA` when only `fr` is bundled).
  static String localeOf(BuildContext context) => of(context).locale;

  @override
  ConsumerState<TranslationScope> createState() => _TranslationScopeState();
}

class _TranslationScopeState extends ConsumerState<TranslationScope> {
  KeyRecorder? _recorder;

  @override
  void didUpdateWidget(TranslationScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget._epoch != oldWidget._epoch ||
        widget.locale != oldWidget.locale) {
      _recorder?.keys.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    final translator = ref.watch(translatorProvider(widget.locale));
    // Both operands are consts in release, so the panel and the editor fold away.
    final inContext =
        kTolgeeInContext || (kDebugMode && TranslationScope.debugInContext);
    final recorder = inContext ? (_recorder ??= KeyRecorder()) : null;
    Widget child = widget.child;
    if (recorder != null) {
      child = InContextHost(
        locale: translator.locale,
        translator: translator,
        recorder: recorder,
        child: child,
      );
    }
    if (translator.locale.isNotEmpty) {
      final locale = localeFromTag(translator.locale);
      child = Localizations.maybeLocaleOf(context) == null
          ? Localizations(
              locale: locale,
              delegates: const [DefaultWidgetsLocalizations.delegate],
              child: child,
            )
          : Localizations.override(
              context: context,
              locale: locale,
              child: child,
            );
    }
    return _ScopeData(translator: translator, recorder: recorder, child: child);
  }
}

/// go_router's delegate with the scope built inside its `build`.
final class _TranslatedDelegate extends RouterDelegate<RouteMatchList> {
  _TranslatedDelegate(this.inner, this.localeOf);

  final GoRouterDelegate inner;
  final LocaleOfUri localeOf;

  // The Router's own listener, forwarded: this package adds none.
  @override
  void addListener(VoidCallback listener) {
    // A tear-off: the Router's listener goes to go_router's delegate, this package adds none.
    final add = inner.addListener;
    add(listener);
  }

  @override
  void removeListener(VoidCallback listener) => inner.removeListener(listener);

  @override
  RouteMatchList get currentConfiguration => inner.currentConfiguration;

  @override
  Future<bool> popRoute() => inner.popRoute();

  @override
  Future<void> setNewRoutePath(RouteMatchList configuration) =>
      inner.setNewRoutePath(configuration);

  @override
  Future<void> setInitialRoutePath(RouteMatchList configuration) =>
      inner.setInitialRoutePath(configuration);

  @override
  Future<void> setRestoredRoutePath(RouteMatchList configuration) =>
      inner.setRestoredRoutePath(configuration);

  @override
  Widget build(BuildContext context) => _RouteLocale(
    uri: inner.currentConfiguration.uri,
    localeOf: localeOf,
    child: inner.build(context),
  );
}

/// Resolves the locale of [uri], remembering the last one that resolved.
class _RouteLocale extends ConsumerStatefulWidget {
  const _RouteLocale({
    required this.uri,
    required this.localeOf,
    required this.child,
  });

  final Uri uri;
  final LocaleOfUri localeOf;
  final Widget child;

  @override
  ConsumerState<_RouteLocale> createState() => _RouteLocaleState();
}

class _RouteLocaleState extends ConsumerState<_RouteLocale> {
  String? _last;

  @override
  Widget build(BuildContext context) {
    final config = ref.watch(translationsConfig);
    final preferred = ref.watch(preferredLocale);
    final resolved = config.resolve(widget.localeOf(widget.uri));
    if (resolved != null) _last = resolved;
    return TranslationScope._(
      locale: resolved ?? _last ?? preferred,
      epoch: widget.uri.toString(),
      child: widget.child,
    );
  }
}

/// Shortcuts on BuildContext (since 0.10.0).
extension TranslateContext on BuildContext {
  /// `TranslationScope.of(this).tr(key, args)`. Also records the key for the in-context panel, in
  /// debug only.
  String tr(String key, [Map<String, Object?> args = const {}]) {
    final data = _dataOf(this);
    data.recorder?.record(key);
    return data.translator.tr(key, args);
  }

  /// `TranslationScope.localeOf(this)`: the route's locale.
  String get routeLocale => TranslationScope.localeOf(this);
}

/// A `Text` whose data is `tr(translationKey, args)` (since 0.10.0).
class TrText extends StatelessWidget {
  /// The text of [translationKey] with [args]; the other parameters are `Text`'s.
  const TrText(
    this.translationKey, {
    super.key,
    this.args = const {},
    this.style,
    this.textAlign,
    this.maxLines,
    this.overflow,
    this.semanticsLabel,
  });

  /// The key to translate.
  final String translationKey;

  /// The ICU message's arguments.
  final Map<String, Object?> args;

  /// See [Text.style].
  final TextStyle? style;

  /// See [Text.textAlign].
  final TextAlign? textAlign;

  /// See [Text.maxLines].
  final int? maxLines;

  /// See [Text.overflow].
  final TextOverflow? overflow;

  /// See [Text.semanticsLabel].
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) => Text(
    context.tr(translationKey, args),
    style: style,
    textAlign: textAlign,
    maxLines: maxLines,
    overflow: overflow,
    semanticsLabel: semanticsLabel,
  );
}
