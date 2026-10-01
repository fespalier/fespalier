import 'package:features/app.g.dart';
import 'package:features/app/teams/\$teamId/data.dart';
import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';

/// Takes the section's `Team` by type; it has no data.dart of its own. Its button writes to the
/// section (`../action.dart`), and the team reloads for the layout and this page.
class MembersPage extends ConsumerWidget {
  const MembersPage(this.team, {super.key, required this.teamId});

  final Team team;
  final String teamId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final add = TeamsTeamIdSection.useAddMember(ref, teamId: teamId);
    return Column(
      children: [
        Text('Members: ${team.members.join(', ')}'),
        TextButton(
          onPressed: add.isPending ? null : () => add.call('carol'),
          child: const Text('Add carol'),
        ),
      ],
    );
  }
}
