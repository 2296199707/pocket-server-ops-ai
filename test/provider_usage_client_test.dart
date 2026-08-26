import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart';
import 'package:http/testing.dart';
import 'package:mobile_agent/domain/models.dart';
import 'package:mobile_agent/providers/provider_usage_client.dart';

ProviderProfile _profile(String baseUrl) => ProviderProfile(
  id: 'provider-1',
  name: '测试供应商',
  baseUrl: baseUrl,
  model: 'test-model',
  apiKeyRef: 'provider-key',
  isDefault: true,
);

void main() {
  test('gateway usage endpoint normalizes balance and sends the key', () async {
    late BaseRequest request;
    final client = ProviderUsageClient(
      client: MockClient((incoming) async {
        request = incoming;
        return Response(
          jsonEncode({
            'balance': 12.5,
            'remaining': 8.25,
            'unit': 'USD',
            'usage': {
              'today': {'requests': 3, 'cost': 0.4},
            },
          }),
          200,
        );
      }),
    );
    addTearDown(client.close);

    final snapshot = await client.fetch(
      _profile('https://api.ai-pixel.online'),
      'secret-key',
    );

    expect(request.url.path, '/v1/usage');
    expect(request.headers['authorization'], 'Bearer secret-key');
    expect(snapshot.status, 'ok');
    expect(snapshot.balance?.remaining, 8.25);
    expect(snapshot.todayRequests, 3);
  });

  test('DeepSeek usage endpoint reads balance_infos', () async {
    late BaseRequest request;
    final client = ProviderUsageClient(
      client: MockClient((incoming) async {
        request = incoming;
        return Response(
          jsonEncode({
            'is_available': true,
            'balance_infos': [
              {'total_balance': '4.20', 'currency': 'CNY'},
            ],
          }),
          200,
        );
      }),
    );
    addTearDown(client.close);

    final snapshot = await client.fetch(
      _profile('https://api.deepseek.com/v1'),
      'deepseek-key',
    );

    expect(request.url.path, '/user/balance');
    expect(snapshot.balance?.amount, 4.2);
    expect(snapshot.balance?.currency, 'CNY');
  });
}
