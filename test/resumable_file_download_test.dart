import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_agent/ssh/resumable_file_download.dart';
import 'package:mobile_agent/ssh/ssh_connection.dart';

void main() {
  test('keeps a partial file and resumes from its byte offset', () async {
    final root = await Directory.systemTemp.createTemp(
      'mobile-agent-download-',
    );
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final target = File('${root.path}/nested/file.bin');
    final offsets = <int>[];
    var failFirstAttempt = true;

    Future<SshFileBytesChunk> readChunk(int offset) async {
      offsets.add(offset);
      if (offset == 3 && failFirstAttempt) {
        throw StateError('connection lost');
      }
      if (offset == 0) {
        return SshFileBytesChunk(
          offset: 0,
          nextOffset: 3,
          bytes: Uint8List.fromList([1, 2, 3]),
          eof: false,
          totalBytes: 6,
        );
      }
      return SshFileBytesChunk(
        offset: 3,
        nextOffset: 6,
        bytes: Uint8List.fromList([4, 5, 6]),
        eof: true,
        totalBytes: 6,
      );
    }

    const downloader = ResumableFileDownloader();
    await expectLater(
      downloader.download(
        target: target,
        sourceKey: 'server\u0000/tmp/file.bin',
        readChunk: readChunk,
      ),
      throwsStateError,
    );
    expect(offsets, [0, 3]);
    expect(await File('${target.path}.part').readAsBytes(), [1, 2, 3]);

    failFirstAttempt = false;
    offsets.clear();
    final result = await downloader.download(
      target: target,
      sourceKey: 'server\u0000/tmp/file.bin',
      readChunk: readChunk,
    );

    expect(offsets, [3]);
    expect(await result.readAsBytes(), [1, 2, 3, 4, 5, 6]);
    expect(await File('${target.path}.part').exists(), isFalse);
    expect(await File('${target.path}.part.json').exists(), isFalse);
  });
}
