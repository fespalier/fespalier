import 'package:fespalier/fespalier.dart';
import 'package:live/ask.dart';
import 'package:live/wiring.dart';

/// Run before [answer]: a question needs words. The stream never starts without them.
FieldErrors? answerValidate(String input) => input.trim().isEmpty
    ? const FieldErrors({'question': 'Type a question first'})
    : null;

/// A streaming action: the server's answer to `input`, each item the text so far.
///
/// `AskRoute.useAnswer(ref)` gives the page the state (running with the latest text, then done, failed
/// or cancelled) and `cancel()`. Leaving the page, or **Stop**, cancels the subscription, which aborts
/// the request (lib/ask.dart): the server sees the client leave and stops writing.
Stream<String> answer(Ref ref, {required String input}) => streamAnswer(
  ref.read(liveTransport),
  ref.read(liveOrigin).resolve('ask'),
  input,
);
