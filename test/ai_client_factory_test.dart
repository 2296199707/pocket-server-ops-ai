import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_agent/agent/ai_client_factory.dart';
import 'package:mobile_agent/agent/chat_completions_client.dart';
import 'package:mobile_agent/agent/openai_compatible_client.dart';

void main() {
  test('factory keeps the selected protocol explicit', () {
    final responses = createAiClient(
      wireApi: 'responses',
      baseUrl: 'https://provider.example/v1',
      apiKey: 'key',
      model: 'model',
    );
    final completions = createAiClient(
      wireApi: 'chat-completions',
      baseUrl: 'https://provider.example/v1',
      apiKey: 'key',
      model: 'model',
    );
    addTearDown(() {
      closeAiClient(responses);
      closeAiClient(completions);
    });

    expect(responses, isA<OpenAiCompatibleClient>());
    expect(completions, isA<ChatCompletionsClient>());
  });

  test('unknown protocol is an explicit configuration error', () {
    expect(
      () => createAiClient(
        wireApi: 'unknown',
        baseUrl: 'https://provider.example/v1',
        apiKey: 'key',
        model: 'model',
      ),
      throwsA(isA<StateError>()),
    );
  });
}
