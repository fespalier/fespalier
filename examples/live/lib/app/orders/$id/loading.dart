import 'package:flutter/material.dart';

/// Until the first event: no spinner, so a screenshot settles.
class OrderLoading extends StatelessWidget {
  const OrderLoading({super.key, required this.id});

  final int id;

  @override
  Widget build(BuildContext context) =>
      Center(child: Text('Connecting to order $id'));
}
