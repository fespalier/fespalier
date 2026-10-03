import 'package:fespalier/nav.dart';
import 'package:flutter/material.dart';

/// Guarded by `(members)/guard.dart` and by `guard.dart` here: left out of the menu while
/// either would refuse it (`NavRefused.hide` is the default).
const nav = Nav(label: 'Admin', icon: Icons.admin_panel_settings, order: 3);
