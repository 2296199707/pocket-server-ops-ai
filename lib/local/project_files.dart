import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as path_util;
import 'package:path_provider/path_provider.dart';

import '../domain/models.dart';

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

  Future<List<ProjectFileEntry>> list(
    Project project,
    String relativePath,
  ) async {
    final directory = Directory(resolve(project, relativePath));
    final entries = <ProjectFileEntry>[];
    await for (final entity in directory.list(followLinks: false)) {
      final type = await FileSystemEntity.type(entity.path, followLinks: false);
      final name = path_util.basename(entity.path);
      final childPath = _relativePath(project, entity.path);
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
    final file = await File(resolve(project, relativePath)).open();
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
    return File(resolve(project, relativePath)).readAsString();
  }

  Future<void> writeText(
    Project project,
    String relativePath,
    String content,
  ) {
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
    final target = File(resolve(project, relativePath));
    await target.parent.create(recursive: true);
    await target.writeAsBytes(bytes, flush: true);
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
    await writeText(project, relativePath, current.replaceFirst(oldText, newText));
  }

  Future<void> createFile(Project project, String relativePath) async {
    final target = File(resolve(project, relativePath));
    await target.parent.create(recursive: true);
    if (!await target.exists()) await target.writeAsString('');
  }

  Future<void> createDirectory(Project project, String relativePath) {
    return Directory(resolve(project, relativePath)).create(recursive: true);
  }

  String resolve(Project project, String relativePath) {
    final normalized = _normalizeRelativePath(relativePath);
    return normalized.isEmpty
        ? project.localPath
        : path_util.joinAll([project.localPath, ...normalized.split('/')]);
  }

  String _relativePath(Project project, String absolutePath) {
    final relative = path_util.relative(
      absolutePath,
      from: project.localPath,
    );
    return relative == '.' ? '' : relative.replaceAll(path_util.separator, '/');
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
