import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_agent/agent/agent_tools.dart';
import 'package:mobile_agent/agent/ai_protocol.dart';
import 'package:mobile_agent/agent/phone_image_tools.dart';
import 'package:mobile_agent/ssh/ssh_connection.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'server.view_image reads and persists a PNG without a project',
    () async {
      final root = await Directory.systemTemp.createTemp('server-image-');
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });

      final persisted = <_PersistedImage>[];
      final connection = _ImageConnection(_tinyPng());
      final tools = RemoteAgentTools(
        connection,
        workingDirectory: root.path,
        imageViewer: _viewer('initial', persisted),
      );
      addTearDown(tools.close);

      final view = tools.tools.singleWhere(
        (tool) => tool.definition.name == 'server.view_image',
      );
      final properties = view.definition.parameters['properties'] as Map;
      expect(view.definition.parameters['required'], contains('remote_path'));
      expect(properties['remote_path'], {'type': 'string'});
      expect(view.isRemote, isTrue);
      expect(view.requiresConfirmation, isFalse);
      expect(view.canRunConcurrently, isTrue);

      final relativePath = 'assets/pixel.png';
      final resolvedPath = '${root.path}/$relativePath';
      final first =
          await view.call({'remote_path': relativePath}) as AiToolResult;

      expect(connection.readPaths, [resolvedPath]);
      expect(persisted.single.mimeType, 'image/png');
      expect(persisted.single.bytes, orderedEquals(_tinyPng()));
      expect(first.attachments.single.id, 'ref-initial');
      expect(first.attachments.single.base64Data, base64Encode(_tinyPng()));
      expect((first.result as Map)['source'], 'initial');
      expect((first.result as Map)['remote_path'], resolvedPath);
      expect((first.result as Map)['attachment_id'], 'ref-initial');
      expect((first.result as Map)['width'], 1);
      expect((first.result as Map)['height'], 1);

      // The same tool callback reads the mutable viewer used by a new round.
      tools.imageViewer = _viewer('updated', persisted);
      final second =
          await view.call({'remote_path': resolvedPath}) as AiToolResult;

      expect(connection.readPaths, [resolvedPath, resolvedPath]);
      expect((second.result as Map)['source'], 'updated');
      expect(second.attachments.single.id, 'ref-updated');
    },
  );

  test(
    'the group routes image reads and preserves decorated results',
    () async {
      final firstRoot = await Directory.systemTemp.createTemp(
        'server-image-a-',
      );
      final secondRoot = await Directory.systemTemp.createTemp(
        'server-image-b-',
      );
      addTearDown(() async {
        if (await firstRoot.exists()) await firstRoot.delete(recursive: true);
        if (await secondRoot.exists()) await secondRoot.delete(recursive: true);
      });

      final firstPersisted = <_PersistedImage>[];
      final secondPersisted = <_PersistedImage>[];
      final firstConnection = _ImageConnection(_tinyPng());
      final secondConnection = _ImageConnection(_tinyPng());
      final group = RemoteAgentToolsGroup(
        runtimes: {
          'server-a': RemoteAgentTools(
            firstConnection,
            workingDirectory: firstRoot.path,
            imageViewer: _viewer('source-a', firstPersisted),
          ),
          'server-b': RemoteAgentTools(
            secondConnection,
            workingDirectory: secondRoot.path,
            imageViewer: _viewer('source-b', secondPersisted),
          ),
        },
        serverNames: const {'server-a': 'Build host', 'server-b': 'Test host'},
      );
      addTearDown(group.close);

      final view = group.tools.singleWhere(
        (tool) => tool.definition.name == 'server.view_image',
      );
      final properties = view.definition.parameters['properties'] as Map;
      expect(view.definition.parameters['required'], contains('server_id'));
      expect(properties['remote_path'], {'type': 'string'});
      expect(properties['server_id'], {
        'type': 'string',
        'description': '目标服务器 ID',
      });

      final firstPath = '${firstRoot.path}/first.png';
      final secondPath = '${secondRoot.path}/second.png';
      final first = await view.call({
        'server_id': 'server-a',
        'remote_path': 'first.png',
      }) as AiToolResult;
      final second = await view.call({
        'server_id': 'server-b',
        'remote_path': secondPath,
      }) as AiToolResult;

      expect(firstConnection.readPaths, [firstPath]);
      expect(secondConnection.readPaths, [secondPath]);
      _expectDecoratedImage(
        first,
        source: 'source-a',
        serverId: 'server-a',
        serverName: 'Build host',
        attachmentId: 'ref-source-a',
        remotePath: firstPath,
      );
      _expectDecoratedImage(
        second,
        source: 'source-b',
        serverId: 'server-b',
        serverName: 'Test host',
        attachmentId: 'ref-source-b',
        remotePath: secondPath,
      );
    },
  );

  test('invalid images and SSH errors do not persist bytes', () async {
    final persisted = <_PersistedImage>[];
    final invalidTools = RemoteAgentTools(
      _ImageConnection(Uint8List.fromList([1, 2, 3])),
      imageViewer: _viewer('invalid', persisted),
    );
    final failedTools = RemoteAgentTools(
      _ImageConnection(_tinyPng(), readError: StateError('read failed')),
      imageViewer: _viewer('failed', persisted),
    );
    addTearDown(invalidTools.close);
    addTearDown(failedTools.close);

    final invalidView = invalidTools.tools.singleWhere(
      (tool) => tool.definition.name == 'server.view_image',
    );
    final failedView = failedTools.tools.singleWhere(
      (tool) => tool.definition.name == 'server.view_image',
    );

    await expectLater(
      invalidView.call({'remote_path': 'not-an-image'}),
      throwsA(isA<FormatException>()),
    );
    await expectLater(
      failedView.call({'remote_path': 'unreadable.png'}),
      throwsA(isA<StateError>()),
    );
    expect(persisted, isEmpty);
  });
}

RemoteImageViewer _viewer(String source, List<_PersistedImage> persisted) {
  return (remotePath, readBytes) async {
    final bytes = await readBytes();
    return persistToolImageResult(
      'remote.png',
      bytes,
      {'source': source, 'remote_path': remotePath},
      persist: (name, mimeType, imageBytes) async {
        persisted.add(_PersistedImage(name, mimeType, imageBytes));
        return AiAttachment(
          id: 'ref-$source',
          name: name,
          mimeType: mimeType,
          byteLength: imageBytes.length,
        );
      },
    );
  };
}

void _expectDecoratedImage(
  AiToolResult result, {
  required String source,
  required String serverId,
  required String serverName,
  required String attachmentId,
  required String remotePath,
}) {
  final value = result.result as Map;
  expect(value['source'], source);
  expect(value['remote_path'], remotePath);
  expect(value['server_id'], serverId);
  expect(value['server_name'], serverName);
  expect(value['attachment_id'], attachmentId);
  expect(result.attachments, hasLength(1));
  expect(result.attachments.single.id, attachmentId);
  expect(result.attachments.single.mimeType, 'image/png');
  expect(result.attachments.single.base64Data, base64Encode(_tinyPng()));
}

Uint8List _tinyPng() => Uint8List.fromList(
  base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=',
  ),
);

class _PersistedImage {
  _PersistedImage(this.name, this.mimeType, Uint8List bytes)
    : bytes = Uint8List.fromList(bytes);

  final String name;
  final String mimeType;
  final Uint8List bytes;
}

class _ImageConnection implements SshConnection {
  _ImageConnection(this.bytes, {this.readError});

  final Uint8List bytes;
  final Object? readError;
  final readPaths = <String>[];
  var closed = false;

  @override
  final hostKey = const SshHostKey(
    type: 'ssh-ed25519',
    fingerprint: 'SHA256:test-image',
  );

  @override
  bool get isClosed => closed;

  @override
  Future<void> get done => Future.value();

  @override
  Future<Uint8List> readFileBytes(String remotePath) async {
    readPaths.add(remotePath);
    final error = readError;
    if (error != null) throw error;
    return Uint8List.fromList(bytes);
  }

  @override
  Future<void> close() async {
    closed = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw UnimplementedError(
      '${invocation.memberName} is not used by this test',
    );
  }
}
