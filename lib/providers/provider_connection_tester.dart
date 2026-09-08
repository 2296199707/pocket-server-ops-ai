import 'dart:convert';

import 'package:http/http.dart' as http;

import '../agent/ai_protocol.dart';
import '../agent/ai_client_factory.dart';
import '../domain/models.dart';

// Sub2API selects its Codex capability manifest when this query is present.
// Keep this aligned with the current Codex client contract; it is not the
// provider API version and is never used for the ordinary model list.
const _codexModelCatalogClientVersion = '0.200.1';

class ProviderConnectionTester {
  ProviderConnectionTester({this.client});

  final http.Client? client;

  Future<void> test(ProviderProfile profile, String secret) async {
    final client = createAiClient(
      wireApi: profile.wireApi,
      baseUrl: profile.baseUrl,
      apiKey: secret,
      model: profile.model,
      sessionId: 'provider-test-${profile.id}',
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
    // Prefer the unversioned provider catalog. A Codex client_version can
    // filter out newer models on gateways, even when the request succeeds.
    // Keep version negotiation only for endpoints rejecting standard /models.
    final codexUri = standardUri.replace(
      queryParameters: {
        ...standardUri.queryParameters,
        'client_version': _codexModelCatalogClientVersion,
      },
    );
    final requestClient = client ?? http.Client();
    try {
      var usedCodexCatalogFallback = false;
      var response = await requestClient
          .get(
            standardUri,
            headers: {
              'Accept': 'application/json',
              'Authorization': 'Bearer $secret',
            },
          )
          .timeout(const Duration(seconds: 10));
      if (_shouldRetryStandardModelCatalog(response.statusCode)) {
        usedCodexCatalogFallback = true;
        response = await requestClient
            .get(
              codexUri,
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
      var models = _parseModelMetadata(decoded, source: 'api');
      if (!usedCodexCatalogFallback && _needsCodexCapabilityMetadata(models)) {
        final capabilityModels = await _tryFetchCodexModelMetadata(
          requestClient,
          codexUri,
          secret,
        );
        if (capabilityModels != null) {
          final byModel = <String, ProviderModelMetadata>{
            for (final model in capabilityModels) model.model: model,
          };
          models = [
            for (final model in models)
              if (byModel[model.model] case final capability?)
                model.mergedWith(capability)
              else
                model,
          ];
        }
      }
      return await _mergeOpenCodeCatalog(profile, models, requestClient);
    } on FormatException {
      throw ArgumentError('Base URL 无效');
    } finally {
      if (client == null) requestClient.close();
    }
  }

  List<ProviderModelMetadata> _parseModelMetadata(
    Map decoded, {
    required String source,
  }) {
    // OpenAI-compatible catalogs use `data`; the Codex model catalog uses
    // `models`. Both contain the same per-model capability fields.
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
            'source': source,
          }),
        );
      }
    }
    return models;
  }

  bool _needsCodexCapabilityMetadata(List<ProviderModelMetadata> models) {
    return models.any(
      (model) =>
          model.defaultReasoningLevel == null &&
          model.supportedReasoningLevels == null,
    );
  }

  Future<List<ProviderModelMetadata>?> _tryFetchCodexModelMetadata(
    http.Client requestClient,
    Uri uri,
    String secret,
  ) async {
    try {
      final response = await requestClient
          .get(
            uri,
            headers: {
              'Accept': 'application/json',
              'Authorization': 'Bearer $secret',
            },
          )
          .timeout(const Duration(seconds: 10));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return null;
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! Map) return null;
      return _parseModelMetadata(decoded, source: 'api-codex');
    } on Object {
      // Capability discovery is enrichment. A provider that only supports
      // ordinary /models must remain usable with its already returned ids.
      return null;
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
