import 'package:features/tally.dart';
import 'package:flutter/material.dart';

class RemountLocationPage extends StatelessWidget {
  const RemountLocationPage({super.key, required this.id, this.page});

  final int id;

  /// A query parameter: `?page=2`.
  final int? page;

  @override
  Widget build(BuildContext context) =>
      Tally(label: 'location $id, page ${page ?? 1},');
}
