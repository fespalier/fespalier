import 'package:features/app/teams/\$teamId/data.dart';
import 'package:flutter/material.dart';

/// A parameter called `data` gets the nearest data.dart: here the section's.
class TeamSettingsPage extends StatelessWidget {
  const TeamSettingsPage({super.key, required this.data});

  final Team data;

  @override
  Widget build(BuildContext context) => Text('Settings of ${data.name}');
}
