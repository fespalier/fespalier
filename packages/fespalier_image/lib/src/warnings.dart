import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'builder.dart';

bool _unconfiguredWarned = false;

/// Debug builds only, once per isolate: [source] is not a URL and no image CDN is configured,
/// so there is nothing to fetch it with: with neither a `transport` nor a `providerFactory` on the
/// `ImageCdn`, the image shows its error view and an `ImageUrlError` is reported (M1).
void warnUnconfigured(String source) {
  assert(() {
    if (_unconfiguredWarned) return true;
    _unconfiguredWarned = true;
    debugPrint(
      'fespalier_image: "$source" is not a URL and no image CDN is configured, '
      'so nothing is fetched: without an ImageCdn that has a transport the image shows its '
      'error view and an ImageUrlError is reported. Override imageCdnProvider in startup() '
      '(docs/responsive-images.md, "Images").',
    );
    return true;
  }());
}

/// Lets a test see [warnUnconfigured] again.
@visibleForTesting
void resetImageWarnings() => _unconfiguredWarned = false;

/// Reports [error], an [ImageUrlError], while [what] (M2): the library is `fespalier_image`.
void reportUrlError(ImageUrlError error, StackTrace stack, String what) {
  FlutterError.reportError(
    FlutterErrorDetails(
      exception: error,
      stack: stack,
      library: 'fespalier_image',
      context: ErrorDescription(what),
    ),
  );
}
