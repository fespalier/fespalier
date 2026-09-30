import 'package:flutter/material.dart';

/// Outside `(tabs)/`, so it covers the whole screen: no navigation bar.
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Settings')),
    body: const Center(child: Text('Settings')),
  );
}
