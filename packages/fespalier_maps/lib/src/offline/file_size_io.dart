import 'dart:io';

/// The size of the file at [path], or null when it is not there.
Future<int?> fileBytes(String path) async {
  final file = File(path);
  return await file.exists() ? file.length() : null;
}
