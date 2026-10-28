/// One challenge of a `WWW-Authenticate` header (RFC 9110, section 11.6.1) (since 0.25.0): its
/// [scheme], lower-cased, and either its [params] or its [token68].
///
/// ```dart
/// final challenges = parseChallenges(response.headers['www-authenticate'] ?? '');
/// final bearer = challenges.where((c) => c.scheme == 'bearer').firstOrNull;
/// final error = bearer?.params['error'];
/// ```
final class HttpChallenge {
  /// A challenge for [scheme] (lower-cased by [parseChallenges]) with [params] or a [token68].
  const HttpChallenge(
    this.scheme, {
    this.params = const <String, String>{},
    this.token68,
  });

  /// The authentication scheme, lower-cased: `bearer`, `dpop`, `basic`.
  final String scheme;

  /// The parameters, by lower-cased name, unquoted and unescaped. A name given twice keeps its
  /// first value.
  final Map<String, String> params;

  /// The single token a scheme may carry instead of parameters; null when it has parameters or
  /// nothing.
  final String? token68;

  @override
  bool operator ==(Object other) =>
      other is HttpChallenge &&
      other.scheme == scheme &&
      other.token68 == token68 &&
      other.params.length == params.length &&
      params.entries.every((e) => other.params[e.key] == e.value);

  @override
  int get hashCode => Object.hash(
    scheme,
    token68,
    Object.hashAllUnordered(
      params.entries.map((e) => Object.hash(e.key, e.value)),
    ),
  );

  @override
  String toString() => 'HttpChallenge($scheme, $params)';
}

/// The challenges of a `WWW-Authenticate` value (since 0.25.0), in order: several challenges in
/// one header, or several headers joined with `, ` (as a `TransportResponse` joins them).
///
/// Schemes and parameter names are case-insensitive, so both are lower-cased; values are taken
/// as tokens or quoted strings (a backslash escapes the next character). It never throws: what
/// does not parse is skipped up to the next comma, and an unterminated quoted string runs to the
/// end.
List<HttpChallenge> parseChallenges(String header) =>
    _ChallengeParser(header).parse();

/// The RFC 9470 error a resource server answers when the user's authentication is too weak or
/// too old for the request: `insufficient_user_authentication`.
const String insufficientUserAuthentication =
    'insufficient_user_authentication';

/// What a resource server asks of the user's authentication before it answers (RFC 9470, step-up
/// authentication) (since 0.25.0): a stronger method ([acrValues]), a recent one ([maxAge]), or
/// both. The `StepUp` verdict carries it to `AuthBackend.stepUp`, and an app's re-proof page
/// passes one to `AuthSessionNotifier.stepUp`.
///
/// No value of it is secret: `toString` shows them.
final class StepUpChallenge {
  /// A step-up to [acrValues] (most preferred first; empty: any) within [maxAge] (null: any age).
  /// With neither, the user re-proves their authentication as it is.
  const StepUpChallenge({this.acrValues = const <String>[], this.maxAge});

  /// The step-up an RFC 9470 refusal asks for, or null when [statusCode] and [headers] are not
  /// one: a 401 whose `www-authenticate` header (lower-case name, as a `TransportResponse` has
  /// it) has a challenge of one of [schemes] with `error="insufficient_user_authentication"`.
  ///
  /// `acr_values` is space-separated; `max_age` is a whole number of seconds (anything else is
  /// ignored). The first matching challenge wins.
  static StepUpChallenge? fromResponse(
    int statusCode,
    Map<String, String> headers, {
    Set<String> schemes = const {'bearer', 'dpop'},
  }) {
    if (statusCode != 401) return null;
    final header = headers['www-authenticate'];
    if (header == null) return null;
    for (final challenge in parseChallenges(header)) {
      if (!schemes.contains(challenge.scheme)) continue;
      final error = challenge.params['error']?.trim().toLowerCase();
      if (error != insufficientUserAuthentication) continue;
      final acr = challenge.params['acr_values'];
      final age = int.tryParse(challenge.params['max_age']?.trim() ?? '');
      return StepUpChallenge(
        acrValues: acr == null
            ? const <String>[]
            : List<String>.unmodifiable(
                acr.split(' ').where((value) => value.isNotEmpty),
              ),
        maxAge: age == null || age < 0 ? null : Duration(seconds: age),
      );
    }
    return null;
  }

  /// The authentication context classes the server accepts, most preferred first (`acr_values`);
  /// empty when it named none.
  final List<String> acrValues;

  /// How long ago the user may have authenticated (`max_age`); null when the server said nothing.
  final Duration? maxAge;

  @override
  bool operator ==(Object other) =>
      other is StepUpChallenge &&
      other.maxAge == maxAge &&
      other.acrValues.length == acrValues.length &&
      Iterable<int>.generate(
        acrValues.length,
      ).every((i) => other.acrValues[i] == acrValues[i]);

  @override
  int get hashCode => Object.hash(Object.hashAll(acrValues), maxAge);

  @override
  String toString() =>
      'StepUpChallenge(acr: ${acrValues.join(' ')}, maxAge: ${maxAge?.inSeconds})';
}

/// A cursor over one header value.
final class _ChallengeParser {
  _ChallengeParser(this._text);

  final String _text;
  int _at = 0;

  static const String _tcharSymbols = "!#\$%&'*+-.^_`|~";
  static const String _token68Symbols = '-._~+/';

  bool get _done => _at >= _text.length;

  String get _peek => _text[_at];

  static bool _isAlnum(String c) {
    final u = c.codeUnitAt(0);
    return (u >= 0x30 && u <= 0x39) ||
        (u >= 0x41 && u <= 0x5a) ||
        (u >= 0x61 && u <= 0x7a);
  }

  static bool _isTchar(String c) => _isAlnum(c) || _tcharSymbols.contains(c);

  void _skipSpace() {
    while (!_done && (_peek == ' ' || _peek == '\t')) {
      _at++;
    }
  }

  /// Spaces and empty list elements (`, ,`).
  void _skipSeparators() {
    while (!_done && (_peek == ' ' || _peek == '\t' || _peek == ',')) {
      _at++;
    }
  }

  String _token() {
    final start = _at;
    while (!_done && _isTchar(_peek)) {
      _at++;
    }
    return _text.substring(start, _at);
  }

  /// Skips to the next comma (not past it).
  void _skipToComma() {
    while (!_done && _peek != ',') {
      if (_peek == '"') {
        _quoted();
      } else {
        _at++;
      }
    }
  }

  String _quoted() {
    _at++; // the opening quote
    final out = StringBuffer();
    while (!_done) {
      final c = _peek;
      if (c == r'\' && _at + 1 < _text.length) {
        out.write(_text[_at + 1]);
        _at += 2;
      } else if (c == '"') {
        _at++;
        return out.toString();
      } else {
        out.write(c);
        _at++;
      }
    }
    return out.toString();
  }

  /// Whether an auth-param (`name BWS "=" BWS value`) starts here, without moving.
  bool _paramAhead() {
    final saved = _at;
    try {
      if (_token().isEmpty) return false;
      _skipSpace();
      if (_done || _peek != '=') return false;
      _at++;
      _skipSpace();
      return !_done && (_peek == '"' || _isTchar(_peek)) && _peek != '=';
    } finally {
      _at = saved;
    }
  }

  List<HttpChallenge> parse() {
    final challenges = <HttpChallenge>[];
    while (true) {
      _skipSeparators();
      if (_done) return challenges;
      final scheme = _token();
      if (scheme.isEmpty) {
        _at++;
        _skipToComma();
        continue;
      }
      _skipSpace();
      if (_done || _peek == ',') {
        challenges.add(HttpChallenge(scheme.toLowerCase()));
        continue;
      }
      if (_paramAhead()) {
        challenges.add(HttpChallenge(scheme.toLowerCase(), params: _params()));
        continue;
      }
      final start = _at;
      while (!_done && (_isAlnum(_peek) || _token68Symbols.contains(_peek))) {
        _at++;
      }
      while (!_done && _peek == '=') {
        _at++;
      }
      final token68 = _text.substring(start, _at);
      _skipSpace();
      if (token68.isEmpty || (!_done && _peek != ',')) {
        // Neither parameters nor a token68: skip this element.
        _skipToComma();
        challenges.add(HttpChallenge(scheme.toLowerCase()));
        continue;
      }
      challenges.add(HttpChallenge(scheme.toLowerCase(), token68: token68));
    }
  }

  /// The parameters of one challenge: until the end, or a list element that is not a parameter
  /// (the next challenge's scheme).
  Map<String, String> _params() {
    final params = <String, String>{};
    while (true) {
      final name = _token().toLowerCase();
      _skipSpace();
      _at++; // "=", which _paramAhead saw
      _skipSpace();
      final value = _peek == '"' ? _quoted() : _token();
      params.putIfAbsent(name, () => value);
      _skipSpace();
      if (!_done && _peek != ',') _skipToComma();
      // A comma: the next element is a parameter of this challenge, or the next challenge.
      final saved = _at;
      _skipSeparators();
      if (_done) return Map<String, String>.unmodifiable(params);
      if (!_paramAhead()) {
        _at = saved;
        return Map<String, String>.unmodifiable(params);
      }
    }
  }
}
