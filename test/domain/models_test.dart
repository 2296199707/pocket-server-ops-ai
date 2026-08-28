import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_agent/agent/context_usage.dart';
import 'package:mobile_agent/domain/models.dart';

void main() {
  test('phone-only task and server data round-trip without relay fields', () {
    final server = const ServerProfile(
      id: 'server-1',
      name: '生产服务器',
      host: 'server.example.com',
      port: 22,
      username: 'ops',
      authType: 'password',
      credentialRef: 'server-1:ssh',
      credentialPassphraseRef: null,
      hostKey: 'ssh-ed25519',
      hostKeyFingerprint: 'SHA256:server',
      defaultWorkingDirectory: '/srv/app',
    );
    final task = Task(
      id: 'task-1',
      mode: 'agent',
      serverId: server.id,
      providerId: 'provider-1',
      reviewProviderId: 'review-provider-1',
      reviewModelOverride: 'review-model',
      title: '检查服务',
      workingDirectory: '/srv/app',
      executionMode: 'confirm',
      status: 'queued',
      createdAt: DateTime.utc(2026, 8, 24),
      updatedAt: DateTime.utc(2026, 8, 24),
    );

    expect(ServerProfile.fromMap(server.toMap()).host, server.host);
    expect(Task.fromMap(task.toMap()).mode, 'agent');
    expect(Task.fromMap(task.toMap()).reviewProviderId, 'review-provider-1');
    expect(Task.fromMap(task.toMap()).reviewModelOverride, 'review-model');
    expect(Task.fromMap(task.toMap()).effectiveWorkMode, 'server');
    expect(server.toMap().containsKey('relayId'), isFalse);
    expect(task.toMap().containsKey('relayId'), isFalse);
  });

  test('work modes are explicit and legacy tasks are inferred', () {
    expect(
      resolveWorkMode(
        mode: 'agent',
        projectId: 'project-1',
        serverId: 'server-1',
      ),
      'collaborative',
    );
    expect(resolveWorkMode(mode: 'agent', projectId: 'project-1'), 'local');
    expect(resolveWorkMode(mode: 'agent', serverId: 'server-1'), 'server');
    expect(resolveWorkMode(mode: 'chat', serverId: 'server-1'), 'chat');
    expect(
      resolveWorkMode(
        workMode: 'collaborative',
        mode: 'chat',
        projectId: 'project-1',
        serverId: 'server-1',
      ),
      'collaborative',
    );
    expect(
      resolveWorkMode(
        workMode: 'local',
        mode: 'agent',
        projectId: 'project-1',
        serverId: 'server-1',
      ),
      'local',
    );
  });

  test('chat tasks normalize stale persisted agent work modes', () {
    final task = Task.fromMap({
      'id': 'chat-task',
      'mode': 'chat',
      'workMode': 'collaborative',
      'projectId': 'project-1',
      'serverId': 'server-1',
      'providerId': null,
      'title': '普通对话',
      'workingDirectory': null,
      'executionMode': 'confirm',
      'status': 'completed',
      'createdAt': DateTime.utc(2026, 8, 24).toIso8601String(),
      'updatedAt': DateTime.utc(2026, 8, 24).toIso8601String(),
    });

    expect(task.effectiveWorkMode, 'chat');
    expect(task.toMap()['workMode'], 'chat');
  });

  test('unknown stored execution modes fall back to confirmation', () {
    final task = Task.fromMap({
      'id': 'task-1',
      'mode': 'agent',
      'serverId': 'server-1',
      'providerId': 'provider-1',
      'title': '检查服务',
      'workingDirectory': null,
      'executionMode': 'unexpected',
      'status': 'queued',
      'createdAt': DateTime.utc(2026, 8, 24).toIso8601String(),
      'updatedAt': DateTime.utc(2026, 8, 24).toIso8601String(),
    });

    expect(task.executionMode, 'confirm');
  });

  test(
    'Codex model metadata resolves effective window and auto compaction',
    () {
      const metadata = ProviderModelMetadata(
        model: 'gpt-5.6-luna',
        contextWindowTokens: 272000,
      );
      expect(metadata.resolvedContextWindowTokens, 272000);
      expect(metadata.effectiveContextWindowTokens, 258400);
      expect(metadata.resolvedAutoCompactTokenLimit, 244800);
      expect(
        metadata.resolveContextWindowTokens(
          contextWindowMode: maximumContextWindowMode,
        ),
        272000,
      );
      expect(
        const ProviderModelMetadata(
          model: 'custom',
          contextWindowTokens: 272000,
          autoCompactTokenLimit: 250000,
        ).resolvedAutoCompactTokenLimit,
        244800,
      );

      const usage = TaskContextUsage(
        last: TokenUsageSnapshot(
          inputTokens: 129200,
          cachedInputTokens: 0,
          outputTokens: 0,
          reasoningOutputTokens: 0,
          totalTokens: 129200,
        ),
      );
      final resolved = usage.withMetadata(
        metadata,
        selectedModel: metadata.model,
      );
      expect(resolved.rawContextWindow, 272000);
      expect(resolved.effectiveContextWindow, 258400);
      expect(resolved.autoCompactTokenLimit, 244800);
      expect(resolved.remainingPercent, 52);
    },
  );

  test('Codex model can switch between default and maximum windows', () {
    const metadata = ProviderModelMetadata(
      model: 'gpt-5.6-luna',
      contextWindowTokens: 272000,
      maxContextWindowTokens: 872000,
    );

    expect(metadata.hasExpandedContextWindow, isTrue);
    expect(
      metadata.resolveContextWindowTokens(
        contextWindowMode: defaultContextWindowMode,
      ),
      272000,
    );
    expect(
      metadata.resolveContextWindowTokens(
        contextWindowMode: maximumContextWindowMode,
      ),
      872000,
    );
    expect(
      metadata.resolveEffectiveContextWindowTokens(
        contextWindowMode: maximumContextWindowMode,
      ),
      828400,
    );
    expect(
      metadata.resolveAutoCompactTokenLimit(
        contextWindowMode: maximumContextWindowMode,
      ),
      784800,
    );

    const aliasProvider = ProviderProfile(
      id: 'provider-alias',
      name: 'GPT alias',
      baseUrl: 'https://provider.example/v1',
      model: 'gpt-5.6',
      apiKeyRef: 'provider-alias:key',
      isDefault: true,
    );
    expect(
      resolveProviderModelMetadata(aliasProvider, aliasProvider.model)
          ?.maxContextWindowTokens,
      872000,
    );
  });

  test('provider context window mode survives round-trip and invalid values use default', () {
    const provider = ProviderProfile(
      id: 'provider-window',
      name: '窗口供应商',
      baseUrl: 'https://provider.example/v1',
      model: 'gpt-5.6-luna',
      contextWindowMode: maximumContextWindowMode,
      apiKeyRef: 'provider-window:key',
      isDefault: true,
    );

    expect(
      ProviderProfile.fromMap(provider.toMap()).contextWindowMode,
      maximumContextWindowMode,
    );
    expect(
      ProviderProfile.fromMap({
        ...provider.toMap(),
        'contextWindowMode': 'unknown',
      }).contextWindowMode,
      defaultContextWindowMode,
    );
  });

  test('model metadata falls back to max window and keeps explicit policy', () {
    const fallback = ProviderModelMetadata(
      model: 'fallback',
      contextWindowTokens: 0,
      maxContextWindowTokens: 128000,
    );
    expect(fallback.resolvedContextWindowTokens, 128000);
    expect(fallback.resolvedAutoCompactTokenLimit, 115200);

    const configured = ProviderModelMetadata(
      model: 'configured',
      contextWindowTokens: 272000,
      autoCompactTokenLimit: 200000,
      compactionMode: 'disabled',
    );
    const idsOnly = ProviderModelMetadata(model: 'configured', source: 'api');
    final merged = configured.mergedWith(idsOnly);
    expect(merged.contextWindowTokens, 272000);
    expect(merged.autoCompactTokenLimit, 200000);
    expect(merged.compactionMode, 'disabled');
  });

  test('id-only provider metadata keeps the known Codex model window', () {
    const provider = ProviderProfile(
      id: 'provider-codex',
      name: 'Codex 兼容供应商',
      baseUrl: 'https://provider.example/v1',
      model: 'gpt-5.6-luna',
      apiKeyRef: 'provider-codex:key',
      isDefault: true,
      modelMetadata: {
        'gpt-5.6-luna': ProviderModelMetadata(
          model: 'gpt-5.6-luna',
          source: 'api',
        ),
      },
    );

    final metadata = resolveProviderModelMetadata(provider, provider.model);

    expect(metadata?.resolvedContextWindowTokens, 272000);
    expect(metadata?.maxContextWindowTokens, 872000);
    expect(metadata?.effectiveContextWindowTokens, 258400);
    expect(metadata?.resolvedAutoCompactTokenLimit, 244800);
    expect(metadata?.inputModalities, ['text', 'image']);
  });

  test('unknown provider models use the Codex fallback window by default', () {
    const provider = ProviderProfile(
      id: 'provider-default',
      name: '通用供应商',
      baseUrl: 'https://provider.example/v1',
      model: 'deepseek-chat',
      apiKeyRef: 'provider-default:key',
      isDefault: true,
    );

    final metadata = resolveProviderModelMetadata(provider, provider.model);

    expect(metadata?.resolvedContextWindowTokens, 272000);
    expect(metadata?.maxContextWindowTokens, 272000);
    expect(metadata?.effectiveContextWindowTokens, 258400);
    expect(metadata?.resolvedAutoCompactTokenLimit, 244800);
    expect(metadata?.source, 'codex-fallback');
  });

  test('missing tool-output metadata uses Codex fallback policy', () {
    const metadata = ProviderModelMetadata(model: 'id-only');

    expect(metadata.truncationPolicy, isNull);
    expect(metadata.resolvedTruncationPolicy.mode, 'bytes');
    expect(metadata.resolvedTruncationPolicy.limit, 10000);
  });

  test('Codex model capabilities round-trip and accept wire field names', () {
    final metadata = ProviderModelMetadata.fromMap({
      'model': 'codex-model',
      'default_reasoning_level': 'high',
      'supported_reasoning_levels': [
        {'effort': 'low', 'description': 'Low'},
        {'effort': 'high', 'description': 'High'},
      ],
      'input_modalities': ['text', 'image'],
      'truncation_policy': {'mode': 'bytes', 'limit': 10000},
      'shell_type': 'unified_exec',
      'apply_patch_tool_type': 'freeform',
      'web_search_tool_type': 'text',
      'tool_mode': 'direct',
      'experimental_supported_tools': ['computer', 'example_tool'],
      'supports_search_tool': true,
      'supports_image_detail_original': false,
      'comp_hash': 'comp-123',
      'source': 'api',
    });

    expect(metadata.defaultReasoningLevel, 'high');
    expect(metadata.supportedReasoningLevels?.map((level) => level.effort), [
      'low',
      'high',
    ]);
    expect(metadata.inputModalities, ['text', 'image']);
    expect(metadata.truncationPolicy?.mode, 'bytes');
    expect(metadata.truncationPolicy?.limit, 10000);
    expect(metadata.experimentalSupportedTools, ['computer', 'example_tool']);
    expect(metadata.supportsSearchTool, isTrue);
    expect(metadata.supportsImageDetailOriginal, isFalse);
    expect(metadata.compHash, 'comp-123');

    final restored = ProviderModelMetadata.fromMap(metadata.toMap());
    expect(restored.defaultReasoningLevel, 'high');
    expect(restored.truncationPolicy?.limit, 10000);
    expect(restored.toolMode, 'direct');
    expect(restored.compHash, 'comp-123');
  });

  test('id-only model catalog does not replace manual capabilities', () {
    const manual = ProviderModelMetadata(
      model: 'manual-model',
      defaultReasoningLevel: 'high',
      supportedReasoningLevels: [
        ProviderReasoningLevel(effort: 'low'),
        ProviderReasoningLevel(effort: 'high'),
      ],
      inputModalities: ['text', 'image'],
      truncationPolicy: ProviderTruncationPolicy(mode: 'bytes', limit: 10000),
      experimentalSupportedTools: ['shell'],
      supportsSearchTool: true,
    );
    const idsOnly = ProviderModelMetadata(model: 'manual-model', source: 'api');

    final merged = manual.mergedWith(idsOnly);
    expect(merged.defaultReasoningLevel, 'high');
    expect(merged.inputModalities, ['text', 'image']);
    expect(merged.truncationPolicy?.limit, 10000);
    expect(merged.experimentalSupportedTools, ['shell']);
    expect(merged.supportsSearchTool, isTrue);
  });

  test('context usage without resolved metadata remains unknown', () {
    const usage = TaskContextUsage(
      last: TokenUsageSnapshot(
        inputTokens: 1,
        cachedInputTokens: 0,
        outputTokens: 1,
        reasoningOutputTokens: 0,
        totalTokens: 2,
      ),
    );
    expect(usage.remainingPercent, isNull);
    expect(usage.toMap().containsKey('model_context_window'), isFalse);
  });

  test('Chat Completions is labeled as compatibility mode', () {
    expect(wireApiLabel('responses'), 'Responses');
    expect(wireApiLabel('chat-completions'), 'Chat Completions（兼容模式）');
  });
}
