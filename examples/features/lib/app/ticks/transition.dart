import 'package:fespalier/fespalier.dart';
import 'package:flutter/widgets.dart';

/// /ticks appears instantly.
Page<void> transition(LocalKey key, Widget child) =>
    Transitions.none(key, child);
