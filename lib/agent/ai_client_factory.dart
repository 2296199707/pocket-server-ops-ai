import 'package:http/http.dart' as http;

import 'chat_completions_client.dart';
import 'openai_compatible_client.dart';

AiChatClient createAiClient({
  required String wireApi,
  required String baseUrl,
  required String apiKey,
  required String model,
  String reasoningEffort = 'default',
  http.Client? client,
}) {
  switch (wireApi) {
    case 'responses':
      return OpenAiCompatibleClient(
        baseUrl: baseUrl,
        apiKey: apiKey,
        model: model,
        reasoningEffort: reasoningEffort,
        client: client,
      );
    case 'chat-completions':
      return ChatCompletionsClient(
        baseUrl: baseUrl,
        apiKey: apiKey,
        model: model,
        reasoningEffort: reasoningEffort,
        client: client,
      );
    default:
      throw StateError('不支持的 AI 协议：$wireApi');
  }
}

void closeAiClient(AiChatClient client) {
  if (client is ChatCompletionsClient) {
    client.close();
  } else if (client is OpenAiCompatibleClient) {
    client.close();
  }
}
