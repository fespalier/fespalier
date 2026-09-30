import 'package:features/app/teams/\$teamId/data.dart';
import 'package:flutter/material.dart';

/// Its own data.dart yields a String (`label`) and the section above yields a
/// Team (`team`): by type, each goes where it fits.
class MemberPage extends StatelessWidget {
  const MemberPage({super.key, required this.label, required this.team});

  final String label;
  final Team team;

  @override
  Widget build(BuildContext context) => Text('$label of ${team.name}');
}
