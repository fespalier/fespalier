import 'package:fespalier/fespalier.dart';

class Team {
  const Team(this.name, this.members);

  final String name;
  final List<String> members;
}

/// How many times [data] ran; the tests read it to see it's shared.
int teamFetches = 0;

/// This folder has a layout.dart and no page.dart, so this is the data of the
/// whole section below it: the layout and the pages under it can take a [Team].
/// The section shows loading.dart or error.dart until it has loaded.
Future<Team> data(Ref ref, {required String teamId}) async {
  teamFetches++;
  await Future<void>.delayed(const Duration(milliseconds: 10));
  if (teamId == 'ghost') throw Exception('no team $teamId');
  return Team(teamId.toUpperCase(), const ['ann', 'bob']);
}
