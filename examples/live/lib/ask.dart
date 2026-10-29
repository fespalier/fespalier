import 'dart:async';
import 'dart:convert';

import 'package:fespalier_transport/fespalier_transport.dart';

/// The answer to [question] from `POST` [url], as the text so far after each piece the server sends:
/// what a language model's answer looks like on the wire, a body written a word at a time.
///
/// Cancelling the subscription (the page's **Stop**, or leaving the page) completes the request's
/// `abortTrigger` at once, even before the headers came, so the client lets the connection go and the
/// server sees the client leave. A status that is not 200 is a [TransportStatusError].
Stream<String> streamAnswer(HttpTransport transport, Uri url, String question) {
  final giveUp = Completer<void>();
  void letGo() {
    if (!giveUp.isCompleted) giveUp.complete();
  }

  StreamSubscription<String>? reading;
  var cancelled = false;
  late final StreamController<String> out;
  out = StreamController<String>(
    onListen: () {
      transport
          .send(
            TransportRequest(
              method: 'POST',
              uri: url,
              headers: const {
                'content-type': 'text/plain; charset=utf-8',
                'accept': 'text/plain',
              },
              body: utf8.encode(question),
              abortTrigger: giveUp.future,
            ),
          )
          .then(
            (response) async {
              if (cancelled) return;
              if (response.statusCode != 200) {
                letGo();
                out.addError(
                  TransportStatusError(
                    statusCode: response.statusCode,
                    headers: response.headers,
                    body: await response.bytes(),
                    reasonPhrase: response.reasonPhrase,
                  ),
                );
                await out.close();
                return;
              }
              var text = '';
              reading = response.body
                  .transform(utf8.decoder)
                  .listen(
                    (piece) {
                      text += piece;
                      out.add(text);
                    },
                    // The body is over: nothing to cancel any more, and a cancel of a finished
                    // subscription would hold the done event back until it completes.
                    onError: (Object error, StackTrace stackTrace) {
                      reading = null;
                      letGo();
                      out.addError(error, stackTrace);
                      unawaited(out.close());
                    },
                    onDone: () {
                      reading = null;
                      letGo();
                      unawaited(out.close());
                    },
                    cancelOnError: true,
                  );
            },
            onError: (Object error, StackTrace stackTrace) {
              if (cancelled) return;
              out.addError(error, stackTrace);
              unawaited(out.close());
            },
          );
    },
    onCancel: () {
      cancelled = true;
      letGo();
      return reading?.cancel();
    },
  );
  return out.stream;
}
