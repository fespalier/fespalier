import 'package:fespalier/nav.dart';
import 'package:flutter/material.dart';

/// The app folder's own entry. The app folder is flat: the entries of the folders below sit
/// beside this one, and it is selected on `/` alone.
const nav = Nav(
  label: 'Home',
  icon: Icons.home_outlined,
  selectedIcon: Icons.home,
);
