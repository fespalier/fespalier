import 'package:fespalier/fespalier.dart';
import 'package:flutter/widgets.dart';

Page<void> transition(LocalKey key, Widget child) =>
    Transitions.fullscreenDialog(key, child);
