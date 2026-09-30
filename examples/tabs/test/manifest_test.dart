import 'dart:io';

import 'package:fespalier/fespalier.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs/app.g.dart';
import 'package:tabs/app.routes.g.dart';
import 'package:tabs/review.dart';

// The manifest is its own library here (`output_manifest:` in pubspec.yaml), so
// it is `AppManifest`, not `AppRoutes.byType`, and only tests import it.
void main() {
  test('lists the routes with the tabs they sit in', () {
    expect(AppManifest.all, hasLength(8));

    final home = AppManifest.byType[HomeRoute]!;
    expect(home.path, '/');
    expect(home.groups, ['(tabs)', '(home)']);
    expect(home.layouts, ['(tabs)']);
    expect(home.tabs.single.index, 0);
    expect(home.tabs.single.branch, '(home)');

    // Nested tab layouts: Books is a tab of Library, itself a tab of (tabs),
    // and the tab order follows `tabs` in layout.dart, not the folders.
    final books = AppManifest.byPath['/library/books']!;
    expect(books.type, BooksRoute);
    expect(books.layouts, ['(tabs)', '(tabs)/library']);
    expect(
      books.tabs.map((t) => '${t.layout}:${t.index}:${t.branch}'),
      ['(tabs):3:library', '(tabs)/library:0:books'],
    );

    // navigator.dart: /profile/edit is in the Profile tab but on the root navigator;
    // /profile/security stays inside the tab's own.
    expect(AppManifest.byType[EditProfileRoute]!.presentation,
        RoutePresentation.root);
    expect(AppManifest.byType[EditProfileRoute]!.tabs.single.branch, 'profile');
    expect(AppManifest.byType[SecurityRoute]!.presentation,
        RoutePresentation.page);

    // Outside `(tabs)/`: full screen, in no tab.
    final settings = AppManifest.byType[SettingsRoute]!;
    expect(settings.tabs, isEmpty);
    expect(settings.layouts, isEmpty);
    expect(settings.groups, isEmpty);
  });

  test('meta.dart is the app\'s own type, kept out of app.g.dart', () {
    expect(AppManifest.byType[SearchRoute]!.metaAs<Review>()!.code, 'T02');
    expect(AppManifest.byType[SettingsRoute]!.metaAs<Review>()!.code, 'S01');
    expect(AppManifest.byType[HomeRoute]!.meta, isNull);

    // Nothing that production code imports mentions the meta files or the
    // manifest: main.dart and app.g.dart stay clear of them.
    for (final file in ['lib/main.dart', 'lib/app.g.dart']) {
      final source = File(file).readAsStringSync();
      expect(source, isNot(contains('meta.dart')), reason: file);
      expect(source, isNot(contains('app.routes.g.dart')), reason: file);
      expect(source, isNot(contains('review.dart')), reason: file);
    }
  });
}
