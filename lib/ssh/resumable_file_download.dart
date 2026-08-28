import 'dart:convert';
import 'dart:io';

import 'ssh_connection.dart';

typedef RemoteFileBytesReader = Future<SshFileBytesChunk> Function(int offset);
typedef FileDownloadProgress = void Function(int received, int? total);

class ResumableFileDownloader {
  const ResumableFileDownloader();

  Future<File> download({
    required File target,
    required String sourceKey,
    required RemoteFileBytesReader readChunk,
    bool overwrite = false,
    FileDownloadProgress? onProgress,
  }) async {
    final normalizedSource = sourceKey.trim();
    if (normalizedSource.isEmpty) {
      throw ArgumentError.value(sourceKey, 'sourceKey');
    }
    if (!overwrite && await target.exists()) {
      throw StateError('目标文件已存在：${target.path}');
    }
    await target.parent.create(recursive: true);

    final partial = File('${target.path}.part');
    final metadataFile = File('${partial.path}.json');
    var metadata = await _readMetadata(metadataFile);
    if (metadata != null && metadata.sourceKey != normalizedSource) {
      await _reset(partial, metadataFile);
      metadata = null;
    }

    var offset = await partial.exists() ? await partial.length() : 0;
    var first = await readChunk(offset);
    var total = first.totalBytes ?? metadata?.totalBytes;
    if ((total != null && offset > total) ||
        (metadata?.totalBytes != null &&
            total != null &&
            metadata!.totalBytes != total)) {
      await _reset(partial, metadataFile);
      metadata = null;
      offset = 0;
      first = await readChunk(0);
      total = first.totalBytes;
    }
    if (first.offset != offset) {
      throw StateError('服务器返回了错误的文件偏移量');
    }
    await _writeMetadata(
      metadataFile,
      _DownloadMetadata(sourceKey: normalizedSource, totalBytes: total),
    );

    RandomAccessFile? output;
    try {
      output = await partial.open(mode: FileMode.append);
      onProgress?.call(offset, total);
      var chunk = first;
      while (true) {
        if (chunk.offset != offset) {
          throw StateError('服务器返回了错误的文件偏移量');
        }
        if (chunk.totalBytes != null) {
          if (total != null && chunk.totalBytes != total) {
            throw StateError('远程文件大小发生变化，请重新下载');
          }
          total = chunk.totalBytes;
          await _writeMetadata(
            metadataFile,
            _DownloadMetadata(sourceKey: normalizedSource, totalBytes: total),
          );
        }

        if (chunk.bytes.isEmpty) {
          if (chunk.eof || (total != null && offset >= total)) break;
          throw StateError('服务器返回了空的文件分块');
        }
        final nextOffset = offset + chunk.bytes.length;
        if (chunk.nextOffset != nextOffset) {
          throw StateError('服务器返回了无效的文件偏移量');
        }
        await output.writeFrom(chunk.bytes);
        await output.flush();
        offset = nextOffset;
        onProgress?.call(offset, total);
        if (chunk.eof || (total != null && offset >= total)) break;
        chunk = await readChunk(offset);
      }
      if (total != null && offset != total) {
        throw StateError('文件下载未完成');
      }
      await output.flush();
      await output.close();
      output = null;
      if (await target.exists()) await target.delete();
      await partial.rename(target.path);
      if (await metadataFile.exists()) await metadataFile.delete();
      return target;
    } finally {
      await output?.close();
    }
  }

  static Future<_DownloadMetadata?> _readMetadata(File file) async {
    if (!await file.exists()) return null;
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map || decoded['source_key'] is! String) return null;
      final total = decoded['total_bytes'];
      return _DownloadMetadata(
        sourceKey: decoded['source_key'] as String,
        totalBytes: total is int ? total : null,
      );
    } on FormatException {
      return null;
    } on FileSystemException {
      return null;
    }
  }

  static Future<void> _writeMetadata(File file, _DownloadMetadata metadata) {
    return file.writeAsString(
      jsonEncode({
        'source_key': metadata.sourceKey,
        if (metadata.totalBytes != null) 'total_bytes': metadata.totalBytes,
      }),
      flush: true,
    );
  }

  static Future<void> _reset(File partial, File metadata) async {
    if (await partial.exists()) await partial.delete();
    if (await metadata.exists()) await metadata.delete();
  }
}

class _DownloadMetadata {
  const _DownloadMetadata({required this.sourceKey, required this.totalBytes});

  final String sourceKey;
  final int? totalBytes;
}
