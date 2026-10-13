import 'dart:convert';

import 'package:fespalier/fespalier.dart' show FieldErrors;

/// Turns the decoded body of a server's answer into the [FieldErrors] it describes, or null when the
/// body is not that shape. Keys are the server's, before [fieldErrorsOf] renames them.
///
/// The body is always a JSON object (a `Map<String, Object?>`): [fieldErrorsOf] has already read a
/// `String` or bytes and refused everything that is not one.
typedef FieldErrorsDecoder = FieldErrors? Function(Object? body);

/// The shapes servers send validation errors in (since 0.9.0).
///
/// Each decoder asks for its exact shape and returns null for anything else, so a body that is not
/// a validation error is never read as one. Each field gets the **first** message the server gave
/// it, because [FieldErrors] holds one text per field.
abstract final class FieldErrorsDecoders {
  /// [problemDetails], [errorsMap], [jsonApi], [fastApi], then [flatMap]: the first that matches.
  static FieldErrors? standard(Object? body) =>
      problemDetails(body) ??
      errorsMap(body) ??
      jsonApi(body) ??
      fastApi(body) ??
      flatMap(body);

  /// RFC 9457 `errors: [{detail, pointer}]`, RFC 7807 `invalid-params: [{name, reason}]`, and
  /// `errors: [{field, message | defaultMessage | detail}]` (Spring and others).
  ///
  /// A JSON Pointer (`#/profile/color`, `/profile/color`) becomes a dotted path
  /// (`profile.color`). An entry with no pointer and no field is the message of the whole input. An
  /// `errors` list whose entries carry a `source` is JSON:API's, not this decoder's.
  static FieldErrors? problemDetails(Object? body) {
    final map = _asMap(body);
    if (map == null) return null;
    final found = _Found();
    final errors = map['errors'];
    if (errors is List<Object?>) {
      for (final entry in errors) {
        final item = _asMap(entry);
        if (item == null) continue;
        if (item.containsKey('source')) return null;
        final text =
            _text(item['detail']) ??
            _text(item['message']) ??
            _text(item['defaultMessage']);
        if (text == null) continue;
        final pointer = item['pointer'];
        final field = item['field'];
        found.add(
          pointer is String
              ? _pointerPath(pointer)
              : field is String
              ? field
              : '',
          text,
        );
      }
    }
    final params = map['invalid-params'];
    if (params is List<Object?>) {
      for (final entry in params) {
        final item = _asMap(entry);
        if (item == null) continue;
        final name = item['name'];
        final reason = _text(item['reason']);
        if (name is String && reason != null) found.add(name, reason);
      }
    }
    return found.build();
  }

  /// `errors: {field: [message] | message}`: ASP.NET Core's ValidationProblemDetails, Laravel, Rails.
  ///
  /// A `""` or `$` key is the message of the whole input, and a leading `$.` is dropped from a key
  /// (ASP.NET's JSON paths).
  static FieldErrors? errorsMap(Object? body) {
    final errors = _asMap(_asMap(body)?['errors']);
    if (errors == null) return null;
    final found = _Found();
    for (final entry in errors.entries) {
      final text = _firstText(entry.value);
      if (text == null) continue;
      var key = entry.key;
      if (key == r'$') {
        key = '';
      } else if (key.startsWith(r'$.')) {
        key = key.substring(2);
      }
      found.add(key, text);
    }
    return found.build();
  }

  /// JSON:API `errors: [{source: {pointer: '/data/attributes/name'}, detail | title}]`.
  ///
  /// `/data/attributes/` and `/data/relationships/` are dropped from the pointer. An entry with no
  /// `source` is the message of the whole input.
  static FieldErrors? jsonApi(Object? body) {
    final errors = _asMap(body)?['errors'];
    if (errors is! List<Object?>) return null;
    final found = _Found();
    for (final entry in errors) {
      final item = _asMap(entry);
      if (item == null) continue;
      final text = _text(item['detail']) ?? _text(item['title']);
      if (text == null) continue;
      final pointer = _asMap(item['source'])?['pointer'];
      found.add(pointer is String ? _jsonApiKey(pointer) : '', text);
    }
    return found.build();
  }

  /// FastAPI and Pydantic `detail: [{loc: ['body', 'age'], msg}]`.
  ///
  /// A leading `body`, `query`, `path`, `header` or `cookie` is dropped from `loc`, and what is left
  /// is joined with dots. `loc: ['body']` is the message of the whole input.
  static FieldErrors? fastApi(Object? body) {
    final detail = _asMap(body)?['detail'];
    if (detail is! List<Object?>) return null;
    final found = _Found();
    for (final entry in detail) {
      final item = _asMap(entry);
      if (item == null) continue;
      final text = _text(item['msg']);
      if (text == null) continue;
      final loc = item['loc'];
      found.add(loc is List<Object?> ? _locPath(loc) : '', text);
    }
    return found.build();
  }

  /// Django REST framework: `{field: [message], non_field_errors: [message]}`.
  ///
  /// Only when every value is a string or a list of strings, and none of `type`, `title`, `status`,
  /// `errors` or `detail` is a key, so `{"detail": "Not found."}` never matches. A `message` or
  /// `error` that is a plain string is a generic envelope, not a field called `message`: it does
  /// not match either (a field's own `message` is a list, as DRF writes it). `non_field_errors` is
  /// the message of the whole input.
  static FieldErrors? flatMap(Object? body) {
    final map = _asMap(body);
    if (map == null || map.isEmpty) return null;
    for (final key in const ['type', 'title', 'status', 'errors', 'detail']) {
      if (map.containsKey(key)) return null;
    }
    for (final key in const ['message', 'error']) {
      if (map[key] is String) return null;
    }
    final found = _Found();
    for (final entry in map.entries) {
      final value = entry.value;
      final String text;
      if (value is String && value.isNotEmpty) {
        text = value;
      } else if (value is List<Object?> &&
          value.isNotEmpty &&
          value.every((v) => v is String && v.isNotEmpty)) {
        text = value.first! as String;
      } else {
        return null;
      }
      found.add(entry.key == 'non_field_errors' ? '' : entry.key, text);
    }
    return found.build();
  }
}

/// How a server's field key becomes the name of a field of the form's record (since 0.9.0; the
/// form is in `fespalier_forms`, see https://github.com/fespalier/fespalier/blob/main/docs/forms.md).
abstract final class FieldNames {
  /// The key as the server sent it (after the decoder made a path of it: `address.street`).
  static String asIs(String key) => key;

  /// `first_name`, `FirstName` and `first-name` become `firstName`, each dotted segment on its own.
  ///
  /// It only changes case and separators: `nick_name` becomes `nickName`, not `nickname`. When the
  /// names differ by more than that, map them yourself.
  static String camelCase(String key) =>
      key.split('.').map(_camelSegment).join('.');
}

/// The [FieldErrors] that a [status] answer with [body] describes, or null (since 0.9.0): null
/// unless [status] is in [statuses] and [decoder] recognises [body] (a JSON map, or a `String` or
/// bytes holding one). A 422 whose body says what is wrong without naming fields (a string `detail`
/// or `message`) is a [FieldErrors] with only a message.
///
/// The keys of the result are [fieldName] of the server's. When two keys end up with the same name,
/// the first wins.
FieldErrors? fieldErrorsOf(
  int? status,
  Object? body, {
  FieldErrorsDecoder decoder = FieldErrorsDecoders.standard,
  String Function(String key) fieldName = FieldNames.asIs,
  Set<int> statuses = const {400, 422},
}) {
  if (status == null || !statuses.contains(status)) return null;
  final map = _decodeBody(body);
  if (map == null) return null;
  final decoded = decoder(map);
  if (decoded != null && !decoded.isEmpty) {
    final fields = <String, String>{};
    for (final entry in decoded.fields.entries) {
      fields.putIfAbsent(fieldName(entry.key), () => entry.value);
    }
    return FieldErrors(fields, message: decoded.message);
  }
  // A 400 without field errors is usually a bug of the client, which should be seen: only a 422
  // ("understood, but not acceptable") says its message belongs to the person.
  if (status == 422) {
    final text = _text(map['detail']) ?? _text(map['message']);
    if (text != null) return FieldErrors(const {}, message: text);
  }
  return null;
}

/// What a decoder collects: a text per field, and the text for the input as a whole.
final class _Found {
  final Map<String, String> _fields = {};
  String? _message;

  /// Adds [text] under [key], or as the message when [key] is empty. The first text wins.
  void add(String key, String text) {
    if (key.isEmpty) {
      _message ??= text;
    } else {
      _fields.putIfAbsent(key, () => text);
    }
  }

  FieldErrors? build() => _fields.isEmpty && _message == null
      ? null
      : FieldErrors(_fields, message: _message);
}

/// [body] as a JSON object, or null: a `String` or bytes are decoded first.
Map<String, Object?>? _decodeBody(Object? body) {
  var value = body;
  try {
    if (value is List<int>) value = utf8.decode(value);
    if (value is String) value = jsonDecode(value);
  } on FormatException {
    return null;
  }
  return _asMap(value);
}

/// [value] as a map with string keys, or null.
Map<String, Object?>? _asMap(Object? value) {
  if (value is! Map<Object?, Object?>) return null;
  return {
    for (final entry in value.entries)
      if (entry.key case final String key) key: entry.value,
  };
}

/// [value] when it is a string with something in it.
String? _text(Object? value) =>
    value is String && value.trim().isNotEmpty ? value : null;

/// The first text of a string, or of a list that has one.
String? _firstText(Object? value) {
  if (value is List<Object?>) {
    for (final item in value) {
      final text = _text(item);
      if (text != null) return text;
    }
    return null;
  }
  return _text(value);
}

/// A JSON Pointer (RFC 6901), in its string or its URI fragment form (`#/a/b`), as a dotted path.
/// The root (`''`, `#`, `/`) is the empty string.
String _pointerPath(String pointer) {
  var path = pointer;
  if (path.startsWith('#')) {
    path = path.substring(1);
    try {
      path = Uri.decodeComponent(path);
    } on Object {
      // Not percent-encoded after all: keep it as it is.
    }
  }
  if (path.startsWith('/')) path = path.substring(1);
  if (path.isEmpty) return '';
  return path
      .split('/')
      .map((s) => s.replaceAll('~1', '/').replaceAll('~0', '~'))
      .join('.');
}

String _jsonApiKey(String pointer) {
  final path = _pointerPath(pointer);
  for (final prefix in const ['data.attributes.', 'data.relationships.']) {
    if (path.startsWith(prefix)) return path.substring(prefix.length);
  }
  return path == 'data' ? '' : path;
}

String _locPath(List<Object?> loc) {
  final parts = [for (final part in loc) '$part'];
  if (parts.isNotEmpty &&
      const {
        'body',
        'query',
        'path',
        'header',
        'cookie',
      }.contains(parts.first)) {
    parts.removeAt(0);
  }
  return parts.join('.');
}

final RegExp _separators = RegExp(r'[_\-\s]+');
final RegExp _leadingAcronym = RegExp(r'^([A-Z]+)(?=[A-Z][a-z])');

String _camelSegment(String segment) {
  final words = segment.split(_separators).where((w) => w.isNotEmpty).toList();
  if (words.isEmpty) return segment;
  final out = StringBuffer();
  for (var i = 0; i < words.length; i++) {
    var word = words[i];
    // ALL CAPS is one word written loudly: `ID` is `id`, `FIRST_NAME` is `firstName`.
    if (word.length > 1 &&
        word == word.toUpperCase() &&
        word != word.toLowerCase()) {
      word = word.toLowerCase();
    }
    if (i == 0) {
      final acronym = _leadingAcronym.firstMatch(word);
      if (acronym != null) {
        // `HTTPServer` is `httpServer`.
        out.write(acronym[1]!.toLowerCase());
        out.write(word.substring(acronym[1]!.length));
      } else {
        out.write(word[0].toLowerCase() + word.substring(1));
      }
    } else {
      out.write(word[0].toUpperCase() + word.substring(1));
    }
  }
  return out.toString();
}
