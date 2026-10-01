import 'package:features/tally.dart';
import 'package:flutter/material.dart';

class RemountSegmentsPage extends StatelessWidget {
  const RemountSegmentsPage({super.key, required this.id, this.page});

  final int id;

  /// A query parameter: `?page=2`.
  final int? page;

  @override
  Widget build(BuildContext context) =>
      Tally(label: 'segments $id, page ${page ?? 1},');
}
