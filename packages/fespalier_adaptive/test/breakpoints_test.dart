import 'package:fespalier_adaptive/fespalier_adaptive.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('WindowSizeClass.of', () {
    test('follows Material 3 at each edge', () {
      final expected = {
        0.0: WindowSizeClass.compact,
        599.0: WindowSizeClass.compact,
        599.9: WindowSizeClass.compact,
        600.0: WindowSizeClass.medium,
        839.0: WindowSizeClass.medium,
        840.0: WindowSizeClass.expanded,
        1199.0: WindowSizeClass.expanded,
        1200.0: WindowSizeClass.large,
        1599.0: WindowSizeClass.large,
        1600.0: WindowSizeClass.extraLarge,
        3000.0: WindowSizeClass.extraLarge,
      };
      for (final MapEntry(:key, :value) in expected.entries) {
        expect(WindowSizeClass.of(key), value, reason: 'width $key');
      }
    });
  });

  group('NavBreakpoints.modeFor', () {
    NavMode at(NavBreakpoints b, double width) => b.modeFor(width);

    test('the defaults are a bar, a rail from 600 and a drawer from 1200', () {
      const b = NavBreakpoints();
      expect(b.rail, 600);
      expect(b.drawer, 1200);
      expect(at(b, 0), NavMode.bar);
      expect(at(b, 599), NavMode.bar);
      expect(at(b, 600), NavMode.rail);
      expect(at(b, 1199), NavMode.rail);
      expect(at(b, 1200), NavMode.drawer);
      expect(at(b, 2400), NavMode.drawer);
      expect(
        identical(NavBreakpoints.material, const NavBreakpoints()),
        isTrue,
      );
    });

    test('noDrawer is a bar, then a rail from 600', () {
      const b = NavBreakpoints.noDrawer;
      expect(b.drawer, isNull);
      expect(at(b, 599), NavMode.bar);
      expect(at(b, 600), NavMode.rail);
      expect(at(b, 5000), NavMode.rail);
    });

    test('a null rail never has one: the bar gives way to the drawer', () {
      const b = NavBreakpoints(rail: null);
      expect(at(b, 599), NavMode.bar);
      expect(at(b, 800), NavMode.bar);
      expect(at(b, 1199), NavMode.bar);
      expect(at(b, 1200), NavMode.drawer);
    });

    test('both null is always a bar', () {
      const b = NavBreakpoints(rail: null, drawer: null);
      for (final width in [0.0, 600.0, 1200.0, 4000.0]) {
        expect(at(b, width), NavMode.bar, reason: 'width $width');
      }
    });

    test('a rail breakpoint of your own moves where the rail starts', () {
      const b = NavBreakpoints(rail: 840);
      expect(at(b, 800), NavMode.bar);
      expect(at(b, 839), NavMode.bar);
      expect(at(b, 840), NavMode.rail);
      expect(at(b, 1200), NavMode.drawer);
    });

    test('the drawer wins where both start at the same width', () {
      const b = NavBreakpoints(rail: 900, drawer: 900);
      expect(at(b, 899), NavMode.bar);
      expect(at(b, 900), NavMode.drawer);
    });
  });

  test('a drawer below the rail is an error in debug', () {
    expect(
      () => NavBreakpoints(rail: 1000, drawer: 800),
      throwsA(
        isA<AssertionError>().having(
          (e) => e.message,
          'message',
          'NavBreakpoints: drawer is below rail',
        ),
      ),
    );
    // A null on either side is no ordering to break.
    expect(() => NavBreakpoints(rail: 1000, drawer: null), returnsNormally);
    expect(() => NavBreakpoints(rail: null, drawer: 100), returnsNormally);
  });
}
