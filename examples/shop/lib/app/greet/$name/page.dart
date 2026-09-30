import 'package:flutter/material.dart';
import 'package:shop/app.g.dart';
import 'package:trellis/trellis.dart';

/// No params.dart here, so trellis generates `GreetParams { String name }`.
class GreetPage extends Screen<GreetParams> {
  const GreetPage(super.data, {super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      Center(child: Text('Hello, ${data.name}'));
}
