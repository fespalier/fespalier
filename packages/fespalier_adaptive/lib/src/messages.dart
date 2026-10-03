import 'package:flutter/foundation.dart';

/// A-M1: a tab layout's current tab has no entry in the menu, so a phone's bar is hidden.
String noTabEntryMessage(int index) =>
    'fespalier_adaptive: no menu entry is the current tab ($index) of the tab layout, so the '
    "navigation bar is hidden. Give the tab's folder a nav.dart (not inMenu: false), and pass "
    "AppMenu.watch(ref, under: <the tab layout's folder>).";

var _noTabEntryReported = false;

/// Prints [noTabEntryMessage] for the tab [index] in a debug build, the first time it is called.
///
/// Once per process: the scaffold builds on every resize and navigation, and the cause is in the
/// layout's source, not in the frame.
void debugReportNoTabEntry(int index) {
  assert(() {
    if (_noTabEntryReported) return true;
    _noTabEntryReported = true;
    debugPrint(noTabEntryMessage(index));
    return true;
  }());
}

/// Forgets what [debugReportNoTabEntry] already printed, for a test that checks the message.
@visibleForTesting
void debugResetAdaptiveReports() {
  _noTabEntryReported = false;
}
