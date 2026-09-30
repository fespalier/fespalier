import 'package:fespalier/fespalier.dart';

/// `/profile/edit` stays under `/profile` in the URL (a deep link builds the
/// Profile tab beneath it, and back returns to it), but it renders on the root
/// navigator: full screen, above the navigation bar. It applies to this folder
/// and the ones below it.
const navigator = RouteNavigator.root;
