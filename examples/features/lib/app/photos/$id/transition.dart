import 'package:fespalier/fespalier.dart';
import 'package:flutter/widgets.dart';

/// /photos/:id opens as a dialog over /photos, also from a deep link.
Page<void> transition(LocalKey key, Widget child) =>
    Transitions.dialog(key, child);
