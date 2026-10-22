import 'dart:io' show CertificateException, HandshakeException, TlsException;

/// Whether [error] is a refused TLS certificate: a `HandshakeException`, a `TlsException` or a
/// `CertificateException` (`dart:io`; the web has no such type, see `tls_failure_stub.dart`).
bool isRefusedCertificate(Object error) =>
    error is HandshakeException ||
    error is TlsException ||
    error is CertificateException;
