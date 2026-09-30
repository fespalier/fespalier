import 'package:flutter/material.dart';

/// Gets the section's data as `data`: what data.dart yields for the `?period=` in the URL.
class ReportsLayout extends StatelessWidget {
  const ReportsLayout({super.key, required this.data, required this.child});

  final String data;
  final Widget child;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Text('Reports: $data'),
      Expanded(child: child),
    ],
  );
}
