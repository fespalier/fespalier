/// Whether [error] is a refused TLS certificate. On the web the browser gives no error that
/// tells a refused certificate from any other failed request, so nothing is mapped there.
bool isRefusedCertificate(Object error) => false;
