import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_agent/agent/mcp_client.dart';
import 'package:mobile_agent/app_controller.dart';
import 'package:mobile_agent/credentials/credential_store.dart';
import 'package:mobile_agent/domain/models.dart';
import 'package:mobile_agent/storage/memory_app_database.dart';

void main() {
  late HttpServer server;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  });

  tearDown(() => server.close(force: true));

  test(
    'initializes, caches the session headers, lists and calls tools',
    () async {
      final requests = <Map<String, Object?>>[];
      server.listen((request) async {
        final body = await utf8.decoder.bind(request).join();
        final message = Map<String, Object?>.from(jsonDecode(body) as Map);
        requests.add(message);
        final method = message['method'];
        if (method == 'initialize') {
          request.response.headers.add('Mcp-Session-Id', 'session-1');
          await _jsonResponse(request, {
            'jsonrpc': '2.0',
            'id': message['id'],
            'result': {
              'protocolVersion': mcpProtocolVersion,
              'capabilities': {'tools': {}},
              'serverInfo': {'name': 'test-mcp', 'version': '1'},
            },
          });
          return;
        }
        if (method == 'notifications/initialized') {
          request.response.statusCode = 202;
          await request.response.close();
          return;
        }
        if (method == 'tools/list') {
          await _jsonResponse(request, {
            'jsonrpc': '2.0',
            'id': message['id'],
            'result': {
              'tools': [
                {
                  'name': 'inspect_apk',
                  'title': '分析 APK',
                  'description': '读取 APK 信息',
                  'inputSchema': {
                    'type': 'object',
                    'properties': {
                      'path': {'type': 'string'},
                    },
                    'required': ['path'],
                  },
                  'annotations': {'readOnlyHint': true},
                },
              ],
            },
          });
          return;
        }
        if (method == 'tools/call') {
          await _jsonResponse(request, {
            'jsonrpc': '2.0',
            'id': message['id'],
            'result': {
              'content': [
                {'type': 'text', 'text': '分析完成'},
              ],
              'structuredContent': {'ok': true},
              'isError': false,
            },
          });
          return;
        }
        request.response.statusCode = 404;
        await request.response.close();
      });

      final tokenReads = <int>[];
      final client = McpClient(
        url: 'http://${server.address.address}:${server.port}/mcp',
        tokenLoader: () async {
          tokenReads.add(1);
          return 'local-token';
        },
      );
      addTearDown(client.close);
      expect(client.requestTimeout, const Duration(minutes: 2));

      final tools = await client.listTools();
      final result = await client.callTool('inspect_apk', {'path': 'app.apk'});

      expect(tools.single.name, 'inspect_apk');
      expect((result as Map)['isError'], isFalse);
      expect(client.sessionId, 'session-1');
      expect(tokenReads, hasLength(4));
      expect(requests.map((item) => item['method']), [
        'initialize',
        'notifications/initialized',
        'tools/list',
        'tools/call',
      ]);
      expect(requests[2]['params'], isEmpty);
    },
  );

  test('applies an explicit MCP request timeout', () async {
    server.listen((request) async {
      await utf8.decoder.bind(request).join();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await _jsonResponse(request, {
        'jsonrpc': '2.0',
        'id': 1,
        'result': {'protocolVersion': mcpProtocolVersion},
      });
    });

    final client = McpClient(
      url: 'http://${server.address.address}:${server.port}/mcp',
      requestTimeout: const Duration(milliseconds: 10),
    );
    addTearDown(client.close);

    await expectLater(
      client.initialize(),
      throwsA(
        isA<McpException>().having(
          (error) => error.message,
          'message',
          contains('MCP 请求超时'),
        ),
      ),
    );
  });

  test(
    'reports a tools/list cursor loop without requesting a cursor twice',
    () async {
      final cursors = <String?>[];
      server.listen((request) async {
        final body = await utf8.decoder.bind(request).join();
        final message = Map<String, Object?>.from(jsonDecode(body) as Map);
        switch (message['method']) {
          case 'initialize':
            request.response.headers.add('Mcp-Session-Id', 'loop-session');
            await _jsonResponse(request, {
              'jsonrpc': '2.0',
              'id': message['id'],
              'result': {'protocolVersion': mcpProtocolVersion},
            });
          case 'notifications/initialized':
            request.response.statusCode = 202;
            await request.response.close();
          case 'tools/list':
            final params = Map<String, Object?>.from(message['params'] as Map);
            cursors.add(params['cursor'] as String?);
            final next = switch (params['cursor']) {
              null => 'A',
              'A' => 'B',
              'B' => 'A',
              _ => null,
            };
            await _jsonResponse(request, {
              'jsonrpc': '2.0',
              'id': message['id'],
              'result': {'tools': [], if (next != null) 'nextCursor': next},
            });
          default:
            request.response.statusCode = 404;
            await request.response.close();
        }
      });

      final client = McpClient(
        url: 'http://${server.address.address}:${server.port}/mcp',
      );
      addTearDown(client.close);

      await expectLater(
        client.listTools(),
        throwsA(
          isA<McpException>().having(
            (error) => error.message,
            'message',
            contains('分页 cursor 循环'),
          ),
        ),
      );
      expect(cursors, [null, 'A', 'B']);
    },
  );

  test('accepts a standard SSE response for tools/list', () async {
    server.listen((request) async {
      final body = await utf8.decoder.bind(request).join();
      final message = Map<String, Object?>.from(jsonDecode(body) as Map);
      if (message['method'] == 'initialize') {
        request.response.headers.add('Mcp-Session-Id', 'sse-session');
        await _jsonResponse(request, {
          'jsonrpc': '2.0',
          'id': message['id'],
          'result': {'protocolVersion': mcpProtocolVersion},
        });
      } else if (message['method'] == 'notifications/initialized') {
        request.response.statusCode = 202;
        await request.response.close();
      } else {
        request.response.headers.set('content-type', 'text/event-stream');
        request.response.write(
          'event: message\ndata: ${jsonEncode({
            'jsonrpc': '2.0',
            'id': message['id'],
            'result': {'tools': []},
          })}\n\n',
        );
        await request.response.close();
      }
    });

    final client = McpClient(
      url: 'http://${server.address.address}:${server.port}/mcp',
    );
    addTearDown(client.close);

    expect(await client.listTools(), isEmpty);
  });

  test('reinitializes a lost session without replaying a tool call', () async {
    var initializeCount = 0;
    var listCount = 0;
    server.listen((request) async {
      final body = await utf8.decoder.bind(request).join();
      final message = Map<String, Object?>.from(jsonDecode(body) as Map);
      switch (message['method']) {
        case 'initialize':
          initializeCount++;
          request.response.headers.add(
            'Mcp-Session-Id',
            'session-$initializeCount',
          );
          await _jsonResponse(request, {
            'jsonrpc': '2.0',
            'id': message['id'],
            'result': {'protocolVersion': mcpProtocolVersion},
          });
        case 'notifications/initialized':
          request.response.statusCode = 202;
          await request.response.close();
        case 'tools/list':
          listCount++;
          if (listCount == 1) {
            request.response.statusCode = 404;
            await request.response.close();
          } else {
            await _jsonResponse(request, {
              'jsonrpc': '2.0',
              'id': message['id'],
              'result': {'tools': []},
            });
          }
        default:
          request.response.statusCode = 404;
          await request.response.close();
      }
    });

    final client = McpClient(
      url: 'http://${server.address.address}:${server.port}/mcp',
    );
    addTearDown(client.close);

    expect(await client.listTools(), isEmpty);
    expect(initializeCount, 2);
    expect(listCount, 2);
    expect(client.sessionId, 'session-2');
  });

  test(
    'MCP configuration persists without putting its token in settings',
    () async {
      final database = MemoryAppDatabase();
      final credentials = MemoryCredentialStore();
      final controller = AppController(
        database: database,
        credentials: credentials,
      );
      await controller.load();

      final saved = await controller.saveMcpServer(
        name: '手机 MCP',
        url: 'http://127.0.0.1:8787/mcp',
        enabled: true,
        token: 'secret-token',
      );
      final stored = await database.readSetting('mcp_servers');
      expect(stored, isNot(contains('secret-token')));
      expect(await credentials.read(saved.tokenRef!), 'secret-token');

      final reloaded = AppController(
        database: database,
        credentials: credentials,
      );
      await reloaded.load();
      expect(reloaded.mcpServers.single.url, saved.url);
      expect(reloaded.mcpServers.single.tools, isEmpty);
      controller.dispose();
      reloaded.dispose();
    },
  );

  test('cached MCP definitions become namespaced Agent tools', () {
    final profile = McpServerProfile(
      id: 'mcp-1',
      name: '手机工具',
      url: 'http://127.0.0.1:8787/mcp',
      tools: const [
        McpToolProfile(
          name: 'inspect.apk',
          description: '分析 APK',
          inputSchema: {'type': 'object'},
          annotations: {'readOnlyHint': true},
        ),
        McpToolProfile(
          name: 'rebuild.apk',
          description: '重新打包 APK',
          inputSchema: {'type': 'object'},
        ),
      ],
    );
    final client = McpClient(url: profile.url);
    addTearDown(client.close);

    final tools = McpAgentTools(profile: profile, client: client).tools;
    expect(tools.map((tool) => tool.definition.name), [
      'mcp_mcp-1__inspect_apk',
      'mcp_mcp-1__rebuild_apk',
    ]);
    expect(tools.first.requiresConfirmation, isFalse);
    expect(tools.last.requiresConfirmation, isTrue);
    expect(tools.last.writesRemoteState, isTrue);
  });
}

Future<void> _jsonResponse(
  HttpRequest request,
  Map<String, Object?> value,
) async {
  request.response.headers.contentType = ContentType.json;
  request.response.write(jsonEncode(value));
  await request.response.close();
}
