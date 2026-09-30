import 'package:flutter/material.dart';

/// Reads the section's data (it has no data.dart of its own). The query parameter the
/// section is keyed by isn't a parameter of this page, so the generated code reads it
/// from the URL.
class MonthlyReportPage extends StatelessWidget {
  const MonthlyReportPage({super.key, required this.data});

  final String data;

  @override
  Widget build(BuildContext context) => Text('Monthly: $data');
}
