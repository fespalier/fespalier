import 'package:fespalier/fespalier.dart'
    show
        FespalierTelemetry,
        TelemetryEnd,
        TelemetryOp,
        TelemetryOutcome,
        TelemetryStart;
import 'package:flutter/painting.dart';

import 'variants.dart';

/// Whether a telemetry sink is installed: the one check before a configuration is made for a span
/// nobody will read.
bool get imageTelemetryOn => FespalierTelemetry.current != null;

/// Starts an `image` span for the load of [provider] and ends it when the load does (since 0.9.0),
/// when a sink is installed and the image cache has not got the image (nothing is loading it, and
/// it is not there): a cache hit and a load already in flight make no span.
///
/// The span is named by the builder ([cdn]) and the width asked for: never the URL, the source,
/// a signature or the error's text (the exception's message holds the URL), only the HTTP status
/// of a failed load. It is a child of the navigation in progress, if any: an image that starts
/// loading while a page is being reached is part of reaching it. [preload] says a precache
/// started it.
///
/// It resolves [provider] with [configuration], which starts the load a moment before the widget
/// that asked would have; the widget then joins that one load. It creates no `Future`, no
/// microtask and no timer: one stream listener, which removes itself on the first image or error
/// (a widget disposed before the load ends leaves it to end the span).
void traceImageLoad(
  ImageProvider<Object> provider,
  ImageConfiguration configuration, {
  required String cdn,
  required int width,
  required bool preload,
}) {
  if (FespalierTelemetry.current == null) return;
  try {
    final status = imageStatusOf(provider);
    if (status == null || !status.untracked) return;
    final token = FespalierTelemetry.begin(
      TelemetryStart(
        TelemetryOp.image,
        imageCdn: cdn,
        imageWidth: width,
        imagePreload: preload,
      ),
      underNavigation: true,
    );
    final stream = provider.resolve(configuration);
    var ended = false;
    late final ImageStreamListener listener;
    void end(TelemetryEnd result) {
      if (ended) return;
      ended = true;
      stream.removeListener(listener);
      FespalierTelemetry.finish(token, result);
    }

    listener = ImageStreamListener(
      (ImageInfo image, bool synchronousCall) {
        image.dispose();
        end(const TelemetryEnd(TelemetryOutcome.ok, isAsync: true));
      },
      onError: (Object error, StackTrace? stackTrace) => end(
        TelemetryEnd(
          TelemetryOutcome.error,
          isAsync: true,
          // No `error:`: its text carries the URL.
          imageStatus: error is NetworkImageLoadException
              ? error.statusCode
              : null,
        ),
      ),
    );
    stream.addListener(listener);
  } catch (_) {
    // A failing sink or provider costs the span, never the image.
  }
}
