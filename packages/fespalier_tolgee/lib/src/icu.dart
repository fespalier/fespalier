import 'package:intl/intl.dart';

/// A malformed ICU message.
final class IcuException implements Exception {
  /// A problem at [offset] of the message.
  const IcuException(this.message, this.offset);

  /// What is wrong.
  final String message;

  /// Where, in characters.
  final int offset;

  @override
  String toString() => 'IcuException: $message (at $offset)';
}

/// A parsed piece of a message.
sealed class IcuNode {
  const IcuNode();

  /// Appends the text of this node to [out]; [hash] is what `#` shows.
  void write(
    StringBuffer out,
    Map<String, Object?> args,
    String locale,
    num? hash,
  );
}

final class _Text extends IcuNode {
  const _Text(this.text);
  final String text;

  @override
  void write(
    StringBuffer out,
    Map<String, Object?> args,
    String locale,
    num? hash,
  ) => out.write(text);
}

final class _Hash extends IcuNode {
  const _Hash();

  @override
  void write(
    StringBuffer out,
    Map<String, Object?> args,
    String locale,
    num? hash,
  ) => out.write(hash == null ? '#' : _show(hash));
}

final class _Arg extends IcuNode {
  const _Arg(this.name);
  final String name;

  @override
  void write(
    StringBuffer out,
    Map<String, Object?> args,
    String locale,
    num? hash,
  ) {
    if (!args.containsKey(name)) {
      out.write('{$name}');
      return;
    }
    out.write(_show(args[name]));
  }
}

final class _Choice extends IcuNode {
  const _Choice(this.name, this.kind, this.offset, this.cases);
  final String name;

  /// `plural`, `selectordinal` or `select`.
  final String kind;
  final num offset;
  final Map<String, List<IcuNode>> cases;

  @override
  void write(
    StringBuffer out,
    Map<String, Object?> args,
    String locale,
    num? hash,
  ) {
    final value = args[name];
    List<IcuNode>? chosen;
    var inner = hash;
    if (kind == 'select') {
      chosen = cases[value is Enum ? value.name : '$value'] ?? cases['other'];
    } else {
      final n = value is num ? value : num.tryParse('$value') ?? 0;
      inner = n - offset;
      chosen = cases['=${_show(n)}'];
      chosen ??= cases[_category(inner, locale)] ?? cases['other'];
    }
    if (chosen == null) return;
    for (final node in chosen) {
      node.write(out, args, locale, inner);
    }
  }

  String _category(num n, String locale) => Intl.pluralLogic<String>(
    n,
    zero: cases.containsKey('zero') ? 'zero' : null,
    one: cases.containsKey('one') ? 'one' : null,
    two: cases.containsKey('two') ? 'two' : null,
    few: cases.containsKey('few') ? 'few' : null,
    many: cases.containsKey('many') ? 'many' : null,
    other: 'other',
    useExplicitNumberCases: false,
    locale: locale.replaceAll('-', '_'),
  );
}

String _show(Object? value) {
  if (value == null) return '';
  if (value is double && value.isFinite && value == value.truncateToDouble()) {
    return value.toInt().toString();
  }
  return '$value';
}

/// The nodes of [message]. Throws an [IcuException] when it is malformed.
List<IcuNode> parseIcu(String message) => _Parser(message).parseAll();

/// Formats already parsed [nodes] with [args] for [locale] (plural rules).
String formatNodes(
  List<IcuNode> nodes,
  Map<String, Object?> args,
  String locale,
) {
  final out = StringBuffer();
  for (final node in nodes) {
    node.write(out, args, locale, null);
  }
  return out.toString();
}

/// [message] formatted with [args] for [locale].
///
/// Throws an [IcuException] when it is malformed.
String formatIcu(String message, Map<String, Object?> args, String locale) =>
    formatNodes(parseIcu(message), args, locale);

final class _Parser {
  _Parser(this.s);
  final String s;
  var i = 0;

  List<IcuNode> parseAll() {
    final nodes = _parse(inChoice: false);
    if (i < s.length) throw IcuException('Unexpected "}"', i);
    return nodes;
  }

  /// Parses to the end, or to an unmatched `}` when [inChoice] (not consumed).
  List<IcuNode> _parse({required bool inChoice}) {
    final nodes = <IcuNode>[];
    final text = StringBuffer();
    void flush() {
      if (text.isNotEmpty) {
        nodes.add(_Text(text.toString()));
        text.clear();
      }
    }

    while (i < s.length) {
      final c = s[i];
      if (c == "'") {
        final next = i + 1 < s.length ? s[i + 1] : '';
        if (next == "'") {
          text.write("'");
          i += 2;
        } else if (next == '{' || next == '}' || (inChoice && next == '#')) {
          // Quoted text runs to the next single quote (a doubled one is a quote).
          i++;
          while (i < s.length) {
            if (s[i] == "'") {
              if (i + 1 < s.length && s[i + 1] == "'") {
                text.write("'");
                i += 2;
                continue;
              }
              i++;
              break;
            }
            text.write(s[i]);
            i++;
          }
        } else {
          text.write("'");
          i++;
        }
      } else if (c == '{') {
        flush();
        nodes.add(_argument());
      } else if (c == '}') {
        if (inChoice) break;
        throw IcuException('Unexpected "}"', i);
      } else if (c == '#' && inChoice) {
        flush();
        nodes.add(const _Hash());
        i++;
      } else {
        text.write(c);
        i++;
      }
    }
    flush();
    return nodes;
  }

  void _space() {
    while (i < s.length && ' \t\r\n'.contains(s[i])) {
      i++;
    }
  }

  String _word() {
    final start = i;
    while (i < s.length && !' \t\r\n,{}'.contains(s[i])) {
      i++;
    }
    if (i == start) throw IcuException('Expected a name', i);
    return s.substring(start, i);
  }

  IcuNode _argument() {
    i++; // {
    _space();
    final name = _word();
    _space();
    if (i >= s.length) throw IcuException('Unclosed "{"', i);
    if (s[i] == '}') {
      i++;
      return _Arg(name);
    }
    if (s[i] != ',') throw IcuException('Expected "," or "}"', i);
    i++;
    _space();
    final kind = _word();
    _space();
    if (i < s.length && s[i] == '}') {
      if (kind == 'plural' || kind == 'select') {
        throw IcuException('A $kind needs cases', i);
      }
      // {n, number}: a typed argument, shown as it is.
      i++;
      return _Arg(name);
    }
    if (i >= s.length || s[i] != ',') throw IcuException('Expected ","', i);
    i++;
    if (kind == 'selectordinal') {
      // intl has no ordinal rules: better shown as written than with cardinal ones.
      throw IcuException('selectordinal is not supported', i);
    }
    if (kind != 'plural' && kind != 'select') {
      // {d, date, short} and the like: shown as they are.
      while (i < s.length && s[i] != '}') {
        i++;
      }
      if (i >= s.length) throw IcuException('Unclosed "{"', i);
      i++;
      return _Arg(name);
    }
    num offset = 0;
    final cases = <String, List<IcuNode>>{};
    _space();
    if (s.startsWith('offset:', i)) {
      i += 'offset:'.length;
      _space();
      final n = num.tryParse(_word());
      if (n == null) throw IcuException('Bad offset', i);
      offset = n;
    }
    while (true) {
      _space();
      if (i >= s.length) throw IcuException('Unclosed "{"', i);
      if (s[i] == '}') {
        i++;
        break;
      }
      final selector = _word();
      _space();
      if (i >= s.length || s[i] != '{') throw IcuException('Expected "{"', i);
      i++;
      cases[selector] = _parse(inChoice: true);
      if (i >= s.length) throw IcuException('Unclosed "{"', i);
      i++; // }
    }
    if (!cases.containsKey('other')) {
      throw IcuException('A $kind needs an "other" case', i);
    }
    return _Choice(name, kind, offset, cases);
  }
}
