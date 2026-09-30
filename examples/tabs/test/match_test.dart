// The manifest is its own library here (lib/app.routes.g.dart), so `match` lives on
// AppManifest; app.g.dart only has what needs no manifest: matchUrl and dataAt.
import 'package:fespalier/fespalier.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs/app.g.dart';
import 'package:tabs/app.routes.g.dart';

void main() {
  test('AppManifest.match names the route, its info and its tabs', () {
    final m = AppManifest.match(Uri.parse('/profile/edit'))!;
    expect(m.info, AppManifest.byType[EditProfileRoute]);
    expect(m.route, isA<EditProfileRoute>());
    expect(m.params, isEmpty);
    expect(m.data, isEmpty);
    expect(m.info.tabs, isNotEmpty);
  });

  test('app.g.dart alone matches without the manifest', () {
    expect(AppRoutes.matchUrl(Uri.parse('/library/books'))!.type, BooksRoute);
    expect(AppRoutes.dataAt(Uri.parse('/library/books')), isEmpty);
    expect(AppRoutes.dataAt(Uri.parse('/nothing/here')), isNull);
    expect(AppManifest.match(Uri.parse('/nothing/here')), isNull);
  });

  test('a route on the root navigator is a match with its presentation', () {
    final m = AppManifest.match(Uri.parse('/profile/edit'))!;
    expect(m.info.presentation, RoutePresentation.root);
  });
}
