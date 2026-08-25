import 'dart:convert';

import 'package:http/http.dart' as http;

import '../agent/ai_protocol.dart';
import '../agent/openai_compatible_client.dart';
import '../domain/models.dart';

class ProviderConnectionTester {
  Future<void> test(ProviderProfile profile, String secret) async {
    final client = OpenAiCompatibleClient(
      baseUrl: profile.baseUrl,
      apiKey: secret,
      model: profile.model,
      reasoningEffort: profile.reasoningEffort,
    );
    try {
      // Test the same strict Responses path used by an actual task. A models
      // endpoint alone does not prove that this model supports Responses,
      // streaming, or the configured credentials.
      await client.complete(
        messages: [AiMessage.user('回复 OK。')],
        tools: const [],
      );
    } finally {
      client.close();
    }
  }

  Future<List<String>> listModels(
    ProviderProfile profile,
    String secret,
  ) async {
    final baseUrl = profile.baseUrl.trim().replaceFirst(RegExp(r'/+$'), '');
    if (baseUrl.isEmpty) {
      throw ArgumentError('Base URL 不能为空');
    }

    final uri = Uri.parse('$baseUrl/models');
    final client = http.Client();
    try {
      final response = await client
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
      if (decoded is! Map || decoded['data'] is! List) {
        throw const FormatException('供应商模型列表格式无效');
      }
      final models = <String>[];
      for (final item in decoded['data'] as List) {
        if (item is Map &&
            item['id'] is String &&
            (item['id'] as String).isNotEmpty) {
          models.add(item['id'] as String);
        }
      }
      return models;
    } on FormatException {
      throw ArgumentError('Base URL 无效');
    } finally {
      client.close();
    }
  }
}
