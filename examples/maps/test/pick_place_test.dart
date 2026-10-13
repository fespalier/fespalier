// The pin picker on the generated router. The map is a FakeMapSurface (a MapLibre map is a
// platform view and does not draw in a widget test) and the test plays it: startMove() is a drag,
// idleAt(point) is the map coming to rest with that point under the pin. The geocoder is the
// app's own Gazetteer, a fixed list, so nothing here touches the network.
import 'package:fespalier/testing.dart';
import 'package:fespalier_maps/fespalier_maps.dart';
import 'package:fespalier_maps/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maps/app.g.dart';
import 'package:maps/places.dart';

void main() {
  late FakeMapSurface map;

  Future<void> boot(
    WidgetTester tester, {
    required FakePositionSource position,
    String location = '/',
  }) async {
    map = FakeMapSurface();
    await pumpRouter(
      tester,
      AppRoutes.router(initialLocation: location),
      overrides: [
        mapSurface.overrideWithValue(map),
        positionSource.overrideWithValue(position),
      ],
    );
  }

  FilledButton confirmButton(WidgetTester tester) =>
      tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Use this place'),
      );

  Future<void> openPicker(WidgetTester tester) async {
    await tester.tap(find.text('Pick a place'));
    await tester.pumpAndSettle();
    expect(currentLocation(tester), '/pick-place');
  }

  testWidgets('pan, a guess, confirm: the point and the guess come back', (
    tester,
  ) async {
    await boot(tester, position: FakePositionSource(const Denied()));
    expect(find.text('No place yet.'), findsOneWidget);
    await openPicker(tester);

    // The map's first rest on the world is not a choice: there is no point to return yet.
    expect(confirmButton(tester).onPressed, isNull);

    map.startMove();
    map.idleAt(const GeoPoint(4.05, 9.7)); // a little west of Douala
    await tester.pumpAndSettle();

    // A name is a guess, and says so.
    expect(find.text('Best guess: Douala'), findsOneWidget);
    expect(confirmButton(tester).onPressed, isNotNull);
    expect(find.byType(Dialog), findsNothing);

    await tester.tap(find.text('Use this place'));
    await tester.pumpAndSettle();
    expect(currentLocation(tester), '/');
    expect(find.text('Point: 4.0500, 9.7000'), findsOneWidget);
    expect(find.text('Best guess: Douala'), findsOneWidget);
  });

  testWidgets(
    'far from every city there is no name, and the point still comes back',
    (tester) async {
      await boot(tester, position: FakePositionSource(const Denied()));
      await openPicker(tester);

      map.startMove();
      map.idleAt(const GeoPoint(0.5, 20));
      await tester.pumpAndSettle();
      expect(find.text('The pin marks this point.'), findsOneWidget);

      await tester.tap(find.text('Use this place'));
      await tester.pumpAndSettle();
      expect(find.text('Point: 0.5000, 20.0000'), findsOneWidget);
      expect(find.text('No name for this point.'), findsOneWidget);
    },
  );

  testWidgets('a position that is refused is a hint, not an error', (
    tester,
  ) async {
    await boot(
      tester,
      position: FakePositionSource(const Denied(permanent: true)),
    );
    await openPicker(tester);
    expect(
      find.text('Location is off for this app. Move the map or search.'),
      findsOneWidget,
    );
    expect(confirmButton(tester).onPressed, isNull);
  });

  testWidgets('a fix moves the map to where the device is', (tester) async {
    await boot(
      tester,
      position: FakePositionSource(const Fixed(GeoPoint(3.848, 11.5021))),
    );
    await openPicker(tester);
    expect(map.moves.single.center, const GeoPoint(3.848, 11.5021));
    expect(confirmButton(tester).onPressed, isNotNull);
  });

  testWidgets('a late fix does not override a pan', (tester) async {
    final position = FakePositionSource(
      const Fixed(GeoPoint(3.848, 11.5021)),
      hold: true,
    );
    await boot(tester, position: position);
    await openPicker(tester);

    // The person pans before the position arrives.
    map.startMove();
    map.idleAt(const GeoPoint(5.4737, 10.4179));
    await tester.pumpAndSettle();
    position.release(); // the late fix
    await tester.pumpAndSettle();

    expect(map.moves, isEmpty); // the map was not moved to the fix
    await tester.tap(find.text('Use this place'));
    await tester.pumpAndSettle();
    expect(find.text('Point: 5.4737, 10.4179'), findsOneWidget);
    expect(find.text('Best guess: Bafoussam'), findsOneWidget);
  });

  testWidgets('a search is submitted, then a result moves the map', (
    tester,
  ) async {
    await boot(tester, position: FakePositionSource(const Denied()));
    await openPicker(tester);

    await tester.enterText(find.byType(TextField), 'Bam');
    await tester.pump();
    expect(find.text('Bamenda'), findsNothing); // nothing is sent per keystroke
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(find.text('Bamenda'), findsOneWidget);

    await tester.tap(find.text('Bamenda'));
    await tester.pumpAndSettle();
    expect(map.moves.last.center, const GeoPoint(5.9631, 10.1591));
    // The result's name is the guess for the point it moved to.
    expect(find.text('Best guess: Bamenda'), findsOneWidget);
  });
}
