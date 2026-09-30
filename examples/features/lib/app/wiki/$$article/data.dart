import 'package:fespalier/fespalier.dart';

/// A catch-all can key data: the generated provider is keyed by the path.
Future<String> data(Ref ref, {required List<String> article}) async =>
    'Article ${article.join('/')}';
