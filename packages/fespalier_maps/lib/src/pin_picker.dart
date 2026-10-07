import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';

import 'geo.dart';
import 'pin_model.dart';
import 'ports.dart';

/// Where the tip of Material's `location_on` glyph is, as a fraction of its box (22 of 24).
const double _glyphTip = 22 / 24;

/// A page body that picks a place: the pin is fixed at the centre and the map moves under it.
///
/// - **Seeded once** from [position] (the platform's own permission prompt, never a dialog of
///   ours) unless [initial] says where to start; a refusal, a switched-off service or no fix is
///   a value in [PinGuess.fix] for the app to render, and the map stays where it is.
/// - **Search** is the app's own field: [searchField] gets a [PinSearch] and is laid out at the
///   bottom of the picker, so put the picker's body where the thumb is (a `Scaffold` body that
///   resizes for the keyboard puts the field on the keyboard). It submits a query, never one per
///   keystroke, and picking a result moves the map.
/// - **Reverse geocoding** runs when the map comes to rest, never while it moves, and an answer
///   that a newer request has overtaken is dropped. [guess] shows it as a guess: say so.
/// - **Confirm** is the app's button: [confirm] gets a callback that is null until there is a
///   point and the map is at rest, and calling it returns a [PickedPlace] (the point is the
///   truth, the label a courtesy) through `GoRouter.pop`, so the page that did
///   `await PickPlaceRoute().push<PickedPlace>(context)` gets it. [onPicked] replaces that.
///
/// Nothing here opens a dialog, a menu or a sheet. It is a body, not a page: the app writes the
/// `lib/app/pick-place/page.dart` that holds it, and the route is the app's.
class PinPicker extends HookWidget {
  /// A picker over [map] and [geocoder].
  const PinPicker({
    super.key,
    required this.map,
    required this.geocoder,
    required this.searchField,
    required this.guess,
    required this.confirm,
    this.position,
    this.initial,
    this.locale,
    this.pin,
    this.focusZoom = 16,
    this.onPicked,
  });

  /// The map under the pin: `MapLibreSurface` from `package:fespalier_maps/maplibre.dart`.
  /// Keep one instance for the life of the page (a `final` field or a provider), not one per
  /// build: a new [map] makes a new picker state. A surface may serve several pickers; `moveTo` reaches the one mounted last.
  final MapSurface map;

  /// The geocoder; the app's choice and the app's terms of use.
  final Geocoder geocoder;

  /// Where the device is, or null for a picker that never asks:
  /// `GeolocatorPositionSource()` from `package:fespalier_maps/geolocator.dart`.
  final PositionSource? position;

  /// Where the map starts, for editing an existing place; [position] is then not asked until
  /// the person taps "use my location".
  final MapCamera? initial;

  /// The BCP 47 tag the geocoder labels in (`context.locale` of the app's translations, say).
  final String? locale;

  /// The zoom for a fix or a picked result.
  final double focusZoom;

  /// The search field and its results, docked at the bottom of the picker.
  final Widget Function(BuildContext context, PinSearch search) searchField;

  /// The card that shows the pin's guess, with its caveat ("best guess").
  final Widget Function(BuildContext context, PinGuess guess) guess;

  /// The confirm button; its callback is null until a place can be returned.
  final Widget Function(BuildContext context, VoidCallback? confirm) confirm;

  /// The pin; its bottom centre is the point. By default Material's `location_on` glyph, placed
  /// so that the tip of the marker (not the bottom of its box) is the point.
  final Widget? pin;

  /// Called with the place instead of popping the route.
  final ValueChanged<PickedPlace>? onPicked;

  void _deliver(BuildContext context, PickedPlace place) {
    final handler = onPicked;
    if (handler != null) {
      handler(place);
      return;
    }
    final router = GoRouter.maybeOf(context);
    if (router != null && router.canPop()) {
      router.pop(place);
    } else {
      // Nothing under the page (opened by a link, or with `go`): there is nobody to answer, and
      // GoRouter.pop would throw. A navigator with a route under this one is popped; otherwise
      // nothing happens, and the app that opens the picker that way passes [onPicked].
      final navigator = Navigator.maybeOf(context);
      if (navigator != null && navigator.canPop()) {
        navigator.pop(place);
      } else {
        assert(() {
          debugPrint(
            'fespalier_maps: PinPicker has nowhere to pop to (the page was opened with go or a '
            'link): pass onPicked: to receive the place.',
          );
          return true;
        }());
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // One model for the life of the page, whatever the parent rebuilds with: the map captured this
    // model's callbacks when it was created, so a new model would leave it talking to the old one.
    // A new geocoder, locale or zoom is assigned to it; a new [map] is a new picker.
    final model = useMemoized(
      () => PinPickerModel(
        map: map,
        geocoder: geocoder,
        position: position,
        initial: initial,
        locale: locale,
        focusZoom: focusZoom,
      ),
      [map],
    );
    model
      ..geocoder = geocoder
      ..position = position
      ..locale = locale
      ..focusZoom = focusZoom;
    useListenable(model);
    useEffect(() {
      unawaited(model.seed());
      return null;
    }, [model]);
    useEffect(() => model.dispose, [model]);

    return Stack(
      children: [
        Positioned.fill(
          child: map.build(
            context,
            model.initialCamera,
            onIdle: model.onIdle,
            onMove: model.onMove,
          ),
        ),
        Center(
          child: IgnorePointer(
            child: FractionalTranslation(
              // A custom pin's bottom centre is the point; the glyph's tip is 2/24 above its box.
              translation: Offset(0, pin == null ? -(_glyphTip - 0.5) : -0.5),
              child: pin ?? const Icon(Icons.location_on, size: 48),
            ),
          ),
        ),
        Align(
          alignment: Alignment.bottomCenter,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              guess(context, model.guessState),
              searchField(context, model.search),
              confirm(
                context,
                model.canConfirm
                    ? () {
                        final place = model.confirm();
                        if (place != null) _deliver(context, place);
                      }
                    : null,
              ),
            ],
          ),
        ),
      ],
    );
  }
}
