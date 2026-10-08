import 'package:fespalier_maps/fespalier_maps.dart';
import 'package:flutter/material.dart';

/// Says what the pin is on, as a guess, and what to do when there is no position.
class GuessCard extends StatelessWidget {
  const GuessCard(this.state, {super.key});

  final PinGuess state;

  @override
  Widget build(BuildContext context) {
    final String line;
    if (state.guessing) {
      line = 'Looking for a name...';
    } else if (state.guess case final guess?) {
      line = 'Best guess: ${guess.label}';
    } else if (state.failed) {
      line = 'No name found. The pin is still where you put it.';
    } else if (state.center == null) {
      line = switch (state.fix) {
        Denied(permanent: true) =>
          'Location is off for this app. Move the map or search.',
        Denied() ||
        ServiceOff() ||
        Unavailable() => 'No position yet. Move the map or search.',
        _ => 'Move the map to put the pin on the place.',
      };
    } else {
      line = 'The pin marks this point.';
    }
    return Card(
      margin: const EdgeInsets.all(8),
      child: Padding(padding: const EdgeInsets.all(12), child: Text(line)),
    );
  }
}

/// The search field, with its results above it. It submits on the keyboard's search action,
/// never per keystroke.
class PlaceSearchField extends StatelessWidget {
  const PlaceSearchField(this.search, {super.key});

  final PinSearch search;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      for (final place in search.results)
        ListTile(
          title: Text(place.label),
          subtitle: place.detail == null ? null : Text(place.detail!),
          onTap: () => search.pick(place),
        ),
      if (search.failed)
        const ListTile(title: Text('Search is not available right now.')),
      Padding(
        padding: const EdgeInsets.all(8),
        child: SearchBar(
          hintText: 'Search a place',
          onSubmitted: search.submit,
          trailing: [
            IconButton(
              icon: const Icon(Icons.my_location),
              tooltip: 'Use my location',
              onPressed: search.useMyLocation,
            ),
          ],
        ),
      ),
    ],
  );
}
