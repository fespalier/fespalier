import 'package:fespalier/nav.dart';
import 'package:flutter/widgets.dart';

/// A folder with no page.dart is a heading: it holds the entries of the folders below it,
/// and it needs the `$teamId` of the location to be in the menu.
const nav = Nav(label: 'Team', order: 4);

String label(BuildContext context, {required String teamId}) =>
    'Team ${teamId.toUpperCase()}';
