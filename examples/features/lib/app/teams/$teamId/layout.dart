import 'package:features/app/teams/\$teamId/data.dart';
import 'package:flutter/material.dart';

/// Gets the section's data by type: `Team` is what data.dart yields.
class TeamLayout extends StatelessWidget {
  const TeamLayout({super.key, required this.team, required this.child});

  final Team team;
  final Widget child;

  @override
  Widget build(BuildContext context) => Column(
        children: [
          Text('Team ${team.name}'),
          Expanded(child: child),
        ],
      );
}
