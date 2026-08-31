import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile_agent/relay/computer_relay_client.dart';

void main() {
  test(
    'device status keeps relay success when the Windows Agent is offline',
    () async {
      final relay = ComputerRelayClient(
        baseUrl: 'https://relay.example.com/computer-relay',
        apiToken: 'relay-token',
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'device_id': 'computer-1',
              'online': false,
              'last_seen': null,
            }),
            200,
          ),
        ),
      );
      addTearDown(relay.close);

      final status = await relay.deviceStatus('computer-1');

      expect(status['online'], isFalse);
    },
  );

  test('HTTP errors preserve a relay-specific diagnosis', () async {
    final relay = ComputerRelayClient(
      baseUrl: 'https://relay.example.com',
      apiToken: 'relay-token',
      client: MockClient(
        (_) async =>
            http.Response(jsonEncode({'error': 'device not registered'}), 404),
      ),
    );
    addTearDown(relay.close);

    try {
      await relay.deviceStatus('computer-1');
      fail('expected ComputerRelayException');
    } on ComputerRelayException catch (error) {
      expect(error.statusCode, 404);
      expect(error.userMessage, '中转服务器连接成功，但电脑尚未完成配对登记');
    }
  });

  test(
    'HTTP 502 stays a relay error instead of an agent offline result',
    () async {
      final relay = ComputerRelayClient(
        baseUrl: 'https://relay.example.com',
        apiToken: 'relay-token',
        client: MockClient(
          (_) async => http.Response(jsonEncode({'error': 'bad gateway'}), 502),
        ),
      );
      addTearDown(relay.close);

      try {
        await relay.deviceStatus('computer-1');
        fail('expected ComputerRelayException');
      } on ComputerRelayException catch (error) {
        expect(error.statusCode, 502);
        expect(error.transportFailure, isFalse);
        expect(error.userMessage, '中转服务器返回 HTTP 502：bad gateway');
      }
    },
  );

  test('transport errors are reported separately from HTTP errors', () async {
    final relay = ComputerRelayClient(
      baseUrl: 'https://relay.example.com',
      apiToken: 'relay-token',
      client: MockClient(
        (_) async => throw http.ClientException('connection refused'),
      ),
    );
    addTearDown(relay.close);

    try {
      await relay.deviceStatus('computer-1');
      fail('expected ComputerRelayException');
    } on ComputerRelayException catch (error) {
      expect(error.transportFailure, isTrue);
      expect(error.userMessage, contains('连接中转服务器失败'));
      expect(error.userMessage, contains('connection refused'));
    }
  });
}
