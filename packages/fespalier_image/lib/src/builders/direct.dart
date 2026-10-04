import '../builder.dart';
import '../request.dart';

/// No CDN (since 0.9.0): the source is the URL, fetched as it is and decoded at the width asked
/// for. The default of an app that has not configured one.
final class DirectUrlBuilder extends ImageUrlBuilder {
  /// The source as it is.
  const DirectUrlBuilder();

  @override
  String get name => 'direct';

  @override
  bool get resizes => false;

  @override
  String url(ImageRequest request) => request.source;

  @override
  bool operator ==(Object other) => other is DirectUrlBuilder;

  @override
  int get hashCode => (DirectUrlBuilder).hashCode;

  @override
  String toString() => 'DirectUrlBuilder()';
}
