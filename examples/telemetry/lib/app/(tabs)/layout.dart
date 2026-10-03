import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';

/// A tab layout: each tab keeps its own stack, and the observe.dart hooks follow them. A page in
/// a tab that is not the current one is parked, not left.
const tabs = ['(home)', 'orders', 'settings'];

class TabsLayout extends StatelessWidget {
  const TabsLayout({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: navigationShell,
    bottomNavigationBar: NavigationBar(
      selectedIndex: navigationShell.currentIndex,
      onDestinationSelected: (i) => navigationShell.goBranch(i),
      destinations: const [
        NavigationDestination(icon: Icon(Icons.home), label: 'Home'),
        NavigationDestination(icon: Icon(Icons.receipt_long), label: 'Orders'),
        NavigationDestination(icon: Icon(Icons.settings), label: 'Settings'),
      ],
    ),
  );
}
