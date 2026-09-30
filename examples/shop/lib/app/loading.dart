import 'package:flutter/material.dart';
import 'package:trellis/trellis.dart';

class RootLoading extends Loading<Params> {
  const RootLoading(super.params, {super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      const Center(child: CircularProgressIndicator());
}
