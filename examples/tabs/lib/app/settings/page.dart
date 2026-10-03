import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';
import 'package:tabs/app.g.dart';

/// Outside `(tabs)/`, so it covers the whole screen: no navigation bar.
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Settings')),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // The profile tab has the same line: same route, same name.
              const SettingsRoute().hero(
                'avatar',
                child: const CircleAvatar(radius: 40, child: Text('A')),
              ),
              const Text('Settings'),
            ],
          ),
        ),
      );
}
