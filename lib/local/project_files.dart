import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as path_util;
import 'package:path_provider/path_provider.dart';

import '../domain/models.dart';
import 'local_file_access.dart';

class ProjectFileEntry {
  const ProjectFileEntry({
    required this.name,
    required this.path,
    required this.isDirectory,
    this.size,
  });

  final String name;
  final String path;
  final bool isDirectory;
  final int? size;
}

class ProjectFileChunk {
  const ProjectFileChunk({
    required this.offset,
    required this.nextOffset,
    required this.content,
    required this.eof,
    this.totalBytes,
  });

  final int offset;
  final int nextOffset;
  final String content;
  final bool eof;
  final int? totalBytes;
}

class ProjectFileStore {
  const ProjectFileStore();

  static Future<String> defaultProjectPath(String projectId) async {
    final documents = await getApplicationDocumentsDirectory();
    return path_util.join(
      documents.path,
      'PocketServerOps',
      'projects',
      projectId,
    );
  }

  Future<void> ensureRoot(Project project) async {
    await Directory(project.localPath).create(recursive: true);
  }

  /// Delete the contents of the bound project directory but keep the root
  /// directory itself. Symlinks are listed without following them, so a link
  /// inside the project is removed as a link rather than traversed.
  Future<void> deleteContents(Project project) async {
    final root = await _canonicalProjectRoot(project);
    if (path_util.posix.dirname(root) == root) {
      throw StateError('不能删除文件系统根目录的内容');
    }
    final directory = Directory(root);
    await for (final entity in directory.list(followLinks: false)) {
      await entity.delete(recursive: true);
    }
  }

  Future<List<ProjectFileEntry>> list(
    Project project,
    String relativePath,
  ) async {
    final root = await _canonicalProjectRoot(project);
    final directory = Directory(await _resolveForIo(project, relativePath));
    final entries = <ProjectFileEntry>[];
    await for (final entity in directory.list(followLinks: false)) {
      final type = await FileSystemEntity.type(entity.path, followLinks: false);
      final name = path_util.basename(entity.path);
      final childPath = _relativePath(root, entity.path);
      int? size;
      if (type == FileSystemEntityType.file) {
        try {
          size = await File(entity.path).length();
        } on FileSystemException {
          size = null;
        }
      }
      if (type == FileSystemEntityType.directory ||
          type == FileSystemEntityType.file) {
        entries.add(
          ProjectFileEntry(
            name: name,
            path: childPath,
            isDirectory: type == FileSystemEntityType.directory,
            size: size,
          ),
        );
      }
    }
    entries.sort((left, right) {
      if (left.isDirectory != right.isDirectory) {
        return left.isDirectory ? -1 : 1;
      }
      return left.name.compareTo(right.name);
    });
    return entries;
  }

  Future<ProjectFileChunk> readChunk(
    Project project,
    String relativePath, {
    int offset = 0,
    int length = 64 * 1024,
  }) async {
    if (offset < 0) throw ArgumentError.value(offset, 'offset');
    if (length <= 0) throw ArgumentError.value(length, 'length');
    final file = await File(await _resolveForIo(project, relativePath)).open();
    try {
      final totalBytes = await file.length();
      if (offset >= totalBytes) {
        return ProjectFileChunk(
          offset: offset,
          nextOffset: offset,
          content: '',
          eof: true,
          totalBytes: totalBytes,
        );
      }
      await file.setPosition(offset);
      final bytes = await file.read(length + 3);
      var end = bytes.length;
      while (end > 0) {
        try {
          utf8.decode(bytes.sublist(0, end));
          break;
        } on FormatException {
          end--;
        }
      }
      final nextOffset = offset + end;
      return ProjectFileChunk(
        offset: offset,
        nextOffset: nextOffset,
        content: utf8.decode(bytes.sublist(0, end)),
        eof: nextOffset >= totalBytes,
        totalBytes: totalBytes,
      );
    } finally {
      await file.close();
    }
  }

  Future<String> readText(Project project, String relativePath) async {
    return File(await _resolveForIo(project, relativePath)).readAsString();
  }

  Future<void> writeText(Project project, String relativePath, String content) {
    return writeBytes(
      project,
      relativePath,
      Uint8List.fromList(utf8.encode(content)),
    );
  }

  Future<void> writeBytes(
    Project project,
    String relativePath,
    Uint8List bytes,
  ) async {
    final target = File(await _resolveForIo(project, relativePath));
    await target.parent.create(recursive: true);
    final temporary = File(
      '${target.path}.mobile-agent-${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    var committed = false;
    try {
      await temporary.writeAsBytes(bytes, flush: true);
      await temporary.rename(target.path);
      committed = true;
    } finally {
      if (!committed && await temporary.exists()) {
        try {
          await temporary.delete();
        } catch (_) {
          // A leftover temporary file can be removed by the next cleanup.
        }
      }
    }
  }

  Future<void> replaceText(
    Project project,
    String relativePath,
    String oldText,
    String newText,
  ) async {
    if (oldText.isEmpty) {
      throw ArgumentError.value(oldText, 'oldText', 'must not be empty');
    }
    final current = await readText(project, relativePath);
    if (_countOccurrences(current, oldText) != 1) {
      throw StateError('replaceText requires exactly one matching block');
    }
    await writeText(
      project,
      relativePath,
      current.replaceFirst(oldText, newText),
    );
  }

  Future<void> createFile(Project project, String relativePath) async {
    final target = File(await _resolveForIo(project, relativePath));
    await target.parent.create(recursive: true);
    if (!await target.exists()) await target.writeAsString('');
  }

  Future<void> createDirectory(Project project, String relativePath) {
    return _resolveForIo(
      project,
      relativePath,
    ).then((resolved) => Directory(resolved).create(recursive: true));
  }

  Future<bool> exists(Project project, String relativePath) async {
    final resolved = await _resolveForIo(project, relativePath);
    return await FileSystemEntity.type(resolved, followLinks: false) !=
        FileSystemEntityType.notFound;
  }

  String resolve(Project project, String relativePath) {
    final normalized = _normalizeRelativePath(relativePath);
    return normalized.isEmpty
        ? project.localPath
        : path_util.joinAll([project.localPath, ...normalized.split('/')]);
  }

  /// Resolve a project path after checking every existing path component.
  ///
  /// Local preview uses this instead of joining paths directly so a symbolic
  /// link inside a project cannot expose a file outside the project root.
  Future<String> resolveForIo(Project project, String relativePath) {
    return _resolveForIo(project, relativePath);
  }

  static String normalizeRelativePath(String value) {
    return _normalizeRelativePath(value);
  }

  String _relativePath(String rootPath, String absolutePath) {
    final relative = path_util.relative(absolutePath, from: rootPath);
    return relative == '.' ? '' : relative.replaceAll(path_util.separator, '/');
  }

  Future<String> _canonicalProjectRoot(Project project) {
    return LocalFileAccessStore.canonicalExistingPath(project.localPath);
  }

  Future<String> _resolveForIo(Project project, String relativePath) async {
    final root = await _canonicalProjectRoot(project);
    final normalized = _normalizeRelativePath(relativePath);
    if (normalized.isEmpty) return root;

    var current = root;
    final parts = normalized.split('/');
    for (var index = 0; index < parts.length; index++) {
      final candidate = path_util.join(current, parts[index]);
      final type = await FileSystemEntity.type(candidate, followLinks: false);
      if (type == FileSystemEntityType.notFound) {
        return path_util.joinAll([current, ...parts.sublist(index)]);
      }

      final resolved = await LocalFileAccessStore.canonicalExistingPath(
        candidate,
      );
      if (!LocalFileAccessStore.isWithinCanonical(resolved, root)) {
        throw StateError('项目文件路径不能通过符号链接离开项目文件夹');
      }
      if (index < parts.length - 1 &&
          await FileSystemEntity.type(resolved, followLinks: false) !=
              FileSystemEntityType.directory) {
        throw StateError('项目路径中的目录组件不是目录');
      }
      current = resolved;
    }
    return current;
  }

  static String _normalizeRelativePath(String value) {
    final source = value.trim().replaceAll('\\', '/');
    if (source.isEmpty || source == '.') return '';
    if (source.startsWith('/') || path_util.posix.isAbsolute(source)) {
      throw ArgumentError('项目文件路径必须是相对路径');
    }
    final normalized = path_util.posix.normalize(source);
    if (normalized == '..' || normalized.startsWith('../')) {
      throw ArgumentError('项目文件路径不能离开项目文件夹');
    }
    return normalized;
  }

  static int _countOccurrences(String value, String needle) {
    var count = 0;
    var offset = 0;
    while (true) {
      final index = value.indexOf(needle, offset);
      if (index < 0) return count;
      count++;
      offset = index + needle.length;
    }
  }
}
