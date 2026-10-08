import 'package:fespalier/fespalier.dart';
import 'package:fespalier_maps/fespalier_maps.dart';
import 'package:flutter/material.dart';
import 'package:maps/place_widgets.dart';
import 'package:maps/places.dart';

/// Picks a place: a pin fixed at the centre, the map moving under it. Confirming pops a
/// `PickedPlace` to the page that did `await PickPlaceRoute().push<PickedPlace>(context)`.
class PickPlacePage extends ConsumerWidget {
  const PickPlacePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
    // The picker is the whole body, so the keyboard lifts the search field with it.
    body: PinPicker(
      map: ref.watch(mapSurface),
      geocoder: ref.watch(geocoder),
      position: ref.watch(positionSource),
      guess: (context, state) => GuessCard(state),
      searchField: (context, search) => PlaceSearchField(search),
      confirm: (context, confirm) => Padding(
        padding: const EdgeInsets.all(8),
        // Null until the pin has a point and the map is at rest.
        child: FilledButton(
          onPressed: confirm,
          child: const Text('Use this place'),
        ),
      ),
    ),
  );
}
