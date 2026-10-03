import 'dart:async';

import 'package:fespalier/fespalier.dart'
    show ConsumerState, ConsumerStatefulWidget, ProviderScope;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'buckets.dart';
import 'builder.dart';
import 'builders/common.dart';
import 'builders/direct.dart';
import 'cdn.dart';
import 'request.dart';
import 'variants.dart';
import 'warnings.dart';

/// A network image fetched at the width its box needs (since 0.9.0): the box's logical width ×
/// the device pixel ratio, rounded up to a bucket, through the app's [ImageCdn]
/// (`imageCdnProvider`). Every argument but [source] overrides the CDN's default for this image.
/// Needs the app's `ProviderScope` above it, like `RouteLink`.
///
/// ```dart
/// ResponsiveImage('products/3.jpg', width: 160, aspectRatio: 1)
/// ```
///
/// What it asks for is decided once per element and only ever grows (see [growWithBox]), so an
/// animated box (a hero flight, an `AnimatedSize`) asks for one width. While its URL loads it
/// shows the widest variant of the same picture that is already loaded instead of the
/// placeholder, so a thumbnail stands in for the large image.
class ResponsiveImage extends ConsumerStatefulWidget {
  /// The image [source]: a path the CDN knows, a URL, or a srcset (with `SrcsetUrlBuilder`).
  const ResponsiveImage(
    this.source, {
    super.key,
    this.width,
    this.height,
    this.aspectRatio,
    this.resize = ImageResize.fill,
    this.fit = BoxFit.cover,
    this.alignment = Alignment.center,
    this.quality,
    this.format,
    this.extra = const <String>[],
    this.builder,
    this.buckets,
    this.growWithBox = false,
    this.placeholder,
    this.errorBuilder,
    this.fadeIn,
    this.semanticLabel,
    this.excludeFromSemantics = false,
  });

  /// What to show.
  final String source;

  /// The box's logical width. Given, it is not measured (and the widget works inside
  /// `IntrinsicWidth`).
  final double? width;

  /// The box's logical height. With [width], the image is cropped to width ÷ height by the CDN.
  final double? height;

  /// Width ÷ height: the CDN crops to it ([resize]) and the box takes it. Without it (and without
  /// both [width] and [height]) the request is width-only and [fit] crops on the device.
  final double? aspectRatio;

  /// How the CDN fits the source into the shape.
  final ImageResize resize;

  /// How the image fills its box.
  final BoxFit fit;

  /// Where it sits in its box.
  final AlignmentGeometry alignment;

  /// Overrides the CDN's quality.
  final int? quality;

  /// Overrides the CDN's format.
  final ImageFormat? format;

  /// Provider-specific options ([ImageRequest.extra]).
  final List<String> extra;

  /// Overrides the CDN's builder.
  final ImageUrlBuilder? builder;

  /// Overrides the CDN's buckets.
  final ImageBuckets? buckets;

  /// Asks for a wider bucket when the box grows past the one shown (never a narrower one). Off:
  /// an animated box (a hero flight, an `AnimatedSize`) asks for one width.
  final bool growWithBox;

  /// Overrides the CDN's placeholder.
  final WidgetBuilder? placeholder;

  /// Overrides the CDN's error view.
  final ResponsiveImageErrorBuilder? errorBuilder;

  /// Overrides the CDN's fade.
  final Duration? fadeIn;

  /// `Image.semanticLabel`.
  final String? semanticLabel;

  /// `Image.excludeFromSemantics`.
  final bool excludeFromSemantics;

  /// Starts loading [source] at the size a [ResponsiveImage] [width] logical pixels wide (by
  /// default the view's width) and [aspectRatio] would ask for, with the CDN of [context]. For
  /// `RouteLink(onPreload:)`. Completes when it is loaded or failed; a failure is dropped (the
  /// widget shows its own error).
  ///
  /// Give it the width the page shows the image at (a constant both share): buckets absorb a few
  /// pixels of padding, so the URL it loads is then the one the page asks for.
  static Future<void> precache(
    BuildContext context,
    String source, {
    double? width,
    double? height,
    double? aspectRatio,
    ImageResize resize = ImageResize.fill,
    int? quality,
    ImageFormat? format,
    List<String> extra = const <String>[],
    ImageUrlBuilder? builder,
    ImageBuckets? buckets,
  }) {
    final cdn = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(imageCdnProvider);
    final ResolvedImage? resolved;
    try {
      resolved = cdn.resolve(
        source,
        logicalWidth: width ?? MediaQuery.sizeOf(context).width,
        devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
        aspectRatio: aspectRatio ?? _ratioOf(width, height),
        resize: resize,
        quality: quality,
        format: format,
        extra: extra,
        builder: builder,
        buckets: buckets,
      );
    } on ImageUrlError catch (error, stack) {
      reportUrlError(error, stack, 'while precaching the image "$source"');
      return SynchronousFuture<void>(null);
    }
    if (resolved == null) return SynchronousFuture<void>(null);
    final provider = cdn.providerFor(resolved);
    ImageVariants.register(resolved, cdn.providerFactory, provider);
    return precacheImage(
      provider,
      context,
      onError: (Object error, StackTrace? stack) {},
    );
  }

  /// A `Hero.flightShuttleBuilder` for heroes that hold a [ResponsiveImage]: Flutter's default
  /// shuttle (the destination's child, with the safe-area padding animated), under a
  /// [ResponsiveImageFlight], so the image in flight starts no load and shows the largest
  /// variant of its source already loaded.
  static Widget flightShuttle(
    BuildContext flightContext,
    Animation<double> animation,
    HeroFlightDirection flightDirection,
    BuildContext fromHeroContext,
    BuildContext toHeroContext,
  ) {
    final toHero = toHeroContext.widget as Hero;
    final toMediaQuery = MediaQuery.maybeOf(toHeroContext);
    final fromMediaQuery = MediaQuery.maybeOf(fromHeroContext);
    if (toMediaQuery == null || fromMediaQuery == null) {
      return ResponsiveImageFlight(child: toHero.child);
    }
    final fromPadding = fromMediaQuery.padding;
    final toPadding = toMediaQuery.padding;
    return ResponsiveImageFlight(
      child: AnimatedBuilder(
        animation: animation,
        builder: (context, child) => MediaQuery(
          data: toMediaQuery.copyWith(
            padding: flightDirection == HeroFlightDirection.push
                ? EdgeInsetsTween(
                    begin: fromPadding,
                    end: toPadding,
                  ).evaluate(animation)
                : EdgeInsetsTween(
                    begin: toPadding,
                    end: fromPadding,
                  ).evaluate(animation),
          ),
          child: toHero.child,
        ),
      ),
    );
  }

  @override
  ConsumerState<ResponsiveImage> createState() => _ResponsiveImageState();
}

double? _ratioOf(double? width, double? height) =>
    width != null && height != null && height > 0 ? width / height : null;

/// Marks a hero flight for the [ResponsiveImage]s below it (since 0.9.0): they start no load.
/// For a shuttle of your own; [ResponsiveImage.flightShuttle] puts one in.
class ResponsiveImageFlight extends InheritedWidget {
  /// Marks [child].
  const ResponsiveImageFlight({super.key, required super.child});

  /// Whether [context] is in a flight (`getInheritedWidgetOfExactType`: it never changes).
  static bool of(BuildContext context) =>
      context.getInheritedWidgetOfExactType<ResponsiveImageFlight>() != null;

  @override
  bool updateShouldNotify(ResponsiveImageFlight oldWidget) => false;
}

class _ResponsiveImageState extends ConsumerState<ResponsiveImage> {
  /// The CDN the choice was made with.
  ImageCdn? _cdn;

  /// What was chosen, and its provider; null before the first layout, and when the box has no
  /// width.
  ResolvedImage? _chosen;
  ImageProvider<Object>? _provider;

  /// Whether a choice (or an error) was made since the inputs last changed.
  bool _decided = false;

  /// An [ImageUrlError] of the builder or the buckets, and whether it was reported.
  ImageUrlError? _urlError;
  bool _urlErrorReported = false;

  /// Bumped by a retry: the `Image` is keyed by it, so it resolves again.
  int _retry = 0;

  double _dpr = 1;
  Size _view = Size.zero;
  bool _seenView = false;

  /// The view's size or pixel ratio changed since the last choice: the next one may grow.
  bool _viewChanged = false;

  double? get _aspect =>
      widget.aspectRatio ?? _ratioOf(widget.width, widget.height);

  @override
  void didUpdateWidget(ResponsiveImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final w = widget;
    if (oldWidget.source != w.source ||
        oldWidget.width != w.width ||
        oldWidget.height != w.height ||
        oldWidget.aspectRatio != w.aspectRatio ||
        oldWidget.resize != w.resize ||
        oldWidget.quality != w.quality ||
        oldWidget.format != w.format ||
        !listEquals(oldWidget.extra, w.extra) ||
        oldWidget.builder != w.builder ||
        oldWidget.buckets != w.buckets) {
      _reset();
    }
  }

  /// Forgets the choice: the next layout chooses from scratch.
  void _reset() {
    _chosen = null;
    _provider = null;
    _decided = false;
    _urlError = null;
    _urlErrorReported = false;
  }

  /// Whether [a] and [b] ask for the same URLs and make the same providers.
  static bool _sameRequests(ImageCdn a, ImageCdn b) =>
      a.builder == b.builder &&
      a.buckets == b.buckets &&
      a.format == b.format &&
      a.quality == b.quality &&
      a.maxPixelRatio == b.maxPixelRatio &&
      a.providerFactory == b.providerFactory &&
      a.webHtmlElementStrategy == b.webHtmlElementStrategy;

  void _retryLoad() {
    final provider = _provider;
    if (provider != null) unawaited(provider.evict());
    setState(() {
      _retry++;
      if (_urlError != null) _reset();
    });
  }

  /// Chooses what to fetch for a box [logical] logical pixels wide: at the first layout, from
  /// scratch after the inputs changed, and afterwards only a wider one, when the view changed or
  /// [ResponsiveImage.growWithBox] is on. In a hero flight it chooses once and never loads.
  void _choose(ImageCdn cdn, double logical, {required bool flight}) {
    final grow = _decided && !flight && (widget.growWithBox || _viewChanged);
    if (!flight) _viewChanged = false;
    if (_decided && !grow) return;
    final ResolvedImage? resolved;
    try {
      resolved = cdn.resolve(
        widget.source,
        logicalWidth: logical,
        devicePixelRatio: _dpr,
        aspectRatio: _aspect,
        resize: widget.resize,
        quality: widget.quality,
        format: widget.format,
        extra: widget.extra,
        builder: widget.builder,
        buckets: widget.buckets,
      );
    } on ImageUrlError catch (error, stack) {
      _urlError = error;
      _decided = true;
      if (!_urlErrorReported) {
        _urlErrorReported = true;
        reportUrlError(
          error,
          stack,
          'while building the URL of the image "${widget.source}"',
        );
      }
      return;
    }
    // A width that is not positive chooses nothing: the placeholder shows, nothing is fetched.
    if (resolved == null) return;
    _urlError = null;
    _decided = true;
    final current = _chosen;
    if (current != null && resolved.request.width <= current.request.width) {
      return;
    }
    if (resolved.builder is DirectUrlBuilder && !hasScheme(widget.source)) {
      warnUnconfigured(widget.source);
    }
    final provider = cdn.providerFor(resolved);
    _chosen = resolved;
    _provider = provider;
    ImageVariants.register(resolved, cdn.providerFactory, provider);
  }

  @override
  Widget build(BuildContext context) {
    final cdn = ref.watch(imageCdnProvider);
    final previous = _cdn;
    if (previous != null && !_sameRequests(previous, cdn)) _reset();
    _cdn = cdn;
    final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1.0;
    final view = MediaQuery.maybeSizeOf(context) ?? Size.zero;
    if (_seenView && (dpr != _dpr || view != _view)) _viewChanged = true;
    _seenView = true;
    _dpr = dpr;
    _view = view;
    final flight = ResponsiveImageFlight.of(context);
    final width = widget.width;
    if (width != null) {
      _choose(cdn, width, flight: flight);
      return _box(_visual(context, cdn, flight));
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        _choose(cdn, _measure(constraints), flight: flight);
        return _box(_visual(context, cdn, flight));
      },
    );
  }

  /// The logical width of the box: the maximum width when it is bounded; else the maximum height
  /// times the aspect ratio; else the view's width.
  double _measure(BoxConstraints constraints) {
    if (constraints.maxWidth.isFinite) return constraints.maxWidth;
    final ratio = _aspect;
    if (constraints.maxHeight.isFinite && ratio != null) {
      return constraints.maxHeight * ratio;
    }
    return _view.width;
  }

  /// The box: [ResponsiveImage.width] × [ResponsiveImage.height], else the aspect ratio, else
  /// what the parent gives. The content fills it, and an unbounded side collapses instead of
  /// throwing.
  Widget _box(Widget child) {
    final width = widget.width;
    final height = widget.height;
    final ratio = _aspect;
    final fill = LimitedBox(
      maxWidth: 0,
      maxHeight: 0,
      child: SizedBox.expand(child: child),
    );
    if (width != null && height != null) {
      return SizedBox(width: width, height: height, child: fill);
    }
    if (ratio != null) {
      final box = AspectRatio(aspectRatio: ratio, child: fill);
      return width != null ? SizedBox(width: width, child: box) : box;
    }
    return SizedBox(width: width, height: height, child: fill);
  }

  Widget _visual(BuildContext context, ImageCdn cdn, bool flight) {
    final error = _urlError;
    if (error != null) return _errorView(context, cdn, error);
    final chosen = _chosen;
    final provider = _provider;
    if (chosen == null || provider == null) return _placeholder(context, cdn);
    if (flight) {
      // An image in flight starts no load and asks for nothing: it shows the widest variant of its
      // source that is loaded, of any shape, else the placeholder. (What it chose is only a
      // registered provider: the box of a flight is the rectangle of the moment.)
      final stand = ImageVariants.bestLoaded(
        chosen,
        cdn.providerFactory,
        anyShape: true,
      );
      return stand == null ? _placeholder(context, cdn) : _standIn(stand);
    }
    return Image(
      key: ValueKey<int>(_retry),
      image: provider,
      fit: widget.fit,
      alignment: widget.alignment,
      gaplessPlayback: true,
      semanticLabel: widget.semanticLabel,
      excludeFromSemantics: widget.excludeFromSemantics,
      frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
        if (frame == null) return _loading(context, cdn, chosen, provider);
        final fade = widget.fadeIn ?? cdn.fadeIn;
        if (wasSynchronouslyLoaded || fade <= Duration.zero) return child;
        return _FadeIn(
          duration: fade,
          background: _loading(context, cdn, chosen, provider),
          child: child,
        );
      },
      errorBuilder: (context, error, stack) => _errorView(context, cdn, error),
    );
  }

  /// What shows while [provider] loads: the widest loaded variant of the same picture, else the
  /// placeholder.
  Widget _loading(
    BuildContext context,
    ImageCdn cdn,
    ResolvedImage chosen,
    ImageProvider<Object> provider,
  ) {
    final stand = ImageVariants.bestLoaded(
      chosen,
      cdn.providerFactory,
      except: provider,
    );
    return stand == null ? _placeholder(context, cdn) : _standIn(stand);
  }

  Widget _standIn(ImageProvider<Object> provider) => Image(
    image: provider,
    fit: widget.fit,
    alignment: widget.alignment,
    gaplessPlayback: true,
    excludeFromSemantics: true,
  );

  Widget _placeholder(BuildContext context, ImageCdn cdn) {
    final custom = widget.placeholder ?? cdn.placeholder;
    if (custom != null) return custom(context);
    return ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
    );
  }

  Widget _errorView(BuildContext context, ImageCdn cdn, Object error) {
    final custom = widget.errorBuilder ?? cdn.errorBuilder;
    if (custom != null) return custom(context, error, _retryLoad);
    final colors = Theme.of(context).colorScheme;
    return ColoredBox(
      color: colors.surfaceContainerHighest,
      child: Center(
        child: Icon(
          Icons.broken_image_outlined,
          color: colors.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// Fades [child] in over [background] for [duration], then shows [child] alone.
class _FadeIn extends StatefulWidget {
  const _FadeIn({
    required this.duration,
    required this.background,
    required this.child,
  });

  final Duration duration;
  final Widget background;
  final Widget child;

  @override
  State<_FadeIn> createState() => _FadeInState();
}

class _FadeInState extends State<_FadeIn> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
  );
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _controller
      ..addStatusListener((status) {
        if (status == AnimationStatus.completed && mounted && !_done) {
          setState(() => _done = true);
        }
      })
      ..forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_done) return widget.child;
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.background,
        FadeTransition(opacity: _controller, child: widget.child),
      ],
    );
  }
}
