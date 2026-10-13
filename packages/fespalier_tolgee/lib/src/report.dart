import 'package:flutter/foundation.dart';

/// Reports [problem] through `FlutterError.reportError`, library `fespalier_tolgee`, so a
/// `testWidgets` fails on it and an app's error handler sees it.
void reportProblem(Object problem, {String? context}) {
  FlutterError.reportError(
    FlutterErrorDetails(
      exception: problem,
      library: 'fespalier_tolgee',
      context: context == null ? null : ErrorDescription(context),
    ),
  );
}
