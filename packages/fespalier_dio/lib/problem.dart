/// Server validation errors as [FieldErrors], with no HTTP client in it (since 0.9.0): the
/// decoders for the shapes servers send (RFC 9457 and 7807, ASP.NET Core, Laravel, Spring, JSON:API,
/// FastAPI, Django REST framework), and [fieldErrorsOf], for a client of your own.
///
/// `package:fespalier_dio/fespalier_dio.dart` (Dio) and `package:fespalier_dio/http.dart`
/// (`package:http`) export this library and add `withFieldErrors()`.
///
/// ```dart
/// final errors = fieldErrorsOf(response.statusCode, response.body); // chopper, for one
/// if (errors != null) throw errors;
/// ```
library;

export 'src/problem.dart'
    show FieldErrorsDecoder, FieldErrorsDecoders, FieldNames, fieldErrorsOf;
