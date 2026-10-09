/// Dio as a `package:http` client (since 0.15.0): [DioHttpClient] sends an `http.BaseRequest`
/// through a `Dio`, interceptors and all, so anything that takes an `http.Client` can use the
/// app's Dio.
library;

export 'src/dio_http_client.dart' show DioHttpClient;
