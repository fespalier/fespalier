import 'dart:async';

import 'package:auth/app.g.dart';
import 'package:auth/auth_setup.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:flutter/material.dart';

/// The sign-in form, and a "Sign in with Keycloak" button when the app is built with
/// `--dart-define=OIDC_ISSUER=...`. Neither navigates: the sign-in guard moves the user.
class SignInPage extends HookConsumerWidget {
  const SignInPage({super.key, this.from});

  /// Where the guard that sent us here was going: the sign-in guard sends the user back to it.
  final String? from;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final form = SignInRoute.useForm(ref);
    final fields = form.fields;
    final browserError = useState<String?>(null);
    final expired = ref.watch(
      authSession.select(
        (s) => s is SignedOut && s.reason == SignOutReason.expired,
      ),
    );
    return Scaffold(
      appBar: AppBar(title: const Text('Sign in')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            if (expired) const Text('Your session expired. Sign in again.'),
            if (from != null) Text('Sign in to see $from'),
            TextField(
              controller: fields.username.controller,
              decoration: InputDecoration(
                labelText: 'User name',
                errorText: fields.username.error,
              ),
            ),
            TextField(
              controller: fields.password.controller,
              obscureText: true,
              decoration: InputDecoration(
                labelText: 'Password',
                errorText: fields.password.error,
              ),
            ),
            if (form.error case final error?) Text('$error'),
            // Null while the sign-in runs: the button is disabled.
            FilledButton(
              onPressed: form.onSubmit,
              child: Text(form.isPending ? 'Signing in...' : 'Sign in'),
            ),
            if (usesOidc) ...[
              // signIn is called straight from onPressed: a web popup is blocked otherwise.
              OutlinedButton(
                onPressed: () => unawaited(_browser(ref, browserError)),
                child: const Text('Sign in with Keycloak'),
              ),
              if (browserError.value case final text?) Text(text),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _browser(WidgetRef ref, ValueNotifier<String?> error) async {
    error.value = null;
    try {
      await ref.read(authSession.notifier).signIn(const BrowserSignIn());
    } on AuthCancelled {
      // The user closed the browser: nothing to say.
    } on Object catch (e) {
      error.value = '$e';
    }
  }
}
