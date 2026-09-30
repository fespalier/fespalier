import 'package:flutter/material.dart';

/// A page can be a function instead of a class. The folder gives the path
/// (`about/page.dart` → `/about`) and the route's name (AboutRoute). A function
/// view has no `ref` or hooks; put those in the widget it returns.
Widget page() => const Center(child: Text('A page written as a function.'));
