import '../builder.dart';
import '../request.dart';

/// A URL template (since 0.9.0): `{source}`, `{width}`, `{height}` (0 when not set), `{quality}`
/// and `{format}` (`webp`, `jpg`, `png`, `avif` or `auto`) are replaced; for a CDN whose URLs
/// are a path and a query.
///
/// ```dart
/// const TemplateUrlBuilder('https://cdn.example.com/{source}?w={width}&q={quality}')
/// ```
final class TemplateUrlBuilder extends ImageUrlBuilder {
  /// The template, `https://cdn.example.com/{source}?w={width}`.
  const TemplateUrlBuilder(
    this.template, {
    this.quality = 80,
    this.name = 'template',
  });

  /// The template.
  final String template;

  /// What `{quality}` is when the request has none.
  final int quality;

  @override
  final String name;

  /// True when the template has `{width}`.
  @override
  bool get resizes => template.contains('{width}');

  static final RegExp _placeholder = RegExp(r'\{([a-z]+)\}');

  @override
  String url(ImageRequest request) =>
      template.replaceAllMapped(_placeholder, (match) {
        final placeholder = match.group(1);
        return switch (placeholder) {
          'source' => request.source,
          'width' => '${request.width}',
          'height' => '${request.height ?? 0}',
          'quality' => '${request.quality ?? quality}',
          'format' => request.format.extension,
          _ => throw ImageUrlError(
            'TemplateUrlBuilder: unknown placeholder {$placeholder} in '
            '"$template"; the placeholders are {source}, {width}, {height}, '
            '{quality} and {format}',
          ),
        };
      });

  @override
  bool operator ==(Object other) =>
      other is TemplateUrlBuilder &&
      other.template == template &&
      other.quality == quality &&
      other.name == name;

  @override
  int get hashCode => Object.hash(template, quality, name);

  @override
  String toString() => 'TemplateUrlBuilder($template)';
}
