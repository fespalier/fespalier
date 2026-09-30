import 'package:features/app.g.dart';
import 'package:features/page_meta.dart';
import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as mui;

void main() {
  group('the route manifest', () {
    test('lists every route once, by type and by path', () {
      expect(AppManifest.all, hasLength(27));
      expect(AppManifest.byType, hasLength(27));
      expect(AppManifest.byPath, hasLength(27));
      // With the manifest inline, AppRoutes forwards to it.
      expect(AppRoutes.all, same(AppManifest.all));
      expect(AppRoutes.byType, same(AppManifest.byType));
      expect(AppRoutes.byPath, same(AppManifest.byPath));
      for (final info in AppManifest.all) {
        expect(AppManifest.byType[info.type], same(info));
        expect(AppManifest.byPath[info.path], same(info));
      }
      expect(AppManifest.byPath['/shops/:shop/items/:id']!.type, ItemRoute);
    });

    test('knows the path, folder, groups and layouts', () {
      final photo = AppManifest.byType[PhotoRoute]!;
      expect(photo.path, '/photos/:id');
      expect(photo.folder, r'photos/$id');
      expect(photo.presentation, RoutePresentation.page);
      expect(photo.groups, isEmpty);

      // A (group) is in `groups` and adds nothing to the path; its layout is
      // in `layouts`, after the root one ('' is the app folder itself).
      final profile = AppManifest.byType[ProfileRoute]!;
      expect(profile.path, '/profile');
      expect(profile.folder, '(account)/profile');
      expect(profile.groups, ['(account)']);
      expect(profile.layouts, ['', '(account)']);

      final item = AppManifest.byType[ItemRoute]!;
      expect(item.layouts, ['', r'shops/$shop']);
    });

    test('knows the segments, query parameters and data keys', () {
      final item = AppManifest.byType[ItemRoute]!;
      expect(item.segments.map((p) => '${p.type} ${p.name}'),
          ['String shop', 'int id']);
      expect(item.query, isEmpty);
      expect(item.dataKeys, ['shop', 'id']);

      final search = AppManifest.byType[SearchRoute]!;
      expect(search.segments, isEmpty);
      expect(search.query.map((p) => '${p.type} ${p.name}'),
          ['String? q', 'int? page', 'List<String> tags']);
      expect(search.dataKeys, ['q', 'page', 'tags']);

      // No data.dart, no data keys (which is not the same as none of them).
      expect(AppManifest.byType[HomeRoute]!.dataKeys, isNull);
      expect(AppManifest.byType[CounterRoute]!.dataKeys, isEmpty);
    });

    test('a catch-all is the last segment: a List<String>, marked', () {
      final docs = AppManifest.byType[DocsRoute]!;
      expect(docs.path, '/docs/*rest');
      expect(docs.segments.single.type, 'List<String>');
      expect(docs.segments.single.catchAll, isTrue);
      expect(AppManifest.byPath['/files/*path?']!.type, FilesRoute);
      expect(AppManifest.byType[PhotoRoute]!.segments.single.catchAll, isFalse);
    });

    test('a redirect.dart route is a redirect', () {
      final old = AppManifest.byType[OldSearchRoute]!;
      expect(old.presentation, RoutePresentation.redirect);
      expect(old.isRedirect, isTrue);
      expect(AppManifest.byType[SearchRoute]!.isRedirect, isFalse);
    });

    test('meta.dart is passed through as the route\'s own meta', () {
      final home = AppManifest.byType[HomeRoute]!;
      expect(home.meta, isA<PageMeta>());
      expect(home.metaAs<PageMeta>()!.code, 'A01');
      expect(home.metaAs<String>(), isNull);
      // Not inherited: /photos/sort sits below photos/, which has a meta.dart.
      expect(AppManifest.byType[PhotosRoute]!.metaAs<PageMeta>()!.code, 'B02');
      expect(AppManifest.byType[SortRoute]!.meta, isNull);
      // A redirect route can have one.
      expect(AppManifest.byType[OldSearchRoute]!.metaAs<PageMeta>()!.code, 'C01');
    });

    test('a review test can join its own registry on the manifest', () {
      // The kind of test the manifest replaces a hand-written table for: every
      // declared code is unique.
      final codes = [
        for (final info in AppManifest.all)
          if (info.metaAs<PageMeta>() case final meta?) meta.code,
      ];
      expect(codes, hasLength(7));
      expect(codes.toSet(), hasLength(codes.length));
    });
  });

  group('the web tab title', () {
    late List<String> labels;

    setUp(() {
      labels = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'SystemChrome.setApplicationSwitcherDescription') {
          labels.add((call.arguments as Map)['label'] as String);
        }
        return null;
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    Future<void> boot(WidgetTester tester, String location) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: mui.MaterialApp.router(
              routerConfig: AppRoutes.router(initialLocation: location),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('comes from the route\'s meta.dart, read in a layout',
        (tester) async {
      await boot(tester, '/photos');
      expect(labels.last, 'Photos');

      // A route without a meta.dart falls back to the layout's default.
      await boot(tester, '/profile');
      expect(labels.last, 'Features');
    });

    testWidgets('is found for catch-all routes, with or without the rest',
        (tester) async {
      await boot(tester, '/docs/guide/setup');
      expect(labels.last, 'Docs');
      // The optional catch-all's route above it is the same route.
      await boot(tester, '/files');
      expect(labels.last, 'Files');
      await boot(tester, '/files/a/b');
      expect(labels.last, 'Files');
    });

    testWidgets('follows the location', (tester) async {
      await boot(tester, '/login');
      expect(labels.last, 'Sign in');
      final router = GoRouter.of(tester.element(find.byType(Scaffold).first));
      router.go('/');
      await tester.pumpAndSettle();
      expect(labels.last, 'Home');
    });
  });
}
