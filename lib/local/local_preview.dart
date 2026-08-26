import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path_util;

import '../domain/models.dart';
import 'project_files.dart';

/// Installed in served HTML before page scripts so errors thrown during the
/// initial load are not missed by the WebView's post-load callback.
const localPreviewErrorHookScript = r'''
(function () {
  if (window.__pocketServerOpsErrorHooks) return;
  window.__pocketServerOpsErrorHooks = true;
  function send(level, source, message, url) {
    try {
      if (typeof PocketPreview !== 'undefined') {
        PocketPreview.postMessage(JSON.stringify({
          level: level,
          source: source,
          message: String(message || ''),
          url: url || location.href
        }));
      }
    } catch (_) {}
  }
  window.addEventListener('error', function (event) {
    var message = event.message || (event.error && event.error.stack) || '未捕获的 JavaScript 错误';
    send('error', 'uncaught', message, event.filename || location.href);
  }, true);
  window.addEventListener('unhandledrejection', function (event) {
    var reason = event.reason;
    send('error', 'unhandledrejection', reason && reason.stack || reason || '未处理的 Promise rejection', location.href);
  });
})();
''';

class LocalPreviewLog {
  const LocalPreviewLog({
    required this.sequence,
    required this.timestamp,
    required this.level,
    required this.source,
    required this.message,
    this.url,
  });

  final int sequence;
  final DateTime timestamp;
  final String level;
  final String source;
  final String message;
  final String? url;

  Map<String, Object?> toJson() => {
    'sequence': sequence,
    'timestamp': timestamp.toUtc().toIso8601String(),
    'level': level,
    'source': source,
    'message': message,
    if (url != null) 'url': url,
  };
}

class LocalPreviewStatus {
  const LocalPreviewStatus({
    required this.projectId,
    required this.projectName,
    required this.running,
    required this.entrypoint,
    this.url,
    this.startedAt,
    this.requestCount = 0,
    this.reloadToken = 0,
    this.lastError,
    this.logSequence = 0,
  });

  final String projectId;
  final String projectName;
  final bool running;
  final String entrypoint;
  final String? url;
  final DateTime? startedAt;
  final int requestCount;
  final int reloadToken;
  final String? lastError;
  final int logSequence;

  Map<String, Object?> toJson() => {
    'project_id': projectId,
    'project': projectName,
    'running': running,
    'entrypoint': entrypoint,
    if (url != null) 'url': url,
    if (startedAt != null) 'started_at': startedAt!.toUtc().toIso8601String(),
    'request_count': requestCount,
    'reload_token': reloadToken,
    if (lastError != null) 'last_error': lastError,
    'log_sequence': logSequence,
  };
}

class LocalWebTestIssue {
  const LocalWebTestIssue({
    required this.level,
    required this.type,
    required this.source,
    required this.message,
    this.resource,
  });

  final String level;
  final String type;
  final String source;
  final String message;
  final String? resource;

  Map<String, Object?> toJson() => {
    'level': level,
    'type': type,
    'source': source,
    'message': message,
    if (resource != null) 'resource': resource,
  };
}

class LocalWebTestResult {
  const LocalWebTestResult({
    required this.projectId,
    required this.projectName,
    required this.entrypoint,
    required this.checkedFiles,
    required this.issues,
  });

  final String projectId;
  final String projectName;
  final String entrypoint;
  final List<String> checkedFiles;
  final List<LocalWebTestIssue> issues;

  bool get ok => !issues.any((issue) => issue.level == 'error');

  Map<String, Object?> toJson() => {
    'project_id': projectId,
    'project': projectName,
    'entrypoint': entrypoint,
    'ok': ok,
    'checked_files': checkedFiles,
    'issues': [for (final issue in issues) issue.toJson()],
  };
}

/// Serves one phone project over a loopback-only HTTP server for the embedded
/// WebView. It never binds to a LAN address and resolves files through the
/// same project path checks as the project file manager.
class LocalPreviewServer {
  LocalPreviewServer({this._files = const ProjectFileStore()});

  static const _maxLogEntries = 1000;

  final ProjectFileStore _files;
  final Map<String, _PreviewSession> _sessions = {};

  Future<LocalPreviewStatus> start(
    Project project, {
    String entrypoint = 'index.html',
  }) async {
    final normalizedEntrypoint = _normalizeEntrypoint(entrypoint);
    final current = _sessions[project.id];
    if (current != null &&
        current.project.localPath == project.localPath &&
        current.entrypoint == normalizedEntrypoint) {
      return current.status;
    }
    if (current != null) {
      _sessions.remove(project.id);
      await current.close();
    }

    await _files.ensureRoot(project);
    final server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
      shared: false,
    );
    final session = _PreviewSession(
      project: project,
      entrypoint: normalizedEntrypoint,
      server: server,
      files: _files,
      maxLogEntries: _maxLogEntries,
    );
    _sessions[project.id] = session;
    server.listen(
      (request) => unawaited(_serve(session, request)),
      onError: (Object error, StackTrace stack) {
        session.setError('$error');
        session.addLog(
          level: 'error',
          source: 'server',
          message: '本地预览服务错误：$error',
        );
      },
    );
    session.addLog(
      level: 'info',
      source: 'server',
      message: '本地预览已启动：${session.status.url}',
    );
    return session.status;
  }

  LocalPreviewStatus status(Project project) {
    return _sessions[project.id]?.status ??
        LocalPreviewStatus(
          projectId: project.id,
          projectName: project.name,
          running: false,
          entrypoint: 'index.html',
        );
  }

  List<LocalPreviewLog> logs(
    Project project, {
    int after = 0,
    int limit = 100,
  }) {
    if (after < 0) throw ArgumentError.value(after, 'after');
    if (limit <= 0) throw ArgumentError.value(limit, 'limit');
    final session = _sessions[project.id];
    if (session == null) return const [];
    return session.logs(after: after, limit: limit);
  }

  void recordLog(
    Project project, {
    required String level,
    required String source,
    required String message,
    String? url,
  }) {
    final session = _sessions[project.id];
    if (session == null) return;
    session.addLog(level: level, source: source, message: message, url: url);
  }

  void clearLogs(Project project) {
    _sessions[project.id]?.clearLogs();
  }

  LocalPreviewStatus reload(Project project) {
    final session = _sessionOrThrow(project);
    session.reloadToken++;
    session.addLog(level: 'info', source: 'server', message: '已请求预览页面重新加载');
    return session.status;
  }

  Future<void> stop(Project project) async {
    final session = _sessions.remove(project.id);
    if (session != null) await session.close();
  }

  Future<LocalWebTestResult> testWeb(
    Project project, {
    String entrypoint = 'index.html',
  }) async {
    final normalizedEntrypoint = _normalizeEntrypoint(entrypoint);
    final issues = <LocalWebTestIssue>[];
    final checked = <String>[];
    final references = <_WebReference>[];

    String? html;
    try {
      html = await _files.readText(project, normalizedEntrypoint);
      checked.add(normalizedEntrypoint);
    } catch (error) {
      issues.add(
        LocalWebTestIssue(
          level: 'error',
          type: 'missing-entrypoint',
          source: normalizedEntrypoint,
          message: '找不到入口文件：$error',
        ),
      );
    }

    if (html != null) {
      references.addAll(_htmlReferences(normalizedEntrypoint, html));
      await _checkReferences(
        project,
        references,
        checked,
        issues,
        cssSources: <String>{},
      );
    }

    return LocalWebTestResult(
      projectId: project.id,
      projectName: project.name,
      entrypoint: normalizedEntrypoint,
      checkedFiles: List.unmodifiable(checked),
      issues: List.unmodifiable(issues),
    );
  }

  Future<void> close() async {
    final sessions = _sessions.values.toList(growable: false);
    _sessions.clear();
    await Future.wait([
      for (final session in sessions) session.close(),
    ], eagerError: false);
  }

  Future<void> _serve(_PreviewSession session, HttpRequest request) async {
    session.requestCount++;
    final response = request.response;
    var statusCode = HttpStatus.ok;
    try {
      if (request.method != 'GET' && request.method != 'HEAD') {
        statusCode = HttpStatus.methodNotAllowed;
        response.statusCode = statusCode;
        response.headers.set(HttpHeaders.allowHeader, 'GET, HEAD');
        await response.close();
        session.addRequestLog(request, statusCode);
        return;
      }

      var relativePath = request.uri.pathSegments.join('/');
      if (relativePath.isEmpty || request.uri.path.endsWith('/')) {
        relativePath = relativePath.isEmpty
            ? session.entrypoint
            : path_util.posix.join(relativePath, 'index.html');
      }
      final target = await session.files.resolveForIo(
        session.project,
        relativePath,
      );
      final type = await FileSystemEntity.type(target, followLinks: false);
      if (type != FileSystemEntityType.file) {
        statusCode = HttpStatus.notFound;
        await _writeError(response, statusCode, 'Not found');
        session.addRequestLog(request, statusCode);
        return;
      }

      final file = File(target);
      var bytes = await file.readAsBytes();
      final contentType = _contentTypeFor(relativePath);
      if (_isHtml(relativePath)) {
        try {
          final html = utf8.decode(bytes);
          bytes = utf8.encode(_injectErrorHook(html));
        } on FormatException {
          // A non-UTF-8 file is served unchanged and will report its own
          // loading error through the WebView if it cannot be displayed.
        }
      }
      response.statusCode = statusCode;
      response.headers.contentLength = bytes.length;
      response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      response.headers.set(HttpHeaders.contentTypeHeader, contentType);
      if (request.method == 'GET') response.add(bytes);
      await response.close();
      session.addRequestLog(request, statusCode);
    } catch (error) {
      statusCode = error is ArgumentError || error is StateError
          ? HttpStatus.notFound
          : HttpStatus.internalServerError;
      try {
        await _writeError(response, statusCode, '$error');
      } catch (_) {
        try {
          await response.close();
        } catch (_) {}
      }
      if (statusCode >= 500) session.setError('$error');
      session.addRequestLog(request, statusCode);
    }
  }

  Future<void> _checkReferences(
    Project project,
    List<_WebReference> references,
    List<String> checked,
    List<LocalWebTestIssue> issues, {
    required Set<String> cssSources,
  }) async {
    final pending = <_WebReference>[...references];
    final checkedReferences = <String>{};
    while (pending.isNotEmpty) {
      final reference = pending.removeAt(0);
      final key = '${reference.source}\u0000${reference.value}';
      if (!checkedReferences.add(key)) continue;
      final resolved = _resolveReference(reference);
      if (resolved == null) {
        if (_isLocalReference(reference.value)) {
          issues.add(
            LocalWebTestIssue(
              level: 'error',
              type: 'path-outside-project',
              source: reference.source,
              resource: reference.value,
              message: '资源路径不能离开项目文件夹：${reference.value}',
            ),
          );
        }
        continue;
      }
      try {
        final resolvedPath = await _files.resolveForIo(project, resolved);
        final type = await FileSystemEntity.type(
          resolvedPath,
          followLinks: false,
        );
        if (type != FileSystemEntityType.file) {
          issues.add(
            LocalWebTestIssue(
              level: 'error',
              type: 'missing-resource',
              source: reference.source,
              resource: resolved,
              message: '找不到本地资源：$resolved',
            ),
          );
          continue;
        }
        if (!checked.contains(resolved)) checked.add(resolved);
        if (path_util.posix.extension(resolved).toLowerCase() == '.css' &&
            cssSources.add(resolved)) {
          try {
            final css = await _files.readText(project, resolved);
            pending.addAll(_cssReferences(resolved, css));
          } on Object catch (error) {
            issues.add(
              LocalWebTestIssue(
                level: 'warning',
                type: 'unreadable-resource',
                source: reference.source,
                resource: resolved,
                message: '无法读取 CSS 资源：$error',
              ),
            );
          }
        }
      } on Object catch (error) {
        issues.add(
          LocalWebTestIssue(
            level: 'error',
            type: 'missing-resource',
            source: reference.source,
            resource: resolved,
            message: '资源无法访问：$error',
          ),
        );
      }
    }
  }

  List<_WebReference> _htmlReferences(String source, String html) {
    final references = <_WebReference>[];
    final tagPattern = RegExp(
      r'''<(?:script|link|img|source|audio|video|iframe|object)\b[^>]*>''',
      caseSensitive: false,
      multiLine: true,
    );
    final attributePattern = RegExp(
      r'''(?:src|href|data)\s*=\s*["']([^"']+)["']''',
      caseSensitive: false,
    );
    for (final tag in tagPattern.allMatches(html)) {
      final value = tag.group(0) ?? '';
      final match = attributePattern.firstMatch(value);
      if (match != null) {
        references.add(_WebReference(source, match.group(1)!));
      }
    }
    return references;
  }

  List<_WebReference> _cssReferences(String source, String css) {
    final pattern = RegExp(
      r'''url\(\s*["']?([^\)"']+)["']?\s*\)''',
      caseSensitive: false,
    );
    return [
      for (final match in pattern.allMatches(css))
        _WebReference(source, match.group(1)!.trim()),
    ];
  }

  String? _resolveReference(_WebReference reference) {
    final raw = reference.value.trim().split(RegExp(r'[?#]')).first;
    if (raw.isEmpty || !_isLocalReference(raw)) return null;
    final sourceDirectory = path_util.posix.dirname(reference.source);
    final candidate = raw.startsWith('/')
        ? raw.substring(1)
        : path_util.posix.join(sourceDirectory, raw);
    try {
      return ProjectFileStore.normalizeRelativePath(candidate);
    } on ArgumentError {
      return null;
    }
  }

  bool _isLocalReference(String value) {
    final lower = value.trim().toLowerCase();
    if (lower.isEmpty || lower.startsWith('#')) return false;
    if (lower.startsWith('//') || lower.startsWith('data:')) return false;
    if (lower.startsWith('blob:') || lower.startsWith('javascript:')) {
      return false;
    }
    if (lower.startsWith('mailto:') || lower.startsWith('tel:')) return false;
    final parsed = Uri.tryParse(value);
    return parsed == null || !parsed.hasScheme;
  }

  _PreviewSession _sessionOrThrow(Project project) {
    final session = _sessions[project.id];
    if (session == null) throw StateError('本地预览尚未启动');
    return session;
  }

  static String _normalizeEntrypoint(String value) {
    final normalized = ProjectFileStore.normalizeRelativePath(
      value.trim().isEmpty ? 'index.html' : value,
    );
    if (normalized.isEmpty) throw ArgumentError('入口文件不能为空');
    return normalized;
  }

  static String _contentTypeFor(String filePath) {
    switch (path_util.posix.extension(filePath).toLowerCase()) {
      case '.html':
      case '.htm':
        return 'text/html; charset=utf-8';
      case '.css':
        return 'text/css; charset=utf-8';
      case '.js':
      case '.mjs':
        return 'text/javascript; charset=utf-8';
      case '.json':
        return 'application/json; charset=utf-8';
      case '.svg':
        return 'image/svg+xml';
      case '.png':
        return 'image/png';
      case '.jpg':
      case '.jpeg':
        return 'image/jpeg';
      case '.gif':
        return 'image/gif';
      case '.webp':
        return 'image/webp';
      case '.ico':
        return 'image/x-icon';
      case '.wasm':
        return 'application/wasm';
      default:
        return 'application/octet-stream';
    }
  }

  static Future<void> _writeError(
    HttpResponse response,
    int statusCode,
    String message,
  ) async {
    response.statusCode = statusCode;
    response.headers.contentType = ContentType.text;
    response.add(utf8.encode(message));
    await response.close();
  }

  static bool _isHtml(String filePath) {
    final extension = path_util.posix.extension(filePath).toLowerCase();
    return extension == '.html' || extension == '.htm';
  }

  static String _injectErrorHook(String html) {
    final script = '<script>\n$localPreviewErrorHookScript\n</script>\n';
    final head = RegExp(
      r'<head\b[^>]*>',
      caseSensitive: false,
    ).firstMatch(html);
    if (head != null) {
      return '${html.substring(0, head.end)}$script${html.substring(head.end)}';
    }
    return '$script$html';
  }
}

class _WebReference {
  const _WebReference(this.source, this.value);

  final String source;
  final String value;
}

class _PreviewSession {
  _PreviewSession({
    required this.project,
    required this.entrypoint,
    required this.server,
    required this.files,
    required this.maxLogEntries,
  });

  final Project project;
  final String entrypoint;
  final HttpServer server;
  final ProjectFileStore files;
  final int maxLogEntries;
  final DateTime startedAt = DateTime.now().toUtc();
  final List<LocalPreviewLog> _logs = [];
  int requestCount = 0;
  int reloadToken = 0;
  int _sequence = 0;
  String? lastError;
  bool _closed = false;

  LocalPreviewStatus get status => LocalPreviewStatus(
    projectId: project.id,
    projectName: project.name,
    running: !_closed,
    entrypoint: entrypoint,
    url: _closed ? null : _url,
    startedAt: startedAt,
    requestCount: requestCount,
    reloadToken: reloadToken,
    lastError: lastError,
    logSequence: _sequence,
  );

  String get _url => Uri(
    scheme: 'http',
    host: InternetAddress.loopbackIPv4.host,
    port: server.port,
    path: '/$entrypoint',
  ).toString();

  void setError(String value) {
    lastError = value;
  }

  void addRequestLog(HttpRequest request, int statusCode) {
    addLog(
      level: statusCode >= 400 ? 'error' : 'info',
      source: 'http',
      message: '${request.method} ${request.uri.path} -> $statusCode',
      url: request.uri.toString(),
    );
  }

  void addLog({
    required String level,
    required String source,
    required String message,
    String? url,
  }) {
    _sequence++;
    _logs.add(
      LocalPreviewLog(
        sequence: _sequence,
        timestamp: DateTime.now().toUtc(),
        level: level,
        source: source,
        message: message,
        url: url,
      ),
    );
    if (_logs.length > maxLogEntries) {
      _logs.removeRange(0, _logs.length - maxLogEntries);
    }
  }

  List<LocalPreviewLog> logs({required int after, required int limit}) {
    return List.unmodifiable(
      _logs.where((log) => log.sequence > after).take(limit),
    );
  }

  void clearLogs() {
    _logs.clear();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await server.close(force: true);
  }
}
