// What the tests share: a Dio adapter that answers from a function (no network, no sleeping), the
// JSON answers it gives, and a capture of what a debug build prints.
import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

/// What a [FakeAdapter] does with one request. [cancelFuture] completes when the request's
/// `CancelToken` is cancelled, as it does for a real adapter.
typedef AdapterHandler =
    Future<ResponseBody> Function(
      RequestOptions options,
      Future<void>? cancelFuture,
    );

/// A `HttpClientAdapter` that answers from [handler] and keeps every request it was given.
final class FakeAdapter implements HttpClientAdapter {
  /// An adapter that answers with [handler].
  FakeAdapter(this.handler);

  /// An adapter that answers the n-th request with `answers[n]` (the last one repeats).
  factory FakeAdapter.sequence(List<ResponseBody Function()> answers) {
    var next = 0;
    return FakeAdapter((options, cancelFuture) async {
      final answer = answers[next < answers.length ? next : answers.length - 1];
      next++;
      return answer();
    });
  }

  /// The function that answers.
  final AdapterHandler handler;

  /// Every request the adapter was asked for, in order.
  final List<RequestOptions> requests = [];

  /// How many requests were sent.
  int get sent => requests.length;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    requests.add(options);
    return handler(options, cancelFuture);
  }

  @override
  void close({bool force = false}) {}
}

/// A JSON answer with [status].
ResponseBody jsonAnswer(Object? json, int status) => ResponseBody.fromString(
  jsonEncode(json),
  status,
  headers: {
    Headers.contentTypeHeader: ['application/json'],
  },
);

/// An empty answer with [status].
ResponseBody emptyAnswer(int status) => ResponseBody.fromString('', status);

/// A `Dio` over [adapter], with no base URL.
Dio dioOver(FakeAdapter adapter) => Dio()..httpClientAdapter = adapter;

/// What `debugPrint` printed while [body] ran.
Future<List<String>> printedDuring(Future<void> Function() body) async {
  final printed = <String>[];
  final old = debugPrint;
  debugPrint = (message, {wrapWidth}) => printed.add('$message');
  try {
    await body();
  } finally {
    debugPrint = old;
  }
  return printed;
}
