import 'package:fespalier/nav.dart';
import 'package:flutter/material.dart';

/// No `whenRefused`: while the flag is off the guard refuses the entry, and a refused entry is hidden.
const nav = Nav(
  label: 'Labs',
  icon: Icons.science_outlined,
  selectedIcon: Icons.science,
  order: 6,
);
