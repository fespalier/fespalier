import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

const tabs = ['a'];

class TabsLayout extends StatelessWidget {
  const TabsLayout({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context) => navigationShell;
}
