/// Root certificates beyond the ones Dart trusts by itself.
///
/// On Android Dart reads the system's CA store, but not the CAs the user
/// installed (Settings → Security → Install a certificate → CA certificate),
/// which is how a self-hosted cloud signed by its own CA is trusted. The
/// native side hands their DER bytes over and they are added here to
/// [SecurityContext.defaultContext], so every HTTPS request of the app — the
/// API client, images — trusts them. Plain Dart.
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

class Trust {
  Trust([SecurityContext? context]) : _context = context;

  final SecurityContext? _context;
  final Set<String> _added = {};

  SecurityContext get context => _context ?? SecurityContext.defaultContext;

  /// Adds certificates (DER) not added before; how many were added. A
  /// certificate that can't be read is skipped: one bad CA on the phone must
  /// not stop the app.
  int add(Iterable<List<int>> certificates) {
    var n = 0;
    for (final der in certificates) {
      final id = sha256.convert(der).toString();
      if (_added.contains(id)) continue;
      try {
        context.setTrustedCertificatesBytes(utf8.encode(pem(der)));
        n++;
      } on TlsException {
        // Unreadable, or already trusted by the context.
      }
      _added.add(id);
    }
    return n;
  }

  /// DER → PEM, which [SecurityContext] reads.
  static String pem(List<int> der) {
    final b64 = base64.encode(der);
    final out = StringBuffer('-----BEGIN CERTIFICATE-----\n');
    for (var i = 0; i < b64.length; i += 64) {
      out.writeln(b64.substring(i, i + 64 > b64.length ? b64.length : i + 64));
    }
    out.writeln('-----END CERTIFICATE-----');
    return out.toString();
  }
}
