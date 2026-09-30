import 'package:fespalier/fespalier.dart';
import 'package:flutter_test/flutter_test.dart';

// `RouteNavigator` is only read from the source by `fsp gen`; it has to exist
// (and stay a plain enum of these two names) for `navigator.dart` to compile.
class _Home {}

void main() {
  test('RouteNavigator has the two values navigator.dart can name', () {
    expect(RouteNavigator.values.map((v) => v.name), ['root', 'shell']);
  });

  test('RoutePresentation says how a route is served', () {
    expect(RoutePresentation.values.map((v) => v.name), [
      'page',
      'redirect',
      'root',
      'custom',
    ]);
    final home = RouteInfo<Object?>(type: _Home, path: '/', folder: '');
    expect(home.presentation, RoutePresentation.page);
    expect(home.isRedirect, isFalse);
    final sheet = RouteInfo<Object?>(
      type: _Home,
      path: '/buy',
      folder: 'buy',
      presentation: RoutePresentation.custom,
    );
    expect(sheet.isRedirect, isFalse);
  });
}
