import 'dart:async';
import 'dart:convert';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart' show Override;
import 'package:fespalier_tolgee/fespalier_tolgee.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

/// An AssetBundle over a map of files: no files on disk.
class MapBundle extends CachingAssetBundle {
  MapBundle(this.files);

  final Map<String, String> files;

  /// The paths that were read.
  final reads = <String>[];

  @override
  Future<ByteData> load(String key) async {
    reads.add(key);
    final text = files[key];
    if (text == null) throw FlutterError('Unable to load asset: "$key"');
    final bytes = Uint8List.fromList(utf8.encode(text));
    return ByteData.sublistView(bytes);
  }
}

/// A source the test completes by hand.
class GatedSource implements TranslationSource {
  final calls = <String>[];
  final etags = <String?>[];
  final _gates = <String, Completer<RemoteCatalog?>>{};

  Completer<RemoteCatalog?> _gate(String locale) =>
      _gates.putIfAbsent(locale, Completer.new);

  void complete(String locale, Map<String, String> messages, {String? etag}) {
    _gate(
      locale,
    ).complete(RemoteCatalog(Catalog(locale, messages), etag: etag));
  }

  void fail(String locale) =>
      _gate(locale).completeError(StateError('offline'));

  /// Makes the next fetch of [locale] wait again.
  void rearm(String locale) => _gates.remove(locale);

  @override
  Future<RemoteCatalog?> fetch(String locale, {String? etag}) {
    calls.add(locale);
    etags.add(etag);
    return _gate(locale).future;
  }
}

/// Shows `ref.watch(translator(locale)).tr(key)`.
class Probe extends ConsumerWidget {
  const Probe(this.locale, this.keyName, {super.key, this.args = const {}});

  final String locale;
  final String keyName;
  final Map<String, Object?> args;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Text(
    ref.watch(translator(locale)).tr(keyName, args),
    textDirection: TextDirection.ltr,
  );
}

/// A MaterialApp with the Material delegates under a ProviderScope.
Widget host({
  required Widget home,
  List<Override> overrides = const [],
  ProviderContainer? container,
  List<Locale> supported = const [Locale('en')],
}) {
  final app = MaterialApp(
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    supportedLocales: supported,
    home: home,
  );
  return container != null
      ? UncontrolledProviderScope(container: container, child: app)
      : ProviderScope(overrides: overrides, child: app);
}

Translations config({
  Map<String, Map<String, String>> bundled = const {
    'en': {'hello': 'Hello'},
  },
  String base = 'en',
  TranslationSource? remote,
  bool refreshOnResume = false,
  bool refreshOnReconnect = true,
  Duration cacheMaxAge = const Duration(days: 30),
}) => Translations(
  bundled: BundledTranslations.fromMaps(bundled),
  baseLocale: base,
  remote: remote,
  refreshOnResume: refreshOnResume,
  refreshOnReconnect: refreshOnReconnect,
  cacheMaxAge: cacheMaxAge,
);
