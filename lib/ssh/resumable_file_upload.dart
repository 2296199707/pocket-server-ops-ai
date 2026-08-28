import 'dart:typed_data';

class SshFileUploadSession {
  const SshFileUploadSession({
    required this.targetPath,
    required this.temporaryPath,
    required this.metadataPath,
    required this.offset,
    required this.totalBytes,
    this.existingMode,
  });

  final String targetPath;
  final String temporaryPath;
  final String metadataPath;
  final int offset;
  final int totalBytes;
  final int? existingMode;
}

typedef LocalFileBytesReader = Future<Uint8List> Function(
  int offset,
  int length,
);
typedef RemoteFileBytesWriter = Future<void> Function(
  SshFileUploadSession session,
  Uint8List bytes,
  int offset,
);
typedef FileUploadSessionPreparer = Future<SshFileUploadSession> Function();
typedef FileUploadSessionCommitter = Future<void> Function(
  SshFileUploadSession session,
);
typedef FileUploadProgress = void Function(int uploaded, int total);

class ResumableFileUploader {
  const ResumableFileUploader();

  Future<int> upload({
    required int totalBytes,
    required FileUploadSessionPreparer prepare,
    required LocalFileBytesReader readChunk,
    required RemoteFileBytesWriter writeChunk,
    required FileUploadSessionCommitter commit,
    int chunkBytes = 512 * 1024,
    FileUploadProgress? onProgress,
  }) async {
    if (totalBytes < 0) {
      throw ArgumentError.value(totalBytes, 'totalBytes');
    }
    if (chunkBytes <= 0) {
      throw ArgumentError.value(chunkBytes, 'chunkBytes', 'must be positive');
    }
    final session = await prepare();
    if (session.totalBytes != totalBytes) {
      throw StateError('上传文件大小已变化，请重新上传');
    }
    if (session.offset < 0 || session.offset > totalBytes) {
      throw StateError('服务器返回了无效的上传偏移量');
    }

    var offset = session.offset;
    onProgress?.call(offset, totalBytes);
    while (offset < totalBytes) {
      final requestedLength = (totalBytes - offset).clamp(0, chunkBytes);
      final bytes = await readChunk(offset, requestedLength);
      if (bytes.isEmpty) {
        throw StateError('手机文件读取未完成');
      }
      if (bytes.length > requestedLength) {
        throw StateError('手机文件读取返回了过大的分块');
      }
      await writeChunk(session, bytes, offset);
      offset += bytes.length;
      onProgress?.call(offset, totalBytes);
    }
    await commit(session);
    return offset;
  }
}
