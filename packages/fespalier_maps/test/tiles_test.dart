// tileCount against values worked out by hand from the Web Mercator tile scheme (2^z by 2^z).
import 'package:fespalier_maps/fespalier_maps.dart';
import 'package:flutter_test/flutter_test.dart';

GeoBounds box(double s, double w, double n, double e) =>
    GeoBounds(GeoPoint(s, w), GeoPoint(n, e));

void main() {
  test('the whole world is 4^z tiles per level', () {
    final world = box(-85, -180, 85, 179.999);
    expect(tileCount(world, minZoom: 0, maxZoom: 0), 1);
    expect(tileCount(world, minZoom: 1, maxZoom: 1), 4);
    expect(tileCount(world, minZoom: 0, maxZoom: 2), 1 + 4 + 16);
    expect(tileCount(world, minZoom: 3, maxZoom: 3), 64);
  });

  test('the documented example is five tiles', () {
    expect(tileCount(box(-80, -179, 80, 179), minZoom: 0, maxZoom: 1), 5);
  });

  test(
    'a rectangle across the equator and the prime meridian touches four tiles at zoom 1',
    () {
      // x: -10 is column 0 and 10 is column 1; y: 10 is row 0 and -10 is row 1.
      expect(tileCount(box(-10, -10, 10, 10), minZoom: 1, maxZoom: 1), 4);
      expect(tileCount(box(-10, -10, 10, 10), minZoom: 0, maxZoom: 1), 5);
    },
  );

  test('a small rectangle is one tile until the grid splits it', () {
    // Douala: lng 9.7 is column 4 of 8 at z3 (floor((9.7+180)/360*8) = 4), lat 4.05 is row 3.
    final douala = box(4.0, 9.6, 4.1, 9.8);
    expect(tileCount(douala, minZoom: 0, maxZoom: 3), 4);
    // z8: 256 columns: floor(189.6/360*256) = 134, floor(189.8/360*256) = 134; one column.
    expect(tileCount(douala, minZoom: 8, maxZoom: 8), 1);
  });

  test('a point is one tile on every level', () {
    final point = box(4.05, 9.7, 4.05, 9.7);
    expect(tileCount(point, minZoom: 0, maxZoom: 14), 15);
  });

  test('one tile worth of longitude at zoom 2 is a quarter of the world', () {
    // Columns of z2 are 90 degrees wide: [0, 80] spans columns 2 only (x = 180..270 degrees).
    // Rows: latitude 10..60 is row 1 (row 1 of 4 spans 0 to 66.5 north).
    expect(tileCount(box(10, 0, 60, 80), minZoom: 2, maxZoom: 2), 1);
    // Reaching into the next column at 91 degrees east.
    expect(tileCount(box(10, 0, 60, 91), minZoom: 2, maxZoom: 2), 2);
    // A latitude of exactly 0 is on the border: it belongs to the row south of it.
    expect(tileCount(box(0, 0, 60, 80), minZoom: 2, maxZoom: 2), 2);
  });

  test('a rectangle that crosses the antimeridian counts both sides', () {
    // 170 east to 170 west (-170): at z2 that is column 3 (>=90) on the east side and column 0 on the west.
    final across = box(5, 170, 10, -170);
    expect(across.crossesAntimeridian, isTrue);
    expect(tileCount(across, minZoom: 2, maxZoom: 2), 2);
  });

  test('latitudes beyond the Mercator limit are clamped', () {
    final polar = box(-90, -180, 90, 179.999);
    expect(tileCount(polar, minZoom: 2, maxZoom: 2), 16);
  });

  test('bad zoom ranges are refused', () {
    final b = box(0, 0, 1, 1);
    expect(() => tileCount(b, minZoom: -1, maxZoom: 2), throwsArgumentError);
    expect(() => tileCount(b, minZoom: 3, maxZoom: 2), throwsArgumentError);
    expect(() => tileCount(b, minZoom: 0, maxZoom: 31), throwsArgumentError);
  });
}
