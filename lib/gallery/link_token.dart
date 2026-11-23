import 'dart:convert';

/// What a server link (`/api/v1/app-links/<payload>.<signature>`) points at,
/// read from its payload: base64url JSON with the target `t` (`{k, v}`) and
/// the file's ETag `e` when the link was made (rustcloud
/// `crates/server/src/app_links.rs`, `Claims`).
///
/// Links change at every server restart and after 12–13 hours, while the
/// shard behind them often doesn't: by the ETag in the link the app knows
/// that without fetching it. This reads a detail the server doesn't promise
/// (docs/requests.md#3), so anything unexpected gives null and the shard is
/// simply fetched.
class LinkTarget {
  const LinkTarget(this.path, this.version);

  /// The file in the plugin's data (`index/0a.json`) or a file id.
  final String path;

  /// The file's ETag when the link was made.
  final String version;

  static LinkTarget? read(String link) {
    try {
      final at = link.indexOf('/app-links/');
      if (at < 0) return null;
      var token = link.substring(at + '/app-links/'.length);
      token = token.split(RegExp('[/?#]')).first;
      final dot = token.indexOf('.');
      if (dot <= 0) return null;
      final payload = base64Url.normalize(token.substring(0, dot));
      final claims = jsonDecode(utf8.decode(base64Url.decode(payload)));
      if (claims is! Map<String, dynamic>) return null;
      final t = claims['t'];
      final e = claims['e'];
      if (t is! Map<String, dynamic> || e is! String || e.isEmpty) return null;
      final v = t['v'];
      if (v is! String || v.isEmpty) return null;
      return LinkTarget(v, e);
    } on FormatException {
      return null;
    }
  }
}
