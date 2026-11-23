/// The API client of the app: the server (`/api/v1`) and the rc-photo plugin
/// (`/app/rc-photo/api`). Plain Dart, so `test/api_live` runs it against a real
/// server.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'auth.dart';
import 'models.dart';

/// `GET /api/v1/info`: what answers at an address.
class ServerInfo {
  const ServerInfo({
    required this.version,
    required this.publicUrl,
    required this.thumbnails,
  });

  factory ServerInfo.fromJson(Map<String, dynamic> j) => ServerInfo(
    version: j['version'] as String? ?? '',
    publicUrl: j['public_url'] as String? ?? '',
    thumbnails: j['thumbnails'] as bool? ?? false,
  );

  final String version;

  /// The address the server calls its own; empty if not set.
  final String publicUrl;
  final bool thumbnails;
}

/// `GET /api/v1/auth/me`.
class User {
  const User({
    required this.id,
    required this.username,
    required this.displayName,
  });

  factory User.fromJson(Map<String, dynamic> j) => User(
    id: j['id'] as String,
    username: j['username'] as String,
    displayName: j['display_name'] as String?,
  );

  final String id;
  final String username;
  final String? displayName;

  String get shownName =>
      (displayName?.isNotEmpty ?? false) ? displayName! : username;
}

/// A shard as fetched: [entries] is null when it didn't change (`304`).
class ShardResult {
  const ShardResult({required this.etag, required this.entries});

  final String? etag;
  final List<Entry>? entries;
}

/// An upload in parts, as the server has it.
class UploadState {
  const UploadState({
    required this.id,
    required this.size,
    required this.received,
  });

  factory UploadState.fromJson(Map<String, dynamic> j) => UploadState(
    id: j['id'] as String,
    size: (j['size'] as num?)?.toInt() ?? 0,
    received: (j['received'] as num?)?.toInt() ?? 0,
  );

  final String id;
  final int size;
  final int received;
}

/// What a link is for (`POST /app/rc-photo/api/links`).
enum LinkKind { thumb, preview, original }

/// The rc-photo plugin's id, and the prefix it answers at.
const photoAppId = 'rc-photo';
const photoApi = '/app/$photoAppId/api';

class RcClient {
  /// [auth] is null only for requests that need no session ([info]).
  RcClient(this.server, this.auth, {Dio? dio}) : dio = dio ?? Dio() {
    this.dio.options
      ..baseUrl = server.toString()
      ..connectTimeout = const Duration(seconds: 20)
      ..receiveTimeout = const Duration(seconds: 60)
      ..headers['X-Requested-With'] = 'rc-photo-client';
    if (auth != null) this.dio.interceptors.add(_BearerInterceptor(this));
  }

  final Uri server;
  final TokenSource? auth;
  final Dio dio;

  // ── Server ──────────────────────────────────────────────────────────

  Future<ServerInfo> info() async =>
      ServerInfo.fromJson(await _json('GET', '/api/v1/info', auth: false));

  Future<User> me() async =>
      User.fromJson(await _json('GET', '/api/v1/auth/me'));

  /// Ends this device's session on the server.
  Future<void> logout() => _json('POST', '/api/v1/auth/logout');

  // ── Files ───────────────────────────────────────────────────────────

  /// The user's root folder.
  Future<Node> root() async =>
      Node.fromJson(await _json('GET', '/api/v1/files/root'));

  Future<List<Node>> children(String folderId) async {
    final r = await _send('GET', '/api/v1/files/$folderId/children');
    return (r.data as List<dynamic>)
        .whereType<Map<String, dynamic>>()
        .map(Node.fromJson)
        .toList();
  }

  /// `409 NAME_TAKEN` if something of that name is there already.
  Future<Node> createFolder(String parentId, String name) async =>
      Node.fromJson(
        await _json(
          'POST',
          '/api/v1/files/$parentId/folders',
          body: {'name': name},
        ),
      );

  /// Gives the Photos plugin a folder and everything inside it, for good.
  Future<void> grantToPlugin(String folderId, {bool write = true}) => _json(
    'POST',
    '/api/v1/grants',
    body: {
      'app_id': photoAppId,
      'node_id': folderId,
      'write': write,
      'kind': 'standing',
    },
  );

  /// To the trash (recoverable there).
  Future<void> deleteFile(String id) => _send('DELETE', '/api/v1/files/$id');

  // ── Upload ──────────────────────────────────────────────────────────

  /// A whole file in one request (`POST …/upload`); [mtime] in seconds.
  Future<Node> upload(
    String folderId,
    String name,
    Uint8List bytes, {
    int? mtime,
    bool overwrite = false,
  }) async {
    final q = Uri(
      queryParameters: {
        'name': name,
        'mtime': ?mtime?.toString(),
        if (overwrite) 'overwrite': 'true',
      },
    ).query;
    final r = await _send(
      'POST',
      '/api/v1/files/$folderId/upload?$q',
      body: bytes,
      contentType: 'application/octet-stream',
    );
    return Node.fromJson(r.data as Map<String, dynamic>);
  }

  /// Starts an upload in parts (`POST …/uploads`).
  Future<UploadState> startUpload(
    String folderId, {
    required String name,
    required int size,
    int? mtime,
    bool overwrite = false,
  }) async => UploadState.fromJson(
    await _json(
      'POST',
      '/api/v1/files/$folderId/uploads',
      body: {
        'name': name,
        'size': size,
        // A string: the server reads it like `?mtime=` (seconds or RFC 3339)
        // and refuses a JSON number.
        'mtime': ?mtime?.toString(),
        if (overwrite) 'overwrite': true,
      },
    ),
  );

  /// How much of an upload the server has; `404 UPLOAD_NOT_FOUND` when it
  /// expired (24 h without a part).
  Future<UploadState> uploadState(String id) async =>
      UploadState.fromJson(await _json('GET', '/api/v1/files/uploads/$id'));

  /// The next part, at [offset] = what the server has.
  Future<UploadState> uploadPart(String id, int offset, Uint8List bytes) async {
    final r = await _send(
      'PUT',
      '/api/v1/files/uploads/$id?offset=$offset',
      body: bytes,
      contentType: 'application/octet-stream',
    );
    return UploadState.fromJson(r.data as Map<String, dynamic>);
  }

  /// Puts the parts together; `400 CHECKSUM_MISMATCH` drops the upload.
  Future<Node> finishUpload(String id, String sha256) async => Node.fromJson(
    await _json(
      'POST',
      '/api/v1/files/uploads/$id/finish',
      body: {'sha256': sha256},
    ),
  );

  // ── Plugin ──────────────────────────────────────────────────────────

  /// The gallery state; `404 APP_NOT_FOUND` when the plugin is not installed
  /// or turned off. [today] (the phone's date) picks the stories of the day.
  Future<PhotoState> photoState({DateTime? today}) async =>
      PhotoState.fromJson(await photoStateJson(today: today));

  /// [photoState] as the plugin sent it, to keep.
  Future<Map<String, dynamic>> photoStateJson({DateTime? today}) {
    final q = today == null
        ? ''
        : '?today=${today.year.toString().padLeft(4, '0')}-'
              '${today.month.toString().padLeft(2, '0')}-'
              '${today.day.toString().padLeft(2, '0')}';
    return _json('GET', '$photoApi/state$q');
  }

  /// One index shard by its link from [PhotoState.shards]. Links work
  /// without a session; [etag] from the last fetch makes an unchanged shard a
  /// cheap `304`.
  Future<ShardResult> shard(String link, {String? etag}) async {
    final r = await _send(
      'GET',
      link,
      auth: false,
      headers: {'If-None-Match': ?etag},
      type: ResponseType.plain,
    );
    final newEtag = r.headers.value('etag');
    if (r.statusCode == 304) return ShardResult(etag: etag, entries: null);
    final list = jsonDecode(r.data as String) as List<dynamic>;
    return ShardResult(
      etag: newEtag,
      entries: list
          .whereType<Map<String, dynamic>>()
          .map(Entry.fromJson)
          .toList(),
    );
  }

  /// The text behind a link the server gave (a shard of the index); links
  /// work without a session.
  Future<String> fetchText(String link) async {
    final r = await _send('GET', link, auth: false, type: ResponseType.plain);
    return r.data as String;
  }

  /// Links to thumbnails, previews or originals, in the order asked (at most
  /// 1000 per request); null for what isn't there.
  Future<List<String?>> links(List<(String id, LinkKind kind)> items) async {
    final j = await _json(
      'POST',
      '$photoApi/links',
      body: {
        'items': [
          for (final (id, kind) in items) {'id': id, 'kind': kind.name},
        ],
      },
    );
    return (j['urls'] as List<dynamic>).cast<String?>();
  }

  /// Names, hides or shows a person: an empty [name] takes the name away.
  Future<void> changePerson(String id, {String? name, bool? hidden}) => _json(
    'PUT',
    '$photoApi/people/$id',
    body: {'name': ?name, 'hidden': ?hidden},
  );

  /// The user watched a story.
  Future<void> storySeen(String date) =>
      _json('POST', '$photoApi/stories/$date/seen');

  /// Hides a story, and its theme for good.
  Future<void> hideStory(String date) =>
      _json('POST', '$photoApi/stories/$date/hide');

  /// Turns finding faces on or off for this user; the plugin's answer is the
  /// new status (`{enabled, state?}`).
  Future<Map<String, dynamic>> setFaces(bool enabled) =>
      _json('PUT', '$photoApi/faces', body: {'enabled': enabled});

  /// A full URL for a link the server gave (they are relative).
  Uri resolve(String link) => server.resolve(link);

  // ── Plumbing ────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> _json(
    String method,
    String path, {
    Object? body,
    bool auth = true,
  }) async {
    final r = await _send(method, path, body: body, auth: auth);
    final data = r.data;
    if (data is Map<String, dynamic>) return data;
    return const {};
  }

  Future<Response<dynamic>> _send(
    String method,
    String path, {
    Object? body,
    bool auth = true,
    Map<String, String> headers = const {},
    ResponseType type = ResponseType.json,
    String? contentType,
  }) async {
    final Response<dynamic> r;
    try {
      r = await dio.request<dynamic>(
        path,
        data: body,
        options: Options(
          method: method,
          headers: headers,
          contentType: contentType,
          responseType: type,
          validateStatus: (_) => true,
          extra: {_noAuth: !auth},
        ),
      );
    } on DioException catch (e) {
      // Errors of the token source come wrapped by the interceptor.
      final inner = e.error;
      if (inner is SessionEndedException ||
          inner is NetworkException ||
          inner is ApiException) {
        throw inner!;
      }
      throw NetworkException.from(e);
    }
    final status = r.statusCode ?? 0;
    if (status >= 400) {
      Object? data = r.data;
      if (data is String) {
        try {
          data = jsonDecode(data);
        } on FormatException {
          // keep the text
        }
      }
      throw ApiException.fromBody(status, data);
    }
    return r;
  }
}

const _noAuth = 'rc.noAuth';
const _retried = 'rc.retried';

/// Adds `Authorization: Bearer`, and on a 401 gets a new token and repeats
/// the request once.
class _BearerInterceptor extends Interceptor {
  _BearerInterceptor(this._client);

  final RcClient _client;

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    if (options.extra[_noAuth] == true) return handler.next(options);
    try {
      options.headers['Authorization'] =
          'Bearer ${await _client.auth!.token()}';
      handler.next(options);
    } catch (e) {
      handler.reject(DioException(requestOptions: options, error: e));
    }
  }

  @override
  Future<void> onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) async {
    final o = response.requestOptions;
    if (response.statusCode != 401 ||
        o.extra[_noAuth] == true ||
        o.extra[_retried] == true) {
      return handler.next(response);
    }
    final sent = (o.headers['Authorization'] as String? ?? '').replaceFirst(
      'Bearer ',
      '',
    );
    try {
      final fresh = await _client.auth!.renew(sent);
      o.headers['Authorization'] = 'Bearer $fresh';
      o.extra[_retried] = true;
      handler.resolve(await _client.dio.fetch<dynamic>(o));
    } catch (e) {
      handler.reject(DioException(requestOptions: o, error: e));
    }
  }
}
