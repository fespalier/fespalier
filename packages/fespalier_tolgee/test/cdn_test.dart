import 'dart:convert';

import 'package:fespalier_tolgee/fespalier_tolgee.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  late List<http.Request> requests;

  TolgeeCdn cdn(
    int status, {
    String body = '{"a":"A"}',
    Map<String, String> headers = const {},
    TolgeeCdnFormat format = TolgeeCdnFormat.json,
    String? namespace,
    String Function(String)? file,
    Uri? base,
  }) {
    requests = [];
    return TolgeeCdn(
      base ?? Uri.parse('https://cdn.tolg.ee/abc123/'),
      format: format,
      namespace: namespace,
      file: file,
      client: MockClient((request) async {
        requests.add(request);
        return http.Response.bytes(utf8.encode(body), status, headers: headers);
      }),
    );
  }

  test('URL is <base>/<locale>.json, and .arb, with a namespace', () async {
    await cdn(200).fetch('fr');
    expect(
      requests.single.url.toString(),
      'https://cdn.tolg.ee/abc123/fr.json',
    );
    await cdn(
      200,
      format: TolgeeCdnFormat.arb,
      namespace: 'shop',
    ).fetch('pt-BR');
    expect(
      requests.single.url.toString(),
      'https://cdn.tolg.ee/abc123/shop/pt-BR.arb',
    );
    await cdn(
      200,
      base: Uri.parse('https://x.test/c'),
      file: (l) => 'app_$l.json',
    ).fetch('de');
    expect(requests.single.url.toString(), 'https://x.test/c/app_de.json');
  });

  test('200 parses the body as UTF-8 and keeps the ETag', () async {
    final r = await cdn(
      200,
      body: '{"a":"Épuisé"}',
      headers: {'etag': '"v1"'},
    ).fetch('fr');
    expect(r!.catalog.locale, 'fr');
    expect(r.catalog.messages, {'a': 'Épuisé'});
    expect(r.etag, '"v1"');
  });

  test('ARB format parses ARB', () async {
    final r = await cdn(
      200,
      body: '{"@@locale":"en","a":"A","@a":{}}',
      format: TolgeeCdnFormat.arb,
    ).fetch('en');
    expect(r!.catalog.messages, {'a': 'A'});
  });

  test('If-None-Match is sent; 304 and 404 are null; 5xx throws', () async {
    expect(await cdn(304).fetch('fr', etag: '"v1"'), isNull);
    expect(requests.single.headers['If-None-Match'], '"v1"');
    expect(await cdn(404).fetch('fr'), isNull);
    expect(requests.single.headers.containsKey('If-None-Match'), isFalse);
    await expectLater(
      cdn(503).fetch('fr'),
      throwsA(isA<http.ClientException>()),
    );
  });

  test('a body that is not a catalog throws a FormatException', () async {
    await expectLater(
      cdn(200, body: '<html>').fetch('fr'),
      throwsFormatException,
    );
  });

  test('no X-API-Key or Authorization header is ever sent', () async {
    await cdn(200).fetch('fr', etag: 'x');
    final names = requests.single.headers.keys.map((k) => k.toLowerCase());
    expect(names, isNot(contains('x-api-key')));
    expect(names, isNot(contains('authorization')));
  });
}
