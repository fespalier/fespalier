import 'package:features/screens/plan_screen.dart';
import 'package:flutter/widgets.dart';

/// A page can be a function that returns the widget, instead of a class. This
/// route and `../pro/` build the same screen with different constants, so
/// neither needs a wrapper class. The route is `FreeRoute`, from the folder.
Widget page() => const PlanScreen(plan: Plan.free);
