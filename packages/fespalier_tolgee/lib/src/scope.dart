import 'package:fespalier/fespalier.dart';
import 'package:flutter/scheduler.dart' show SchedulerBinding, SchedulerPhase;
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
        'Put `TranslationScope.router(...)` in `MaterialApp.router`\'s `builder:`, or wrap the '
        'subtree in `TranslationScope(locale: ..., child: ...)`.',
      ),
    ]);
  }
  return data;
}

/// Provides the `Translator` for [locale] below it, and `Localizations.override(locale:)` so
/// Material strings and text direction (RTL) follow it (since 0.10.0).
class TranslationScope extends ConsumerStatefulWidget {
  /// A fixed locale (tests, a subtree in another language).
  ///
  /// [inContext] is for this package's tests: it defaults to `kTolgeeInContext`, which is false
  /// in a release build and unless the app asked for it.
  const TranslationScope({
    super.key,
    required this.locale,
    required this.child,
    @visibleForTesting this.inContext = kTolgeeInContext,
  }) : _epoch = null;

  const TranslationScope._({
    required this.locale,
    required this.child,
    required this.inContext,
    required Object? epoch,
  }) : _epoch = epoch;

  /// Follows [router]: on each location change the locale is `localeOf(uri)` resolved against
  /// `translationsConfig`, else the previous one, else `preferredLocale`. Put it in
  /// `MaterialApp.router`'s `builder`, so root-navigator pages (dialogs, `present.dart`) are under
  /// it too. It listens to the router delegate and stops with the widget.
  static Widget router({
    Key? key,
    required GoRouter router,
    required LocaleOfUri localeOf,
    required Widget child,
    @visibleForTesting bool inContext = kTolgeeInContext,
  }) => _RouterScope(
    key: key,
    router: router,
    localeOf: localeOf,
    inContext: inContext,
    child: child,
  );

  /// The locale shown.
  final String locale;

  /// The subtree.
  final Widget child;

  /// Whether the in-context handle and panel are built (debug builds with the define only).
  final bool inContext;

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
    final recorder = widget.inContext ? (_recorder ??= KeyRecorder()) : null;
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

class _RouterScope extends ConsumerStatefulWidget {
  const _RouterScope({
    super.key,
    required this.router,
    required this.localeOf,
    required this.inContext,
    required this.child,
  });

  final GoRouter router;
  final LocaleOfUri localeOf;
  final bool inContext;
  final Widget child;

  @override
  ConsumerState<_RouterScope> createState() => _RouterScopeState();
}

class _RouterScopeState extends ConsumerState<_RouterScope> {
  String? _last;

  @override
  void initState() {
    super.initState();
    widget.router.routerDelegate.addListener(_locationChanged);
  }

  @override
  void didUpdateWidget(_RouterScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.router != widget.router) {
      oldWidget.router.routerDelegate.removeListener(_locationChanged);
      widget.router.routerDelegate.addListener(_locationChanged);
    }
  }

  @override
  void dispose() {
    widget.router.routerDelegate.removeListener(_locationChanged);
    super.dispose();
  }

  /// go_router can notify while the Router itself is being built (parsing a location), when a
  /// `setState` is not allowed: that one case is handled right after the build.
  void _locationChanged() {
    if (!mounted) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      Future<void>.microtask(() {
        if (mounted) setState(() {});
      });
    } else {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final config = ref.watch(translationsConfig);
    final preferred = ref.watch(preferredLocale);
    final uri = widget.router.routerDelegate.currentConfiguration.uri;
    final resolved = config.resolve(widget.localeOf(uri));
    if (resolved != null) _last = resolved;
    return TranslationScope._(
      locale: resolved ?? _last ?? preferred,
      inContext: widget.inContext,
      epoch: uri.toString(),
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
