import 'package:fespalier_sign_keypair/fespalier_sign_keypair.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  String htu(String uri) => dpopHtu(Uri.parse(uri));

  test('drops the query and the fragment', () {
    expect(
      htu('https://api.example.com/orders?page=2&sort=asc#top'),
      'https://api.example.com/orders',
    );
  });

  test('drops the default port and keeps any other', () {
    expect(htu('https://api.example.com:443/o'), 'https://api.example.com/o');
    expect(htu('http://api.example.com:80/o'), 'http://api.example.com/o');
    expect(
      htu('https://api.example.com:8443/o'),
      'https://api.example.com:8443/o',
    );
    // 443 is the default of https only.
    expect(htu('http://localhost:443/o'), 'http://localhost:443/o');
    expect(htu('http://localhost:8080/o'), 'http://localhost:8080/o');
  });

  test('lower-cases the scheme and the host, not the path', () {
    expect(
      htu('HTTPS://API.Example.COM/Orders/ABC'),
      'https://api.example.com/Orders/ABC',
    );
  });

  test('turns an empty path into /', () {
    expect(htu('https://api.example.com'), 'https://api.example.com/');
    expect(htu('https://api.example.com?x=1'), 'https://api.example.com/');
  });

  test('keeps an IPv6 host in brackets', () {
    expect(htu('http://[::1]:8080/a'), 'http://[::1]:8080/a');
    expect(htu('https://[2001:db8::1]/a'), 'https://[2001:db8::1]/a');
  });

  test('keeps the percent-encoding of the path', () {
    expect(
      htu('https://api.example.com/a%20b/%C3%A9?q=%20'),
      'https://api.example.com/a%20b/%C3%A9',
    );
    expect(
      htu('https://api.example.com/a%2Fb'),
      'https://api.example.com/a%2Fb',
    );
  });
}
