import 'dart:convert';

import 'package:http/http.dart' as http;

import '../agent/ai_protocol.dart';
import '../agent/ai_client_factory.dart';
import '../domain/models.dart';

const _codexModelCatalogClientVersion = '0.150.0';

class ProviderConnectionTester {
  ProviderConnectionTester({this.client});

  final http.Client? client;

  Future<void> test(ProviderProfile profile, String secret) async {
    final client = createAiClient(
      wireApi: profile.wireApi,
      baseUrl: profile.baseUrl,
      apiKey: secret,
      model: profile.model,
      reasoningEffort: profile.reasoningEffort,
      inputModalities: profile.wireApi == 'responses'
          ? resolveProviderModelMetadata(
              profile,
              profile.model,
            )?.inputModalities
          : null,
    );
    try {
      // Test the exact protocol selected for the provider. A models endpoint
      // alone does not prove that the configured protocol and credentials work.
      await client.complete(
        messages: [AiMessage.user('回复 OK。')],
        tools: const [],
      );
    } finally {
      closeAiClient(client);
    }
  }

  Future<List<String>> listModels(
    ProviderProfile profile,
    String secret,
  ) async {
    final models = await listModelMetadata(profile, secret);
    return [for (final model in models) model.model];
  }

  /// Reads model ids and the optional Codex-compatible metadata exposed by a
  /// provider. Standard OpenAI-compatible model lists usually expose only
  /// ids, so missing metadata remains unknown instead of being inferred.
  Future<List<ProviderModelMetadata>> listModelMetadata(
    ProviderProfile profile,
    String secret,
  ) async {
    final baseUrl = profile.baseUrl.trim().replaceFirst(RegExp(r'/+$'), '');
    if (baseUrl.isEmpty) {
      throw ArgumentError('Base URL 不能为空');
    }

    final standardUri = Uri.parse('$baseUrl/models');
    // Codex-compatible gateways use this query to return model capabilities
    // such as supported_reasoning_levels. Ordinary OpenAI-compatible servers
    // usually ignore the query and still return their normal data list.
    final codexUri = standardUri.replace(
      queryParameters: const {
        'client_version': _codexModelCatalogClientVersion,
      },
    );
    final requestClient = client ?? http.Client();
    try {
      var response = await requestClient
          .get(
            codexUri,
            headers: {
              'Accept': 'application/json',
              'Authorization': 'Bearer $secret',
            },
          )
          .timeout(const Duration(seconds: 10));
      if (_shouldRetryStandardModelCatalog(response.statusCode)) {
        response = await requestClient
            .get(
              standardUri,
              headers: {
                'Accept': 'application/json',
                'Authorization': 'Bearer $secret',
              },
            )
            .timeout(const Duration(seconds: 10));
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError('供应商返回 HTTP ${response.statusCode}');
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! Map) {
        throw const FormatException('供应商模型列表格式无效');
      }
      // OpenAI-compatible catalogs use `data`; the Codex model catalog uses
      // `models`. Both contain the same per-model metadata fields.
      final rawModels = decoded['data'] ?? decoded['models'];
      if (rawModels is! List) {
        throw const FormatException('供应商模型列表格式无效');
      }
      final models = <ProviderModelMetadata>[];
      for (final item in rawModels) {
        final rawModel = item is Map
            ? item['id'] is String
                  ? item['id']
                  : item['slug']
            : null;
        if (item is Map && rawModel is String && rawModel.isNotEmpty) {
          final model = rawModel.trim();
          if (model.isEmpty) continue;
          models.add(
            ProviderModelMetadata.fromMap({
              ...Map<String, Object?>.from(item),
              'model': model,
              'source': 'api',
            }),
          );
        }
      }
      return await _mergeOpenCodeCatalog(profile, models, requestClient);
    } on FormatException {
      throw ArgumentError('Base URL 无效');
    } finally {
      if (client == null) requestClient.close();
    }
  }

  static bool _shouldRetryStandardModelCatalog(int statusCode) {
    return statusCode == 400 ||
        statusCode == 404 ||
        statusCode == 405 ||
        statusCode == 406 ||
        statusCode == 415;
  }

  Future<List<ProviderModelMetadata>> _mergeOpenCodeCatalog(
    ProviderProfile profile,
    List<ProviderModelMetadata> models,
    http.Client requestClient,
  ) async {
    final base = Uri.tryParse(profile.baseUrl.trim());
    if (base == null ||
        base.host.toLowerCase() != 'opencode.ai' ||
        !base.path.toLowerCase().startsWith('/zen/')) {
      return models;
    }
    final catalogKey = base.path.toLowerCase().contains('/zen/go/')
        ? 'opencode-go'
        : 'opencode';
    try {
      final response = await requestClient
          .get(
            Uri.parse('https://models.opencode.ai/api.json'),
            headers: const {'Accept': 'application/json'},
          )
          .timeout(const Duration(seconds: 10));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return models;
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! Map) return models;
      final rawProvider = decoded[catalogKey];
      if (rawProvider is! Map || rawProvider['models'] is! Map) {
        return models;
      }
      final rawCatalog = rawProvider['models'] as Map;
      final catalog = <String, ProviderModelMetadata>{};
      for (final entry in rawCatalog.entries) {
        if (entry.key is! String || entry.value is! Map) continue;
        final model = (entry.key as String).trim();
        if (model.isEmpty) continue;
        catalog[model] = ProviderModelMetadata.fromMap({
          ...Map<String, Object?>.from(entry.value as Map),
          'model': model,
          'source': 'opencode-catalog',
        });
      }
      return [
        for (final model in models)
          catalog[model.model]?.mergedWith(model) ?? model,
      ];
    } on Object {
      // The public catalog is capability enrichment only. The provider's
      // authenticated model list remains usable when it is unavailable.
      return models;
    }
  }
}
