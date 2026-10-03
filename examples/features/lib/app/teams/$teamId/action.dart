import 'package:features/app.g.dart';
import 'package:features/app/teams/\$teamId/data.dart';
import 'package:features/refunds.dart';
import 'package:fespalier/fespalier.dart';

/// What a success makes stale. The default for a section's action is its own data and the sections
/// above it, so this list says what is already the case; it is the place to add a route or to
/// leave the data alone (`const invalidates = <Object>[];`). Names are typed routes and section
/// handles: providers are not const.
const invalidates = [TeamsTeamIdSection];

/// An action in a section's folder (a layout.dart and no page.dart): its typed members are on
/// `TeamsTeamIdSection`, and what it makes stale is the section's own data, which the layout
/// and every page below it show. A function with another name than `action` names its helpers
/// after itself: `TeamsTeamIdSection.addMember` and `useAddMember`.
Future<void> addMember(
  Ref ref, {
  required String teamId,
  required String input,
}) async =>
    ref.read(rosterProvider).add(teamId, input);

/// What the team shows while `addMember()` runs: the member is on the page from the first frame
/// (since 0.8.1). A failure takes it back; a success keeps it until the team has loaded again,
/// so the list never loses her in between. Its type, `Team`, is what the section's data.dart
/// gives, which is how it finds the data to patch.
Team addMemberOptimistic(Team team, String input) =>
    Team(team.name, [...team.members, input]);
