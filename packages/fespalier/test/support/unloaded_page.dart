// A second library for `deferred_unloaded_test.dart`, imported `deferred as` and never loaded
// there, so no other test can have loaded it first.
import 'package:flutter/widgets.dart';

/// A page that is never built: its library is never loaded.
class UnloadedPage extends StatelessWidget {
  const UnloadedPage({super.key});

  @override
  Widget build(BuildContext context) => const Text('unloaded page');
}
