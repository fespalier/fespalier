import 'package:fespalier/nav.dart';
import 'package:flutter/material.dart';

/// Guarded by `(members)/guard.dart`: signed out, the entry stays in the menu, switched off.
const nav = Nav(
  label: 'Inbox',
  icon: Icons.inbox,
  order: 2,
  whenRefused: NavRefused.disable,
);
