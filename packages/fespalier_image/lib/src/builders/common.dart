import '../builder.dart';

/// Whether [source] starts with a URL scheme (`https:`), so it is a URL and not a path.
bool hasScheme(String source) => _scheme.hasMatch(source);

final RegExp _scheme = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*:');

/// [baseUrl] without its trailing slashes, after checking that it is an absolute http or https
/// URL (M3). [builder] is the class name the message starts with.
String checkBaseUrl(String builder, String baseUrl) {
  final uri = Uri.tryParse(baseUrl);
  if (uri == null ||
      (uri.scheme != 'http' && uri.scheme != 'https') ||
      uri.host.isEmpty) {
    throw ImageUrlError(
      '$builder: baseUrl "$baseUrl" is not an absolute http or https URL',
    );
  }
  return baseUrl.replaceFirst(RegExp(r'/+$'), '');
}
