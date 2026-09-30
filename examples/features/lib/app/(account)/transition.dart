import 'package:fespalier/fespalier.dart';
import 'package:flutter/widgets.dart';

/// /profile and /settings fade in.
Page<void> transition(LocalKey key, Widget child) =>
    Transitions.fade(key, child);
