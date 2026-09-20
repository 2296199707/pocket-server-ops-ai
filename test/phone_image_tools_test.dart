import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_agent/agent/ai_protocol.dart';
import 'package:mobile_agent/agent/phone_image_tools.dart';
import 'package:mobile_agent/domain/models.dart';
import 'package:mobile_agent/local/local_file_access.dart';
import 'package:mobile_agent/local/local_preview.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=',
  );

  test(
    'image viewing preserves pixels and existing directory authorization',
    () async {
      final root = await Directory.systemTemp.createTemp('vision-');
      final outside = await Directory.systemTemp.createTemp('vision-outside-');
      final preview = LocalPreviewServer();
      addTearDown(() async {
        await preview.close();
        await root.delete(recursive: true);
        await outside.delete(recursive: true);
      });
      await File('${root.path}/asset.png').writeAsBytes(png);
      await File('${outside.path}/asset.png').writeAsBytes(png);
      await Link('${root.path}/escape').create(outside.path);
      final access = LocalFileAccessStore();
      final tool = PhoneImageTools(
        project: Project(id: 'p', name: 'project', localPath: root.path),
        access: access,
        preview: preview,
        capture: (url, width, height) async => png,
        readAttachment: (_) async => throw StateError('missing'),
        persist: (name, mime, bytes) async => AiAttachment(
          id: 'saved',
          name: name,
          mimeType: mime,
          byteLength: bytes.length,
        ),
      );
      final result = await tool.view({
        'source': 'project',
        'path': 'asset.png',
      }) as AiToolResult;
      expect(result.attachments.single.base64Data, base64Encode(png));
      expect(jsonEncode(result.result), isNot(contains(base64Encode(png))));
      await expectLater(
        tool.view({'source': 'project', 'path': 'escape/asset.png'}),
        throwsStateError,
      );
      await expectLater(
        tool.view({'source': 'local', 'path': '${outside.path}/asset.png'}),
        throwsStateError,
      );
      await access.add(outside.path, canWrite: false);
      expect(
        await tool.view({
          'source': 'local',
          'path': '${outside.path}/asset.png',
        }),
        isA<AiToolResult>(),
      );
      await File('${root.path}/index.html').writeAsString('<h1>Preview</h1>');
      final screenshot = await tool.screenshot({}) as AiToolResult;
      expect(screenshot.attachments.single.mimeType, 'image/png');
      expect((screenshot.result as Map)['capture'], 'fresh_viewport');
    },
  );

  test('invalid files are not supplied as image pixels', () async {
    await expectLater(
      inspectToolImage(base64Decode('dGV4dA==')),
      throwsFormatException,
    );
  });
}
