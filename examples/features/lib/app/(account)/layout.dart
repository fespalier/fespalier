import 'package:flutter/material.dart';

/// `(account)` groups /profile and /settings under this layout without adding
/// anything to their URLs.
class AccountLayout extends StatelessWidget {
  const AccountLayout({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      const Text('Account'),
      Expanded(child: child),
    ],
  );
}
