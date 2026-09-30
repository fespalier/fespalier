import 'package:features/screens/plan_screen.dart';
import 'package:flutter/widgets.dart';

/// The function's parameters are bound like a constructor's: `?coupon=` is the
/// query. `routeName` renames the route from the folder's `ProRoute`.
const routeName = 'ProPlan';

Widget page({String? coupon}) => PlanScreen(plan: Plan.pro, coupon: coupon);
