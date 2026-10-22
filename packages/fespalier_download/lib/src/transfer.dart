import 'dart:async';
import 'dart:typed_data';

import 'package:fespalier_transport/fespalier_transport.dart'
    show
        CredentialsUnavailable,
        HttpAuthorization,
        HttpCredentials,
        HttpTransport,
        TransportRequest,
        TransportResponse;

import 'status.dart' show DownloadFailure;
import 'transfer_files.dart';

final RegExp _contentRange = RegExp(
  r'^bytes\s+(\d+)-(\d+)/(\d+|\*)$',
  caseSensitive: false,
);
final RegExp _unsatisfied = RegExp(r'^bytes\s+\*/(\d+)$', caseSensitive: false);

/// How far one transfer is told about: at least this many bytes, or a 200th of the file.
const int _reportStep = 64 * 1024;

/// How an [HttpTransfer] ended (since 0.15.0).
sealed class TransferResult {
  const TransferResult();
}

/// The file is whole, checked and at its destination.
final class TransferDone extends TransferResult {
  /// Done: the destination holds [bytes] bytes.
  const TransferDone(this.bytes);

  /// The size of the file.
  final int bytes;
}

/// [HttpTransfer.pause] stopped it; the bytes received are kept for the next attempt.
final class TransferPaused extends TransferResult {
  /// Paused at [received] bytes out of [total] (null when unknown).
  const TransferPaused(this.received, this.total);

  /// Bytes kept.
  final int received;

  /// The size, when known.
  final int? total;
}

/// [HttpTransfer.stop] ended it: nothing is left to report.
final class TransferStopped extends TransferResult {
  /// Stopped.
  const TransferStopped();
}

/// It ended without a file.
final class TransferFailed extends TransferResult {
  /// Failed for [failure]; [httpStatus] is the server's status code when the server refused.
  const TransferFailed(this.failure, {this.httpStatus});

  /// Why.
  final DownloadFailure failure;

  /// The status code of the refusal, if it was one.
  final int? httpStatus;
}

enum _Step { verify, stop, restart, again }

// The headers a transfer sets itself: the app's own of these names are replaced.
const Set<String> _ownHeaders = {'range', 'if-range', 'accept-encoding'};

/// The most sends of one request that [HttpCredentials] may ask for, as `SessionTransport`'s.
const int _maxSends = 3;

/// The most bytes of a 401's or 403's body that are read for [HttpCredentials.retry].
const int _maxRefusalBody = 64 * 1024;

// The body of a response and whether the transfer took it: a body nobody reads is cancelled. The
// response is replaced when its body was read for the credentials, by one over the same bytes.
final class _Body {
  _Body(this.response);

  TransportResponse response;
  bool taken = false;
}

// The [head] bytes already read from [rest], and the rest, as one stream again.
Stream<List<int>> _rejoin(
  List<int> head,
  StreamIterator<List<int>> rest,
) async* {
  try {
    yield head;
    while (await rest.moveNext()) {
      yield rest.current;
    }
  } finally {
    await rest.cancel();
  }
}

TransportResponse _withBody(
  TransportResponse response,
  Stream<List<int>> body,
) => TransportResponse(
  statusCode: response.statusCode,
  headers: response.headers,
  body: body,
  reasonPhrase: response.reasonPhrase,
);

// [headers] with [extra] on top, matching names without regard to case (an HTTP header name has
// none): `Authorization` from the credentials replaces an `authorization` the app set.
Map<String, String> _merged(
  Map<String, String> headers,
  Map<String, String> extra,
) {
  final names = {for (final name in extra.keys) name.toLowerCase()};
  return <String, String>{
    for (final entry in headers.entries)
      if (!names.contains(entry.key.toLowerCase())) entry.key: entry.value,
    ...extra,
  };
}

// Cancels a response body that is not wanted (an error status, a restart) after its first event,
// without waiting for the rest. No `listen` here: `await for` is the subscription.
Future<void> _abandon(TransportResponse response) async {
  try {
    await for (final _ in response.body) {
      break;
    }
  } catch (_) {
    // The connection is being thrown away anyway.
  }
}

/// One resumable transfer of a single file over HTTP (since 0.15.0), with no state beyond the
/// attempt: it is made, [run] once, and thrown away. A pause, a failure or a restart of the app
/// leaves the bytes on disk, and the next [HttpTransfer] continues from them.
///
/// Where the bytes are: they arrive in `<destination>.part`, with the server's validator beside
/// it (`.part.etag`). The attempt asks for `Range: bytes=<size of the partial file>-` (and
/// `If-Range` with the validator, so a file that changed on the server is fetched again whole)
/// and appends what comes. The file is moved to its destination only when it is the size and the
/// SHA-256 the transfer names, so **a file at the destination is always a whole, checked one**,
/// and a partial file whose check fails is deleted. A server that ignores `Range` (it answers
/// 200) makes the transfer start again from the first byte; one that answers 416 to a partial
/// file it no longer has the end of gets one restart too.
///
/// It starts no timer and listens to nothing: the response body is read with `await for`, which
/// ends when the transfer is paused or stopped, because both abort the request through its
/// `abortTrigger` (every `HttpTransport` honours it, `fespalier_http`'s and `fespalier_dio`'s
/// among them), so a connection that sends nothing cannot hold them up.
///
/// It reports nothing to telemetry: whoever owns the transfer does, and a URL, a path or a
/// header never leave it.
class HttpTransfer {
  /// A transfer of [url] into [destination], an absolute path. [headers] go with the request
  /// (`Range`, `If-Range` and `Accept-Encoding` are the transfer's own and replace the same
  /// names); [bytes] and [sha256] (64 hex digits, either case) are what the file must be.
  /// [onProgress] hears the bytes received and the size when known, [onVerifying] hears that the
  /// body is whole and is being checked.
  HttpTransfer({
    required HttpTransport transport,
    required TransferFiles files,
    required this.url,
    required this.destination,
    this.headers = const {},
    this.bytes,
    this.sha256,
    this.onProgress,
    this.onVerifying,
    this.credentials,
  }) : _transport = transport,
       _files = files;

  final HttpTransport _transport;
  final TransferFiles _files;

  /// Where the file is fetched from.
  final Uri url;

  /// The absolute path of the finished file.
  final String destination;

  /// Request headers for this attempt.
  final Map<String, String> headers;

  /// The size the file must have, when known.
  final int? bytes;

  /// The SHA-256 of the file, when known.
  final String? sha256;

  /// Called with the bytes received so far and the size (null when unknown).
  final void Function(int received, int? total)? onProgress;

  /// Called once the body is whole, before its size and digest are checked.
  final void Function()? onVerifying;

  /// The session's credentials, asked before each send (`authorize`) and after a refusal
  /// (`retry`), for this foreground transfer only: the app is running, so its session is there.
  /// A transfer sends one `GET`, which is safe to send again; at most three sends per request.
  /// Null sends [headers] alone. A throw from the credentials ends the transfer `unauthorized`,
  /// except a `CredentialsUnavailable` (the session could not be reached, as `AuthUnavailable`
  /// is when a token cannot refresh offline), which ends it `network` (since 0.16.0): nothing was
  /// refused, and `Downloads.retry` goes on from the partial file.
  final HttpCredentials? credentials;

  // The attempt of the request being sent, kept while [credentials] asks for a re-send.
  HttpAuthorization? _attempt;
  int _sends = 0;

  /// Where the bytes arrive: [destination] plus `.part`.
  String get partial => '$destination.part';

  /// Where the validator of the partial file (the server's `ETag` or `Last-Modified`, which
  /// `If-Range` sends back) is kept: [partial] plus `.etag`.
  String get validator => '$partial.etag';

  // Completes to abort the request in flight (a pause or a stop).
  final Completer<void> _abort = Completer<void>();
  bool _pausing = false;
  bool _stopped = false;
  bool _started = false;
  TransferResult? _result;

  /// Pauses the transfer: the request is aborted, the partial file is kept and [run] completes
  /// with [TransferPaused]. Does nothing once the body is whole and being checked.
  void pause() {
    if (_stopped) return;
    _pausing = true;
    _abortNow();
  }

  /// Ends the transfer for good (a cancel, the end of the owner): the request is aborted, the
  /// file is closed and [run] completes with [TransferStopped]. Nothing is deleted.
  void stop() {
    _stopped = true;
    _abortNow();
  }

  void _abortNow() {
    if (!_abort.isCompleted) _abort.complete();
  }

  void _fail(DownloadFailure failure, {int? httpStatus}) {
    if (_stopped) return;
    _result ??= TransferFailed(failure, httpStatus: httpStatus);
  }

  void _setPaused(int received, int? total) {
    if (_stopped) return;
    _result ??= TransferPaused(received, total);
  }

  static DownloadFailure _storeFailure(Object error) =>
      error is UnsupportedError
      ? DownloadFailure.unsupported
      : DownloadFailure.storage;

  /// Runs the transfer. Never throws for a failure of the transfer; call it once.
  Future<TransferResult> run() async {
    if (_started) throw StateError('HttpTransfer.run is single-use');
    _started = true;
    try {
      await _work();
    } catch (error) {
      _fail(
        error is UnsupportedError
            ? DownloadFailure.unsupported
            : DownloadFailure.other,
      );
    }
    if (_stopped) return const TransferStopped();
    return _result ?? const TransferFailed(DownloadFailure.other);
  }

  Future<void> _work() async {
    var offset = 0;
    try {
      if (!_files.isSupported) {
        _fail(DownloadFailure.unsupported);
        return;
      }
      final done = await _files.length(destination);
      if (_stopped) return;
      if (done != null) {
        if (bytes == null || done == bytes) {
          _result ??= TransferDone(done);
          return;
        }
        // The file of another size stays: the move at the end replaces it atomically.
      }
      offset = await _files.length(partial) ?? 0;
    } catch (error) {
      _fail(_storeFailure(error));
      return;
    }
    if (_stopped) return;
    var restarted = false;
    while (true) {
      try {
        if (offset > 0 && bytes != null && offset > bytes!) {
          await _dropPartial();
          offset = 0;
        }
      } catch (error) {
        _fail(_storeFailure(error));
        return;
      }
      final step = await _fetch(offset);
      if (_stopped) return;
      switch (step) {
        case _Step.stop:
          return;
        case _Step.again:
          continue;
        case _Step.verify:
          await _verify();
          return;
        case _Step.restart:
          if (restarted) {
            _fail(DownloadFailure.rejected);
            return;
          }
          restarted = true;
          try {
            await _dropPartial();
          } catch (error) {
            _fail(_storeFailure(error));
            return;
          }
          offset = 0;
      }
    }
  }

  Future<void> _dropPartial() async {
    await _files.delete(partial);
    await _files.delete(validator);
  }

  /// One request, from [offset]: the partial file is appended to, or emptied when the server
  /// sent the whole body.
  Future<_Step> _fetch(int offset) async {
    if (bytes != null && offset == bytes) return _Step.verify;
    String? tag;
    if (offset > 0) {
      try {
        tag = await _files.readText(validator);
      } catch (error) {
        _fail(_storeFailure(error));
        return _Step.stop;
      }
      // Without a validator nothing says the partial file belongs to the file the server has
      // now: only a hash (checked at the end) makes a blind continuation safe. Otherwise the
      // transfer starts from the first byte and the partial file is emptied when it begins.
      if (tag == null && sha256 == null) offset = 0;
    }
    // After the awaits above a stop may have come: a request is never sent once it did.
    if (_stopped) return _Step.stop;
    if (_abort.isCompleted) {
      if (_pausing) _setPaused(offset, bytes);
      return _Step.stop;
    }
    // Aborted by a pause or a stop or, when the transfer is done with the response, by this
    // request's own completer, so a body that never sends a byte is freed.
    final done = Completer<void>();
    // Offsets count the bytes on the wire: a compressed body would make them mean nothing.
    var wire = <String, String>{
      for (final entry in headers.entries)
        if (!_ownHeaders.contains(entry.key.toLowerCase()))
          entry.key: entry.value,
    };
    wire['accept-encoding'] = 'identity';
    if (offset > 0) {
      wire['range'] = 'bytes=$offset-';
      if (tag != null) wire['if-range'] = tag;
    }
    final abortTrigger = Future.any<void>([_abort.future, done.future]);
    final session = credentials;
    if (session != null) {
      try {
        final attempt = _attempt = await session.authorize(
          TransportRequest(
            method: 'GET',
            uri: url,
            headers: Map<String, String>.of(wire),
            body: Uint8List(0),
          ),
          previous: _attempt,
        );
        _sends++;
        wire = _merged(wire, attempt.headers);
      } on CredentialsUnavailable {
        // The session could not be reached (no network while its token refreshes,
        // `AuthUnavailable`): nothing was refused, so this is not a lost session.
        done.complete();
        if (!_stopped) _fail(DownloadFailure.network);
        return _Step.stop;
      } catch (_) {
        done.complete();
        if (!_stopped) _fail(DownloadFailure.unauthorized);
        return _Step.stop;
      }
    }
    final TransportResponse response;
    try {
      response = await _transport.send(
        TransportRequest(
          method: 'GET',
          uri: url,
          headers: wire,
          abortTrigger: abortTrigger,
        ),
      );
    } catch (_) {
      if (_stopped) return _Step.stop;
      if (_pausing) {
        _setPaused(offset, bytes);
      } else {
        _fail(DownloadFailure.network);
      }
      return _Step.stop;
    }
    final body = _Body(response);
    try {
      final again = await _askAgain(body);
      if (again == null) return _Step.stop;
      if (again) return _Step.again;
      // The response stands: the next request (a restart) starts its sends from one.
      _attempt = null;
      _sends = 0;
      return await _handle(offset, tag, body);
    } finally {
      if (!body.taken) unawaited(_abandon(body.response));
      if (!done.isCompleted) done.complete();
    }
  }

  // Whether the credentials want the request sent once more after this response: true (send
  // again), false (handle it), null (the credentials threw: the transfer failed). Only a refusal
  // is put to them, and only while sends are left.
  Future<bool?> _askAgain(_Body body) async {
    final response = body.response;
    final session = credentials;
    final attempt = _attempt;
    final code = response.statusCode;
    if (session == null || attempt == null || _stopped || _pausing) {
      return false;
    }
    if (code < 400 || code >= 500 || code == 416 || _sends >= _maxSends) {
      return false;
    }
    try {
      final again = await session.retry(attempt, await _forCredentials(body));
      if (again && !_stopped && !_abort.isCompleted) return true;
      return false;
    } on CredentialsUnavailable {
      // As for authorize: the refresh could not run, which says nothing about the session.
      if (!_stopped) _fail(DownloadFailure.network);
      return null;
    } catch (_) {
      if (!_stopped) _fail(DownloadFailure.unauthorized);
      return null;
    }
  }

  // The response as the credentials see it. A 401 or a 403 is read (up to 64 KiB, so a server's
  // reason or nonce can be looked at) and [body] is made again over the same bytes, so the
  // transfer handles the answer exactly as before; any other refusal, and a body that is longer,
  // goes unbuffered.
  Future<TransportResponse> _forCredentials(_Body body) async {
    final response = body.response;
    final code = response.statusCode;
    final declared = int.tryParse(response.headers['content-length'] ?? '');
    TransportResponse bodiless() => TransportResponse(
      statusCode: code,
      headers: response.headers,
      body: const Stream<List<int>>.empty(),
      reasonPhrase: response.reasonPhrase,
    );
    if ((code != 401 && code != 403) ||
        (declared != null && declared > _maxRefusalBody)) {
      return bodiless();
    }
    final rest = StreamIterator<List<int>>(response.body);
    final read = BytesBuilder(copy: false);
    var whole = true;
    try {
      while (await rest.moveNext()) {
        read.add(rest.current);
        if (read.length > _maxRefusalBody) {
          whole = false;
          break;
        }
      }
    } catch (_) {
      // The body broke off (the connection, an abort): the refusal stands, and its body is of no
      // use to the transfer, which never reads one.
      body.response = _withBody(response, const Stream<List<int>>.empty());
      return bodiless();
    }
    final head = read.takeBytes();
    if (!whole) {
      body.response = _withBody(response, _rejoin(head, rest));
      return bodiless();
    }
    final buffered = TransportResponse.fromBytes(
      statusCode: code,
      headers: response.headers,
      bytes: head,
      reasonPhrase: response.reasonPhrase,
    );
    body.response = buffered;
    return buffered;
  }

  Future<_Step> _handle(int offset, String? tag, _Body body) async {
    final response = body.response;
    if (_stopped) return _Step.stop;
    if (_pausing) {
      _setPaused(offset, bytes);
      return _Step.stop;
    }

    var append = false;
    int? total;
    switch (response.statusCode) {
      case 416:
        final unsatisfied = _unsatisfied.firstMatch(
          response.headers['content-range'] ?? '',
        );
        final size = int.tryParse(unsatisfied?.group(1) ?? '');
        if (offset > 0 && size == offset) return _Step.verify;
        if (offset > 0) return _Step.restart;
        _fail(DownloadFailure.rejected, httpStatus: 416);
        return _Step.stop;
      case 206:
        final range = _contentRange.firstMatch(
          response.headers['content-range'] ?? '',
        );
        if (range == null || int.parse(range.group(1)!) != offset) {
          return _Step.restart;
        }
        // A server or CDN that ignored If-Range may be sending another file's tail: the
        // validator of this answer must be the one the partial file was started with.
        if (offset > 0 &&
            tag != null &&
            _validatorOf(response.headers) != tag) {
          return _Step.restart;
        }
        total = int.tryParse(range.group(3)!);
        append = offset > 0;
      case 200:
        // The whole body: the server ignored Range, or If-Range said the file changed.
        final length = int.tryParse(response.headers['content-length'] ?? '');
        total = length != null && length > 0 ? length : null;
        offset = 0;
      default:
        final code = response.statusCode;
        _fail(
          code == 401 || code == 403
              ? DownloadFailure.unauthorized
              : DownloadFailure.rejected,
          httpStatus: code,
        );
        return _Step.stop;
    }
    if (bytes != null && total != null && total != bytes) {
      try {
        await _dropPartial();
      } catch (_) {
        // The failure below is what the app learns.
      }
      _fail(DownloadFailure.sizeMismatch);
      return _Step.stop;
    }
    final expected = bytes ?? total;

    var received = offset;
    DownloadFailure? failure;
    var paused = false;
    TransferSink? sink;
    try {
      // A new file starts: the old validator goes first, so a crash leaves no validator that
      // belongs to bytes of another file.
      if (!append) await _files.delete(validator);
      sink = await _files.open(partial, append: append);
      if (!append) {
        final newTag = _validatorOf(response.headers);
        if (newTag != null) await _files.writeText(validator, newTag);
      }
    } catch (error) {
      failure = _storeFailure(error);
    }
    if (failure == null && !_stopped) {
      body.taken = true;
      onProgress?.call(received, expected);
      var reported = received;
      final step = expected == null ? _reportStep : expected ~/ 200;
      try {
        await for (final chunk in response.body) {
          if (_stopped) break;
          try {
            await sink!.add(chunk);
          } catch (error) {
            failure = _storeFailure(error);
            break;
          }
          received += chunk.length;
          if (_stopped) break;
          if (_pausing) {
            paused = true;
            break;
          }
          if (received - reported >=
              (step < _reportStep ? _reportStep : step)) {
            reported = received;
            onProgress?.call(received, expected);
          }
        }
      } catch (_) {
        failure ??= DownloadFailure.network;
      }
    }
    try {
      await sink?.close();
    } catch (error) {
      failure ??= _storeFailure(error);
    }
    // A pause aborts the request: the error that reads as a broken connection is a pause.
    if (_pausing && failure == DownloadFailure.network) {
      failure = null;
      paused = true;
    }
    if (_stopped) return _Step.stop;
    if (paused) {
      _setPaused(received, expected);
      return _Step.stop;
    }
    if (failure != null) {
      _fail(failure);
      return _Step.stop;
    }
    if (expected != null && received != expected) {
      if (received < expected) {
        // The body ended short without an error: the connection is what failed.
        _fail(DownloadFailure.network);
      } else {
        try {
          await _dropPartial();
        } catch (_) {
          // The failure below is what the app learns.
        }
        _fail(DownloadFailure.sizeMismatch);
      }
      return _Step.stop;
    }
    return _Step.verify;
  }

  /// The `ETag` of a response (a strong one) or else its `Last-Modified`: what `If-Range` sends
  /// back. Null when the server gave neither.
  static String? _validatorOf(Map<String, String> headers) {
    final etag = headers['etag'];
    if (etag != null && etag.isNotEmpty && !etag.startsWith('W/')) return etag;
    final modified = headers['last-modified'];
    return modified != null && modified.isNotEmpty ? modified : null;
  }

  /// The partial file is whole: check it, then move it to its destination.
  Future<void> _verify() async {
    try {
      final size = await _files.length(partial);
      if (_stopped) return;
      onVerifying?.call();
      if (size == null || (bytes != null && size != bytes)) {
        await _dropPartial();
        _fail(DownloadFailure.sizeMismatch);
        return;
      }
      final hash = sha256;
      if (hash != null) {
        final actual = await _files.sha256(partial);
        if (_stopped) return;
        if (actual != hash.toLowerCase()) {
          await _dropPartial();
          _fail(DownloadFailure.hashMismatch);
          return;
        }
      }
      await _files.rename(partial, destination);
      try {
        await _files.delete(validator);
      } catch (_) {
        // A leftover validator is harmless: the next partial file overwrites it.
      }
      if (_stopped) return;
      _result ??= TransferDone(size);
    } catch (error) {
      _fail(_storeFailure(error));
    }
  }
}
