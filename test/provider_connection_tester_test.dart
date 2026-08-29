import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart';
import 'package:http/testing.dart';
import 'package:mobile_agent/domain/models.dart';
import 'package:mobile_agent/providers/provider_connection_tester.dart';

ProviderProfile _profile(String baseUrl) => ProviderProfile(
  id: 'provider-1',
  name: '测试供应商',
  baseUrl: baseUrl,
  model: 'model-1',
  apiKeyRef: 'provider-key',
  isDefault: true,
);

void main() {
  test('listModelMetadata parses Codex model fields', () async {
    late BaseRequest request;
    final client = MockClient((incoming) async {
      request = incoming;
      return Response(
        jsonEncode({
          'models': [
            {
              'slug': 'model-1',
              'default_reasoning_level': 'high',
              'supported_reasoning_levels': [
                {'effort': 'low', 'description': 'Low'},
                {'effort': 'high', 'description': 'High'},
              ],
              'input_modalities': ['text', 'image'],
              'truncation_policy': {'mode': 'bytes', 'limit': 10000},
              'shell_type': 'unified_exec',
              'experimental_supported_tools': ['shell'],
              'supports_search_tool': true,
            },
          ],
        }),
        200,
      );
    });
    addTearDown(client.close);

    final models = await ProviderConnectionTester(client: client)
        .listModelMetadata(_profile('https://provider.example/v1'), 'secret');

    expect(request.url.path, '/v1/models');
    expect(request.url.queryParameters['client_version'], '0.150.0');
    expect(request.headers['authorization'], 'Bearer secret');
    expect(models.single.defaultReasoningLevel, 'high');
    expect(models.single.supportedReasoningLevels?.last.effort, 'high');
    expect(models.single.inputModalities, ['text', 'image']);
    expect(models.single.truncationPolicy?.limit, 10000);
    expect(models.single.experimentalSupportedTools, ['shell']);
    expect(models.single.supportsSearchTool, isTrue);
  });

  test('id-only model entry leaves optional capabilities unknown', () async {
    final client = MockClient(
      (_) async => Response(
        jsonEncode({
          'data': [
            {'id': 'model-1'},
          ],
        }),
        200,
      ),
    );
    addTearDown(client.close);

    final model =
        (await ProviderConnectionTester(client: client).listModelMetadata(
          _profile('https://provider.example/v1'),
          'secret',
        )).single;

    expect(model.model, 'model-1');
    expect(model.defaultReasoningLevel, isNull);
    expect(model.supportedReasoningLevels, isNull);
    expect(model.inputModalities, isNull);
    expect(model.truncationPolicy, isNull);
    expect(model.experimentalSupportedTools, isNull);
    expect(model.supportsSearchTool, isNull);
  });

  test('parses the provider reasoningEfforts catalog form', () async {
    final client = MockClient(
      (_) async => Response(
        jsonEncode({
          'data': [
            {
              'id': 'model-1',
              'reasoningEffort': 'high',
              'reasoningEfforts': [
                {'value': 'low', 'label': 'Low'},
                {'value': 'high', 'label': 'High'},
              ],
            },
          ],
        }),
        200,
      ),
    );
    addTearDown(client.close);

    final model =
        (await ProviderConnectionTester(client: client).listModelMetadata(
          _profile('https://provider.example/v1'),
          'secret',
        )).single;

    expect(model.defaultReasoningLevel, 'high');
    expect(model.supportedReasoningLevels?.map((level) => level.effort), [
      'low',
      'high',
    ]);
    expect(model.supportedReasoningLevels?.first.description, 'Low');
  });

  test('falls back to the standard model list when catalog negotiation is rejected', () async {
    var requests = 0;
    final client = MockClient((request) async {
      requests++;
      if (request.url.queryParameters.containsKey('client_version')) {
        return Response('{}', 404);
      }
      return Response(
        jsonEncode({
          'data': [
            {'id': 'model-1'},
          ],
        }),
        200,
      );
    });
    addTearDown(client.close);

    final models = await ProviderConnectionTester(client: client)
        .listModelMetadata(_profile('https://provider.example/v1'), 'secret');

    expect(requests, 2);
    expect(models.single.model, 'model-1');
  });
}
