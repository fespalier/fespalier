import 'package:fespalier/fespalier.dart';
import 'package:flutter/widgets.dart';

/// How every route animates in.
Page<void> transition(LocalKey key, Widget child) =>
    Transitions.material(key, child);
