import 'package:features/app.g.dart';
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
