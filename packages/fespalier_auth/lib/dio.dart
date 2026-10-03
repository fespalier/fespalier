/// A `dio` interceptor for `fespalier_auth` (since 0.9.0): the session on requests to
/// `AuthConfig.apiOrigins`, refreshed once on expiry and sent again once after a 401.
///
/// A separate library, so an app that uses `package:http` links no `dio`.
///
/// ```dart
/// final dio = Dio()..interceptors.add(SessionInterceptor(ref.watch(authorizer), dio));
/// ```
library;

export 'src/dio_interceptor.dart' show SessionInterceptor;
