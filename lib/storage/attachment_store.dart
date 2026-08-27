import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../domain/models.dart';

class AttachmentCleanupResult {
  const AttachmentCleanupResult({
    required this.removedFiles,
    required this.removedBytes,
  });

  final int removedFiles;
  final int removedBytes;
}

class AttachmentStore {
  AttachmentStore({Future<Directory> Function()? rootProvider})
    : _rootProvider = rootProvider ?? _defaultRoot;

  final Future<Directory> Function() _rootProvider;

  static Future<Directory> _defaultRoot() async {
    final support = await getApplicationSupportDirectory();
    return Directory(path.join(support.path, 'attachments'));
  }

  Future<void> write(AttachmentRecord record, Uint8List bytes) async {
    final root = await _rootProvider();
    final target = File(path.join(root.path, record.storagePath));
    await target.parent.create(recursive: true);
    final temporary = File('${target.path}.tmp');
    await temporary.writeAsBytes(bytes, flush: true);
    if (await target.exists()) await target.delete();
    await temporary.rename(target.path);
    if (await target.length() != bytes.length) {
      throw FileSystemException('附件写入不完整', target.path);
    }
  }

  Future<Uint8List> read(AttachmentRecord record) async {
    final root = await _rootProvider();
    return File(path.join(root.path, record.storagePath)).readAsBytes();
  }

  Future<void> delete(AttachmentRecord record) async {
    final root = await _rootProvider();
    final file = File(path.join(root.path, record.storagePath));
    if (await file.exists()) await file.delete();
  }

  Future<void> deleteTask(String taskId) async {
    final root = await _rootProvider();
    final directory = Directory(path.join(root.path, taskId));
    if (await directory.exists()) await directory.delete(recursive: true);
  }

  Future<AttachmentCleanupResult> removeExcept(
    Set<String> retainedPaths,
  ) async {
    final root = await _rootProvider();
    if (!await root.exists()) {
      return const AttachmentCleanupResult(removedFiles: 0, removedBytes: 0);
    }
    var removedFiles = 0;
    var removedBytes = 0;
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (await FileSystemEntity.type(entity.path, followLinks: false) !=
          FileSystemEntityType.file) {
        continue;
      }
      final relative = path.relative(entity.path, from: root.path);
      if (retainedPaths.contains(relative)) continue;
      try {
        final file = File(entity.path);
        final length = await file.length();
        await file.delete();
        removedFiles++;
        removedBytes += length;
      } on FileSystemException {
        // A file that cannot be removed can be retried by the next cleanup.
      }
    }
    return AttachmentCleanupResult(
      removedFiles: removedFiles,
      removedBytes: removedBytes,
    );
  }
}
