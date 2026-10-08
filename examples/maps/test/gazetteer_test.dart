// The app's geocoder is a fixed list: plain tests, no widget and no network.
import 'package:fespalier_maps/fespalier_maps.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maps/places.dart';

void main() {
  const gazetteer = Gazetteer(cameroon);

  test('reverse names the point asked about, from the nearest city', () async {
    const point = GeoPoint(4.0, 9.8);
    final guess = await gazetteer.reverse(point);
    expect(guess?.label, 'Douala');
    expect(guess?.point, point);
  });

  test('reverse has no name for a point far from every city', () async {
    expect(await gazetteer.reverse(const GeoPoint(0, 20)), isNull);
  });

  test('search matches the start of a name, case-insensitively', () async {
    final found = await gazetteer.search('ba');
    expect(found.map((p) => p.label), ['Bafoussam', 'Bamenda']);
    expect(await gazetteer.search('  '), isEmpty);
  });

  test('search puts the nearest first', () async {
    final found = await gazetteer.search(
      'ba',
      near: const GeoPoint(5.96, 10.16),
    );
    expect(found.first.label, 'Bamenda');
  });
}
