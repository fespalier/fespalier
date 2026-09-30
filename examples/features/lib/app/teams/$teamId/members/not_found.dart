import 'package:flutter/material.dart';

/// A not_found.dart takes the segments of its own path as Strings, as the URL spells
/// them: the ones that failed to parse (`/teams/acme/members/x`) are why it is shown, so
/// they can't be typed. `teamId` is `acme` here.
class MembersNotFound extends StatelessWidget {
  const MembersNotFound({super.key, required this.uri, required this.teamId});

  final Uri uri;
  final String teamId;

  @override
  Widget build(BuildContext context) => Column(
        children: [Text('No member at ${uri.path}'), Text('Team: $teamId')],
      );
}
