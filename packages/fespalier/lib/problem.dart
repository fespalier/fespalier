/// Server validation errors as [FieldErrors], with no HTTP client in it (since 0.9.0, in
/// `fespalier_http` from 0.15.0 to 0.20.0, in `fespalier` since 0.21.0 so that `fespalier_dio` need not
/// depend on `fespalier_http`): the decoders for the shapes servers send (RFC 9457 and 7807,
/// ASP.NET Core, Laravel, Spring, JSON:API, FastAPI, Django REST framework), and [fieldErrorsOf],
/// for a client of your own.
///
/// `package:fespalier_http/fespalier_http.dart` (`package:http`) and
/// `package:fespalier_dio/fespalier_dio.dart` (Dio) add `withFieldErrors()` over it.
///
/// ```dart
/// final errors = fieldErrorsOf(response.statusCode, response.body); // chopper, for one
/// if (errors != null) throw errors;
/// ```
library;

export 'src/problem.dart'
    show FieldErrorsDecoder, FieldErrorsDecoders, FieldNames, fieldErrorsOf;
