import '../builder.dart';
import '../request.dart';

/// Images that come already sized (since 0.9.0): the source is a srcset,
/// `a.webp 256w, b.webp 640w`, whose URLs (signed by the backend, if they need to be) are used
/// as they are.
///
/// This is the way to use a CDN that signs its URLs with a secret the app must not hold: the
/// backend returns the photo's URLs, one per width, with the product.
final class SrcsetUrlBuilder extends ImageUrlBuilder {
  /// Reads the source as a srcset.
  const SrcsetUrlBuilder();

  /// The candidates of [srcset], width to URL.
  ///
  /// Whitespace and commas between candidates are skipped; a candidate is a URL (a run of
  /// non-whitespace, so `https://x/a,b.jpg` keeps its comma) and a `w` descriptor up to the next
  /// comma. A repeated width keeps the first. Throws an [ImageUrlError] when [srcset] is empty
  /// or a candidate has no `w` descriptor.
  static Map<int, String> parse(String srcset) {
    final result = <int, String>{};
    final n = srcset.length;
    var i = 0;
    bool space(int at) => srcset.codeUnitAt(at) <= 0x20;
    while (true) {
      while (i < n && (space(i) || srcset[i] == ',')) {
        i++;
      }
      if (i >= n) break;
      final start = i;
      while (i < n && !space(i)) {
        i++;
      }
      final url = srcset.substring(start, i);
      if (url.endsWith(',')) {
        // A URL with a trailing comma has no descriptor.
        throw _noDescriptor(url.replaceFirst(RegExp(r',+$'), ''));
      }
      while (i < n && space(i)) {
        i++;
      }
      final descriptorStart = i;
      while (i < n && srcset[i] != ',') {
        i++;
      }
      final descriptor = srcset.substring(descriptorStart, i).trim();
      final match = RegExp(r'^(\d+)w$').firstMatch(descriptor);
      final width = match == null ? null : int.tryParse(match.group(1)!);
      if (width == null || width < 1) {
        throw _noDescriptor(descriptor.isEmpty ? url : '$url $descriptor');
      }
      result.putIfAbsent(width, () => url);
    }
    if (result.isEmpty) {
      throw ImageUrlError('SrcsetUrlBuilder: the srcset is empty');
    }
    return result;
  }

  static ImageUrlError _noDescriptor(String candidate) => ImageUrlError(
    'SrcsetUrlBuilder: "$candidate" in the srcset has no width descriptor, '
    'like "photo-640.webp 640w"',
  );

  /// A srcset from [urls]: `{256: 'a', 640: 'b'}` is `a 256w, b 640w`, in increasing width.
  static String of(Map<int, String> urls) {
    final widths = urls.keys.toList()..sort();
    return widths.map((w) => '${urls[w]} ${w}w').join(', ');
  }

  @override
  String get name => 'srcset';

  /// The srcset's widths, increasing.
  @override
  List<int> widthsOf(String source) => parse(source).keys.toList()..sort();

  /// The candidate of exactly [ImageRequest.width] (it came from [widthsOf]); else the smallest
  /// wider one, else the widest.
  @override
  String url(ImageRequest request) {
    final candidates = parse(request.source);
    final exact = candidates[request.width];
    if (exact != null) return exact;
    final widths = candidates.keys.toList()..sort();
    for (final width in widths) {
      if (width >= request.width) return candidates[width]!;
    }
    return candidates[widths.last]!;
  }

  @override
  bool operator ==(Object other) => other is SrcsetUrlBuilder;

  @override
  int get hashCode => (SrcsetUrlBuilder).hashCode;

  @override
  String toString() => 'SrcsetUrlBuilder()';
}
