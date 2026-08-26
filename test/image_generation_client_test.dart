import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile_agent/providers/image_generation_client.dart';

void main() {
  test('posts the image request and parses base64 output', () async {
    late http.Request request;
    final client = ImageGenerationClient(
      baseUrl: 'https://provider.example/v1/',
      apiKey: 'secret-key',
      client: MockClient((incoming) async {
        request = incoming;
        return http.Response(
          jsonEncode({
            'data': [
              {'b64_json': 'aW1hZ2U=', 'revised_prompt': 'revised prompt'},
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    addTearDown(client.close);

    final result = await client.generate(
      prompt: 'a small server dashboard',
      model: 'image-model',
      size: '1024x1024',
      responseFormat: 'b64_json',
    );

    expect(request.method, 'POST');
    expect(request.url.path, '/v1/images/generations');
    expect(request.headers['authorization'], 'Bearer secret-key');
    expect(jsonDecode(request.body), {
      'prompt': 'a small server dashboard',
      'model': 'image-model',
      'size': '1024x1024',
      'response_format': 'b64_json',
    });
    expect(result.b64Json, 'aW1hZ2U=');
    expect(result.url, isNull);
    expect(result.revisedPrompt, 'revised prompt');
  });

  test('parses a URL result and omits an unset response format', () async {
    late http.Request request;
    final client = ImageGenerationClient(
      baseUrl: 'https://provider.example/v1',
      apiKey: '',
      client: MockClient((incoming) async {
        request = incoming;
        return http.Response(
          jsonEncode({
            'data': [
              {'url': 'https://cdn.example/image.png'},
            ],
          }),
          200,
        );
      }),
    );
    addTearDown(client.close);

    final result = await client.generate(
      prompt: 'a server',
      model: 'image-model',
      size: '512x512',
    );

    expect(request.headers.containsKey('authorization'), isFalse);
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    expect(body.containsKey('response_format'), isFalse);
    expect(result.url, 'https://cdn.example/image.png');
    expect(result.b64Json, isNull);
  });

  test('redacts the API key from HTTP errors', () async {
    final client = ImageGenerationClient(
      baseUrl: 'https://provider.example/v1',
      apiKey: 'secret-key',
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({'error': 'secret-key is not allowed'}),
          401,
        ),
      ),
    );
    addTearDown(client.close);

    Object? error;
    try {
      await client.generate(
        prompt: 'a server',
        model: 'image-model',
        size: '512x512',
      );
    } catch (caught) {
      error = caught;
    }

    expect(error, isA<ImageGenerationHttpException>());
    expect(error.toString(), contains('HTTP 401'));
    expect(error.toString(), contains('[REDACTED]'));
    expect(error.toString(), isNot(contains('secret-key')));
  });

  test('enforces the response body size limit', () async {
    final client = ImageGenerationClient(
      baseUrl: 'https://provider.example/v1',
      apiKey: 'test-key',
      maxResponseBytes: 32,
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'data': [
              {'b64_json': 'x' * 100},
            ],
          }),
          200,
        ),
      ),
    );
    addTearDown(client.close);

    await expectLater(
      client.generate(
        prompt: 'a server',
        model: 'image-model',
        size: '512x512',
      ),
      throwsA(isA<ImageGenerationResponseTooLarge>()),
    );
  });

  test('cancels a pending request and closes the client', () async {
    final requestStarted = Completer<void>();
    final response = Completer<http.Response>();
    final cancellation = Completer<void>();
    final client = ImageGenerationClient(
      baseUrl: 'https://provider.example/v1',
      apiKey: 'test-key',
      client: MockClient((_) {
        requestStarted.complete();
        return response.future;
      }),
    );
    addTearDown(client.close);

    final pending = client.generate(
      prompt: 'a server',
      model: 'image-model',
      size: '512x512',
      cancellation: cancellation.future,
    );
    await requestStarted.future;
    cancellation.complete();

    await expectLater(pending, throwsA(isA<ImageGenerationCancelled>()));
  });
}
