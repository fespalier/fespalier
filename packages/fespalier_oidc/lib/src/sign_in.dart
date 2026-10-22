import 'package:fespalier_auth/fespalier_auth.dart';

/// Sign in in the browser (OpenID Connect) (since 0.9.0 in `fespalier_auth`; here since 0.21.0).
final class BrowserSignIn extends SignInRequest {
  /// A browser sign-in. [prompt] `login` forces the login form over a single-sign-on cookie.
  const BrowserSignIn({
    this.loginHint,
    this.prompt,
    this.parameters = const {},
  });

  /// Pre-fills the user name (`login_hint`).
  final String? loginHint;

  /// `login` shows the login form even when the browser has a session, `none` fails instead of
  /// showing it, `consent` and `select_account` ask again.
  final String? prompt;

  /// Extra authorization parameters, e.g. `{'kc_idp_hint': 'google', 'ui_locales': 'fr'}`.
  final Map<String, String> parameters;
}

/// A user name and a password, for a backend that takes them. `toString` hides both.
final class PasswordSignIn extends SignInRequest {
  /// The credentials the user typed.
  const PasswordSignIn({required this.username, required this.password});

  /// The account's user name or e-mail address.
  final String username;

  /// The password, as typed.
  final String password;

  @override
  String toString() => 'PasswordSignIn(<redacted>)';
}
