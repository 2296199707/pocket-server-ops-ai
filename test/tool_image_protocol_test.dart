import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile_agent/agent/ai_protocol.dart';
import 'package:mobile_agent/agent/agent_loop.dart';
import 'package:mobile_agent/agent/agent_tools.dart';
import 'package:mobile_agent/agent/chat_completions_client.dart';
import 'package:mobile_agent/agent/openai_compatible_client.dart';

const attachment = AiAttachment(
  id: 'image-1',
  name: 'image.png',
  mimeType: 'image/png',
  base64Data: 'aW1hZ2U=',
);
const calls = [
  AiToolCall(id: 'fc1', callId: 'call1', name: 'image.view', arguments: '{}'),
  AiToolCall(id: 'fc2', callId: 'call2', name: 'read.text', arguments: '{}'),
];

void main() {
  for (final responses in [true, false]) {
    test(
      'tool images keep paired results in ${responses ? 'Responses' : 'Chat'}',
      () async {
        late Map<String, dynamic> body;
        final transport = MockClient((request) async {
          body = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode(
              responses
                  ? {'status': 'completed', 'output': <Object>[]}
                  : {
                      'choices': [
                        {
                          'message': {'role': 'assistant', 'content': 'seen'},
                          'finish_reason': 'stop',
                        },
                      ],
                    },
            ),
            200,
            headers: {'content-type': 'application/json'},
          );
        });
        final AiChatClient client = responses
            ? OpenAiCompatibleClient(
                baseUrl: 'https://example.test/v1',
                apiKey: 'test',
                model: 'vision',
                client: transport,
              )
            : ChatCompletionsClient(
                baseUrl: 'https://example.test/v1',
                apiKey: 'test',
                model: 'vision',
                client: transport,
                stream: false,
              );
        addTearDown(transport.close);
        await client.complete(
          messages: [
            AiMessage.user('inspect'),
            const AiMessage(role: 'assistant', toolCalls: calls),
            AiMessage.tool(
              toolCallId: 'call1',
              content: 'image saved',
              attachments: [attachment],
            ),
            AiMessage.tool(toolCallId: 'call2', content: 'text'),
          ],
          tools: [],
        );
        if (responses) {
          final results = (body['input'] as List)
              .where((x) => x['type'] == 'function_call_output')
              .toList();
          expect(results[0]['call_id'], 'call1');
          expect(results[0]['output'][1]['image_url'], attachment.dataUrl);
          expect(results[1]['output'], 'text');
        } else {
          final messages = body['messages'] as List;
          expect(messages.map((x) => x['role']).toList(), [
            'user',
            'assistant',
            'tool',
            'tool',
            'user',
          ]);
          expect(
            messages.last['content'].last['image_url']['url'],
            attachment.dataUrl,
          );
        }
      },
    );
  }

  test(
    'tool pixels reach next model round while durable events store references',
    () async {
      final client = _ImageClient();
      Map<String, Object?>? completed;
      final result =
          await AgentLoop(
            client: client,
            tools: [
              AgentTool(
                definition: const AiToolDefinition(
                  name: 'image.view',
                  description: 'view',
                  parameters: {'type': 'object'},
                ),
                requiresConfirmation: false,
                call: (_) async => const AiToolResult(
                  result: {'viewed': true},
                  attachments: [attachment],
                ),
              ),
            ],
          ).run(
            prompt: 'inspect',
            executionMode: 'auto',
            onEvent: (type, payload) async {
              if (type == 'tool.completed') completed = payload;
            },
          );
      expect(client.seen, attachment.dataUrl);
      expect(
        result.messages
            .where((x) => x.role == 'tool')
            .single
            .attachments
            .single
            .id,
        'image-1',
      );
      expect(jsonEncode(completed), contains('image-1'));
      expect(jsonEncode(completed), isNot(contains('aW1hZ2U=')));
    },
  );
}

class _ImageClient implements AiChatClient {
  String? seen;
  @override
  Future<AiMessage> complete({
    required List<AiMessage> messages,
    required List<AiToolDefinition> tools,
    void Function(String delta)? onContentDelta,
    Future<void>? cancellation,
  }) async {
    if (messages.last.role != 'tool') {
      return AiMessage(role: 'assistant', toolCalls: [calls.first]);
    }
    seen = messages.last.attachments.single.dataUrl;
    return const AiMessage(role: 'assistant', content: 'seen');
  }
}
