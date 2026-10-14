import 'dart:convert';

import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interop_app/app/extra_codec.dart';
import 'package:interop_app/models/note.dart';
import 'package:interop_app/routes.g.dart';

const note = Note(id: 3, title: 'Draft', tags: ['a', 'b']);

/// How data.dart's value is saved: `fespalier:` and the folder and keys of the route.
const cacheKey = 'fespalier:notes/\$id[3]';

/// Builds its router in `initState`, so that after `restartAndRestore` there is
/// a new one and only the restored state can put it back where it was.
class RestorableApp extends StatefulWidget {
  const RestorableApp(this.storage, {super.key});

  final MemoryDataStorage storage;

  @override
  State<RestorableApp> createState() => _RestorableAppState();
}

class _RestorableAppState extends State<RestorableApp> {
  late final GoRouter router = AppRoutes.router(restorationScopeId: 'router');

  @override
  Widget build(BuildContext context) => ProviderScope(
    overrides: [dataCacheStorage.overrideWithValue(widget.storage)],
    child: MaterialApp.router(restorationScopeId: 'app', routerConfig: router),
  );
}

void main() {
  test(
    'freezed builds a private subclass, which an exact-type codec misses',
    () {
      expect(note.runtimeType.toString(), startsWith('_'));
      expect(note.runtimeType, isNot(Note));
      final exact = ExtraCodec({
        Note: (toJson: (Note n) => n.toJson(), fromJson: Note.fromJson),
      });
      expect(exact.encode(note), isNull);
    },
  );

  test('ExtraCodec.of saves it as JSON text and reads it back', () {
    final saved = jsonDecode(jsonEncode(extraCodec.encode(note)));
    expect(extraCodec.decode(saved), note);
  });

  testWidgets('a freezed extra and a DataCache.json value survive a restart', (
    tester,
  ) async {
    final storage = MemoryDataStorage();
    await tester.pumpWidget(RestorableApp(storage));
    await tester.pumpAndSettle();

    final context = tester.element(find.byType(Navigator).first);
    NoteRoute(id: 3).go(context, extra: note);
    await tester.pumpAndSettle();
    expect(find.text('data: Note 3'), findsOneWidget);
    expect(find.text('extra: Draft'), findsOneWidget);

    // DataCache.json: the freezed value, as JSON, under the route's key.
    final saved = jsonDecode(storage.read(cacheKey)!.data);
    expect(Note.fromJson(saved as Map<String, dynamic>).title, 'Note 3');
    expect(saved['tags'], ['saved']);

    await tester.restartAndRestore();
    await tester.pumpAndSettle();
    expect(find.text('data: Note 3'), findsOneWidget);
    // The extra went through extra_codec.dart: without it, this page gets null.
    expect(find.text('extra: Draft'), findsOneWidget);
  });
}
