import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_agent/ssh/resumable_file_upload.dart';

void main() {
  test(
    'resumes from the remote offset and commits only after all chunks',
    () async {
      final source = Uint8List.fromList([1, 2, 3, 4, 5]);
      final reads = <int>[];
      final writes = <({int offset, Uint8List bytes})>[];
      SshFileUploadSession? committed;

      final uploaded = await const ResumableFileUploader().upload(
        totalBytes: source.length,
        chunkBytes: 2,
        prepare: () async => const SshFileUploadSession(
          targetPath: '/tmp/file.bin',
          temporaryPath: '/tmp/file.bin.mobile-agent.part',
          metadataPath: '/tmp/file.bin.mobile-agent.part.json',
          offset: 2,
          totalBytes: 5,
        ),
        readChunk: (offset, length) async {
          reads.add(offset);
          return Uint8List.sublistView(source, offset, offset + length);
        },
        writeChunk: (session, bytes, offset) async {
          writes.add((offset: offset, bytes: Uint8List.fromList(bytes)));
        },
        commit: (session) async => committed = session,
      );

      expect(uploaded, 5);
      expect(reads, [2, 4]);
      expect(writes.map((write) => write.offset), [2, 4]);
      expect(writes.map((write) => write.bytes), [
        [3, 4],
        [5],
      ]);
      expect(committed, isNotNull);
    },
  );
}
