import 'package:fespalier/nav.dart';
import 'package:flutter/material.dart';

// library/ has no page.dart, so this entry is a heading: the Library tab, with Books and Authors
// below it. A bar or a rail lists it as a destination (it is a tab); the drawer shows it as the
// title of a section.
const nav = Nav(
  label: 'Library',
  icon: Icons.library_books_outlined,
  selectedIcon: Icons.library_books,
);
