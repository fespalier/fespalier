import 'dart:convert';

import 'package:fespalier_tolgee/fespalier_tolgee.dart';
import 'package:fespalier_tolgee/in_context.dart';
import 'package:fespalier_tolgee/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support.dart';

void main() {
  test('kTolgeeInContext is false in a test run, and the editor is null', () {
    expect(kTolgeeInContext, isFalse);
    expect(TolgeeEditor.fromEnvironment(), isNull);
  });

  testWidgets('the scope adds no handle and records no keys', (tester) async {
    await tester.pumpWidget(
      host(
        overrides: fakeTranslations(
          bundled: const {
            'en': {'a': 'A'},
          },
        ),
        home: TranslationScope(locale: 'en', child: TrText('a')),
      ),
    );
    expect(find.byKey(const ValueKey('fespalier_tolgee.handle')), findsNothing);
    expect(find.text('A'), findsOneWidget);
  });

  test('TolgeeEditor.withKey: method, path, X-API-Key, body', () async {
    late http.Request seen;
    final editor = TolgeeEditor.withKey(
      Uri.parse('https://tolgee.example/base'),
      'tgpak_test',
      client: MockClient((request) async {
        seen = request;
        return http.Response('{}', 200);
      }),
    );
    await editor.save('product.title', 'fr', 'Titre');
    expect(seen.method, 'PUT');
    expect(
      seen.url.toString(),
      'https://tolgee.example/base/v2/projects/translations',
    );
    expect(seen.headers['X-API-Key'], 'tgpak_test');
    expect(jsonDecode(seen.body), {
      'key': 'product.title',
      'translations': {'fr': 'Titre'},
    });
  });

  test('a failed save throws', () async {
    final editor = TolgeeEditor.withKey(
      Uri.parse('https://tolgee.example'),
      'k',
      client: MockClient((_) async => http.Response('no', 403)),
    );
    await expectLater(
      editor.save('a', 'en', 'x'),
      throwsA(isA<http.ClientException>()),
    );
  });

  testWidgets(
    'an enabled scope lists the keys and a save shows the edited text at once',
    (tester) async {
      final editor = RecordingEditor();
      TranslationScope.debugInContext = true;
      addTearDown(() => TranslationScope.debugInContext = false);
      await tester.pumpWidget(
        host(
          overrides: [
            ...fakeTranslations(
              bundled: const {
                'en': {'a': 'A'},
              },
            ),
            translationEditor.overrideWithValue(editor),
          ],
          home: TranslationScope(
            locale: 'en',
            child: Builder(builder: (context) => Text(context.tr('a'))),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('fespalier_tolgee.handle')));
      await tester.pump();
      expect(find.textContaining('a (bundled)'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('fespalier_tolgee.field.a')),
        'Edited',
      );
      await tester.tap(find.byKey(const ValueKey('fespalier_tolgee.save.a')));
      await tester.pump();
      await tester.pump();
      expect(editor.saved.single, (key: 'a', locale: 'en', text: 'Edited'));
      expect(find.text('Edited'), findsWidgets);
    },
  );
}
