import 'package:flutter/material.dart';

enum Plan { free, pro }

/// A screen that lives outside `lib/app/`, next to the rest of the app's widgets.
/// Two routes build it with different constants: see `lib/app/(plans)/`.
class PlanScreen extends StatelessWidget {
  const PlanScreen({super.key, required this.plan, this.coupon});

  final Plan plan;
  final String? coupon;

  @override
  Widget build(BuildContext context) => Text(
        'Plan ${plan.name}${coupon == null ? '' : ' (coupon $coupon)'}',
      );
}
