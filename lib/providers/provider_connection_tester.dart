import 'dart:convert';

import 'package:http/http.dart' as http;

import '../agent/ai_protocol.dart';
import '../agent/ai_client_factory.dart';
import '../domain/models.dart';

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

  Future<List<String>> listImageModels(
    ProviderProfile profile,
    String secret,
  ) async {
    final models = await listModels(profile, secret);
    final imageModels = <String>{
      for (final model in models)
        if (_looksLikeImageModel(model)) model,
    }.toList()..sort((left, right) => right.compareTo(left));
    return imageModels;
  }

  // Standard /models responses expose ids but usually no output capability.
  static bool _looksLikeImageModel(String model) {
    final normalized = model.toLowerCase();
    return normalized.contains('image') ||
        normalized.contains('dall-e') ||
        normalized.contains('dalle');
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

    final uri = Uri.parse('$baseUrl/models');
    final requestClient = client ?? http.Client();
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
      return models;
    } on FormatException {
      throw ArgumentError('Base URL 无效');
    } finally {
      if (client == null) requestClient.close();
    }
  }
}
