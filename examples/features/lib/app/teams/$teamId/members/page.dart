import 'package:features/app/teams/\$teamId/data.dart';
import 'package:flutter/material.dart';

/// Takes the section's `Team` by type; it has no data.dart of its own.
class MembersPage extends StatelessWidget {
  const MembersPage(this.team, {super.key});

  final Team team;

  @override
  Widget build(BuildContext context) => Text('Members: ${team.members.join(', ')}');
}
