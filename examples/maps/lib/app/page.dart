import 'package:fespalier_maps/fespalier_maps.dart';
import 'package:flutter/material.dart';
import 'package:maps/app.g.dart';

/// Where should we deliver? The place comes back from the picker; the point is what it stores,
/// the name is a guess shown with its caveat.
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  PickedPlace? _place;

  Future<void> _pick() async {
    // Completes with what the picker pops, or null when the person goes back.
    final place = await const PickPlaceRoute().push<PickedPlace>(context);
    if (!mounted || place == null) return;
    setState(() => _place = place);
  }

  @override
  Widget build(BuildContext context) {
    final place = _place;
    return Scaffold(
      appBar: AppBar(title: const Text('Maps')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('Where should we deliver?'),
          if (place == null)
            const Text('No place yet.')
          else ...[
            Text(
              'Point: ${place.point.latitude.toStringAsFixed(4)}, '
              '${place.point.longitude.toStringAsFixed(4)}',
            ),
            Text(
              place.guess == null
                  ? 'No name for this point.'
                  : 'Best guess: ${place.guess!.label}',
            ),
          ],
          FilledButton(onPressed: _pick, child: const Text('Pick a place')),
          TextButton(
            onPressed: () => const OfflineRoute().go(context),
            child: const Text('Offline map'),
          ),
        ],
      ),
    );
  }
}
