import 'dart:io';

import 'package:path/path.dart' as path_util;

import '../platform/android_storage_access.dart';

class LocalFileGrant {
  const LocalFileGrant({required this.rootPath, required this.canWrite});

  final String rootPath;
  final bool canWrite;
}

/// In-memory permissions for one conversation. They intentionally disappear
/// when the app restarts or the conversation is deleted.
class LocalFileAccessStore {
  LocalFileAccessStore([List<LocalFileGrant>? grants])
    : grants = grants ?? <LocalFileGrant>[];

  final List<LocalFileGrant> grants;

  Future<LocalFileGrant> add(
    String requestedPath, {
    required bool canWrite,
  }) async {
    final rootPath = await canonicalExistingPath(requestedPath);
    final grant = LocalFileGrant(rootPath: rootPath, canWrite: canWrite);
    grants.removeWhere((value) => value.rootPath == rootPath);
    grants.add(grant);
    return grant;
  }

  Future<bool> hasAccess(String requestedPath, {bool write = false}) async {
    return await find(requestedPath, write: write) != null;
  }

  Future<LocalFileGrant?> find(
    String requestedPath, {
    bool write = false,
  }) async {
    final candidate = await _canonicalCandidate(requestedPath);
    for (final grant in grants.reversed) {
      final root = await canonicalExistingPath(grant.rootPath);
      final rootType = await FileSystemEntity.type(root, followLinks: false);
      final inside = rootType == FileSystemEntityType.file
          ? candidate == root
          : _isWithin(candidate, root);
      if (inside && (!write || grant.canWrite)) return grant;
    }
    return null;
  }

  Future<String> resolve(String requestedPath, {bool write = false}) async {
    final candidate = await _canonicalCandidate(requestedPath);
    final grant = await find(requestedPath, write: write);
    if (grant == null) {
      throw StateError(
        write ? '本地文件没有写入授权：$requestedPath' : '本地文件没有访问授权：$requestedPath',
      );
    }
    await AndroidStorageAccess.ensureForPath(candidate);
    return candidate;
  }

  static Future<String> canonicalExistingPath(String requestedPath) async {
    final normalized = _absoluteNormalized(requestedPath);
    final type = await FileSystemEntity.type(normalized, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      throw StateError('本地路径不存在：$requestedPath');
    }
    return _resolveExisting(normalized, requestedPath);
  }

  static Future<String> _canonicalCandidate(String requestedPath) async {
    final normalized = _absoluteNormalized(requestedPath);
    final type = await FileSystemEntity.type(normalized, followLinks: false);
    if (type != FileSystemEntityType.notFound) {
      return _resolveExisting(normalized, requestedPath);
    }
    final parent = path_util.posix.dirname(normalized);
    final parentType = await FileSystemEntity.type(parent, followLinks: false);
    if (parentType == FileSystemEntityType.notFound) {
      throw StateError('本地父目录不存在：$requestedPath');
    }
    final resolvedParent = _normalizeResolved(
      await _resolveExisting(parent, requestedPath),
    );
    return path_util.posix.join(
      resolvedParent,
      path_util.posix.basename(normalized),
    );
  }

  static bool isWithinCanonical(String candidate, String root) {
    return _isWithin(candidate, root);
  }

  static Future<String> _resolveExisting(
    String normalized,
    String requestedPath,
  ) async {
    try {
      final type = await FileSystemEntity.type(normalized, followLinks: false);
      final entity = switch (type) {
        FileSystemEntityType.directory => Directory(normalized),
        FileSystemEntityType.link => Link(normalized),
        _ => File(normalized),
      };
      return _normalizeResolved(await entity.resolveSymbolicLinks());
    } on FileSystemException catch (error) {
      throw StateError('本地路径无法解析：$requestedPath (${error.message})');
    }
  }

  static String _absoluteNormalized(String value) {
    final normalized = value.trim().replaceAll('\\', '/');
    if (!path_util.posix.isAbsolute(normalized)) {
      throw ArgumentError('本地文件路径必须是绝对路径');
    }
    return path_util.posix.normalize(normalized);
  }

  static String _normalizeResolved(String value) {
    final normalized = path_util.posix.normalize(value);
    if (normalized.length > 1 && normalized.endsWith('/')) {
      return normalized.substring(0, normalized.length - 1);
    }
    return normalized;
  }

  static bool _isWithin(String candidate, String root) {
    return candidate == root || candidate.startsWith('$root/');
  }
}
