import 'dart:convert';

// `default` is an app-only sentinel: omitting reasoning.effort lets the
// selected model use its documented default. Explicit values come from the
// selected model's provider metadata when available; a small compatibility
// fallback is shown when the provider exposes no reasoning metadata.
const defaultReasoningEffort = 'default';
const genericReasoningEffortValues = <String>['low', 'high', 'max'];

String normalizeReasoningEffort(String? value) {
  final normalized = value?.trim() ?? '';
  return normalized.isEmpty ? defaultReasoningEffort : normalized;
}

const defaultSubagentMaxConcurrentThreads = 4;
const defaultSubagentMaxRecursionDepth = 1;
const subagentMaxConcurrentThreadsRange = (1, 16);
const subagentMaxRecursionDepthRange = (1, 8);
const defaultSubagentRole = 'default';
const defaultSubagentRoleInstructions = <String, String>{
  'default': '完成分配的子任务，并用简短结果通知父代理。',
  'worker': '优先直接实施分配的修改，完成后验证结果并报告变更。',
  'explorer': '优先检查现状、收集证据并给出结论，不要擅自修改目标。',
};

const wireApiOptions = <String>['responses', 'chat-completions'];

const defaultContextWindowMode = 'default';
const maximumContextWindowMode = 'maximum';
const contextWindowModeOptions = <String>[
  defaultContextWindowMode,
  maximumContextWindowMode,
];

String contextWindowModeLabel(String value) {
  switch (value) {
    case defaultContextWindowMode:
      return '默认窗口';
    case maximumContextWindowMode:
      return '扩展窗口';
    default:
      return value;
  }
}

String normalizeContextWindowMode(String? value) {
  return contextWindowModeOptions.contains(value)
      ? value!
      : defaultContextWindowMode;
}

/// Settings shared by all subagents spawned from a root conversation.
///
/// An empty provider id follows the parent conversation's provider. An empty
/// model follows the parent model when the provider is inherited, or uses the
/// selected provider's default model when a provider is explicitly selected.
/// This mirrors Codex's configured subagent defaults without copying secrets
/// or provider credentials into the setting itself.
class SubagentSettings {
  const SubagentSettings({
    this.providerId = '',
    this.model = '',
    this.reasoningEffort = defaultReasoningEffort,
    this.maxConcurrentThreads = defaultSubagentMaxConcurrentThreads,
    this.maxRecursionDepth = defaultSubagentMaxRecursionDepth,
    this.roleInstructions = defaultSubagentRoleInstructions,
  });

  final String providerId;
  final String model;
  final String reasoningEffort;
  final int maxConcurrentThreads;
  final int maxRecursionDepth;
  final Map<String, String> roleInstructions;

  factory SubagentSettings.fromJson(String? value) {
    if (value == null || value.trim().isEmpty) return const SubagentSettings();
    try {
      final decoded = jsonDecode(value);
      return decoded is Map
          ? SubagentSettings.fromMap(Map<String, Object?>.from(decoded))
          : const SubagentSettings();
    } on FormatException {
      return const SubagentSettings();
    }
  }

  factory SubagentSettings.fromMap(Map<String, Object?> map) {
    final threads =
        (_readOptionalInt(
                  map['maxConcurrentThreads'] ?? map['max_concurrent_threads'],
                ) ??
                defaultSubagentMaxConcurrentThreads)
            .clamp(
              subagentMaxConcurrentThreadsRange.$1,
              subagentMaxConcurrentThreadsRange.$2,
            )
            .toInt();
    final depth =
        (_readOptionalInt(
                  map['maxRecursionDepth'] ?? map['max_recursion_depth'],
                ) ??
                defaultSubagentMaxRecursionDepth)
            .clamp(
              subagentMaxRecursionDepthRange.$1,
              subagentMaxRecursionDepthRange.$2,
            )
            .toInt();
    final model = map['model'];
    final providerId = map['providerId'] ?? map['provider_id'];
    final effort = map['reasoningEffort'] ?? map['reasoning_effort'];
    final rawRoles = map['roleInstructions'] ?? map['role_instructions'];
    final roles = <String, String>{...defaultSubagentRoleInstructions};
    if (rawRoles is Map) {
      for (final entry in rawRoles.entries) {
        if (entry.key is! String || entry.value is! String) continue;
        final role = (entry.key as String).trim();
        final instruction = (entry.value as String).trim();
        if (role.isEmpty || instruction.isEmpty) continue;
        roles[role] = instruction;
      }
    }
    return SubagentSettings(
      providerId: providerId is String ? providerId.trim() : '',
      model: model is String ? model.trim() : '',
      reasoningEffort: effort is String && effort.trim().isNotEmpty
          ? effort.trim()
          : defaultReasoningEffort,
      maxConcurrentThreads: threads,
      maxRecursionDepth: depth,
      roleInstructions: Map.unmodifiable(roles),
    );
  }

  Map<String, Object?> toMap() => {
    'providerId': providerId,
    'model': model,
    'reasoningEffort': reasoningEffort,
    'maxConcurrentThreads': maxConcurrentThreads,
    'maxRecursionDepth': maxRecursionDepth,
    'roleInstructions': roleInstructions,
  };

  String toJson() => jsonEncode(toMap());

  SubagentSettings copyWith({
    String? providerId,
    String? model,
    String? reasoningEffort,
    int? maxConcurrentThreads,
    int? maxRecursionDepth,
    Map<String, String>? roleInstructions,
  }) {
    return SubagentSettings(
      providerId: providerId ?? this.providerId,
      model: model ?? this.model,
      reasoningEffort: reasoningEffort ?? this.reasoningEffort,
      maxConcurrentThreads: maxConcurrentThreads ?? this.maxConcurrentThreads,
      maxRecursionDepth: maxRecursionDepth ?? this.maxRecursionDepth,
      roleInstructions: roleInstructions ?? this.roleInstructions,
    );
  }

  String instructionForRole(String? role) {
    final key = role?.trim();
    if (key == null || key.isEmpty) {
      return roleInstructions[defaultSubagentRole] ?? '';
    }
    return roleInstructions[key] ??
        defaultSubagentRoleInstructions[key] ??
        roleInstructions[defaultSubagentRole] ??
        '';
  }
}

String wireApiLabel(String value) {
  switch (value) {
    case 'responses':
      return 'Responses';
    case 'chat-completions':
      return 'Chat Completions（兼容模式）';
    default:
      return value;
  }
}

String reasoningEffortLabel(String value) {
  switch (value) {
    case 'default':
      return '模型默认';
    case 'none':
      return '无推理';
    case 'minimal':
      return '最小';
    case 'low':
      return '低';
    case 'medium':
      return '中';
    case 'high':
      return '高';
    case 'xhigh':
      return '极高';
    case 'max':
      return '最高';
    default:
      return value;
  }
}

const workModeOptions = <String>['collaborative', 'local', 'server', 'chat'];

String workModeLabel(String value) {
  switch (value) {
    case 'collaborative':
      return '协同';
    case 'local':
      return '本地';
    case 'server':
      return '服务器';
    case 'chat':
      return '对话';
    default:
      return value;
  }
}

String workModeDescription(String value) {
  switch (value) {
    case 'collaborative':
      return '手机本地 Agent 与目标服务器一起工作';
    case 'local':
      return '仅使用手机本地 Agent 和项目文件';
    case 'server':
      return '仅使用目标服务器工具';
    case 'chat':
      return '仅进行 AI 对话，不调用运维工具';
    default:
      return '';
  }
}

bool workModeUsesLocal(String value) =>
    value == 'collaborative' || value == 'local';

bool workModeUsesServer(String value) =>
    value == 'collaborative' || value == 'server';

String taskModeForWorkMode(String value) => value == 'chat' ? 'chat' : 'agent';

/// Old tasks did not persist a work mode. Infer one from their existing
/// project/server bindings while new tasks store the explicit selection.
String resolveWorkMode({
  String? workMode,
  required String mode,
  String? projectId,
  String? serverId,
  List<String> serverIds = const [],
}) {
  final selected = workMode?.trim();
  if (selected != null && workModeOptions.contains(selected)) return selected;
  if (mode == 'chat') return 'chat';
  final hasProject = projectId?.isNotEmpty == true;
  final hasServer =
      serverId?.isNotEmpty == true || serverIds.any((id) => id.isNotEmpty);
  if (hasProject && hasServer) return 'collaborative';
  if (hasServer) return 'server';
  return 'local';
}

const serverTargetTypeSsh = 'ssh';
const serverTargetTypeWindows = 'windows';
const windowsConnectionModeRelay = 'relay';
const windowsConnectionModeDirect = 'direct';

class ServerProfile {
  final String id;
  final String name;
  final String host;
  final int port;
  final String username;
  final String authType;
  final String? credentialRef;
  final String? credentialPassphraseRef;
  final String? hostKey;
  final String? hostKeyFingerprint;
  final String? defaultWorkingDirectory;

  /// `ssh` keeps the original direct-server behavior. `windows` represents a
  /// computer reached through the relay client and does not use SSH fields.
  final String targetType;
  final String? relayUrl;
  final String? deviceId;
  final String? relayTokenRef;
  final String? deviceTokenRef;

  const ServerProfile({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
    required this.username,
    required this.authType,
    required this.credentialRef,
    required this.credentialPassphraseRef,
    required this.hostKey,
    required this.hostKeyFingerprint,
    required this.defaultWorkingDirectory,
    this.targetType = serverTargetTypeSsh,
    this.relayUrl,
    this.deviceId,
    this.relayTokenRef,
    this.deviceTokenRef,
  });

  bool get isWindowsComputer => targetType == serverTargetTypeWindows;
  bool get isDirectWindowsComputer =>
      isWindowsComputer && authType == windowsConnectionModeDirect;

  factory ServerProfile.fromMap(Map<String, Object?> map) {
    return ServerProfile(
      id: map['id'] as String,
      name: map['name'] as String,
      host: map['host'] as String,
      port: map['port'] as int,
      username: map['username'] as String,
      authType: map['authType'] as String,
      credentialRef: map['credentialRef'] as String?,
      credentialPassphraseRef: map['credentialPassphraseRef'] as String?,
      hostKey: map['hostKey'] as String?,
      hostKeyFingerprint: map['hostKeyFingerprint'] as String?,
      defaultWorkingDirectory: map['defaultWorkingDirectory'] as String?,
      targetType: map['targetType'] as String? ?? serverTargetTypeSsh,
      relayUrl: map['relayUrl'] as String?,
      deviceId: map['deviceId'] as String?,
      relayTokenRef: map['relayTokenRef'] as String?,
      deviceTokenRef: map['deviceTokenRef'] as String?,
    );
  }

  Map<String, Object?> toMap() => {
    'id': id,
    'name': name,
    'host': host,
    'port': port,
    'username': username,
    'authType': authType,
    'credentialRef': credentialRef,
    'credentialPassphraseRef': credentialPassphraseRef,
    'hostKey': hostKey,
    'hostKeyFingerprint': hostKeyFingerprint,
    'defaultWorkingDirectory': defaultWorkingDirectory,
    'targetType': targetType,
    'relayUrl': relayUrl,
    'deviceId': deviceId,
    'relayTokenRef': relayTokenRef,
    'deviceTokenRef': deviceTokenRef,
  };

  ServerProfile copyWith({
    String? name,
    String? host,
    int? port,
    String? username,
    String? authType,
    String? credentialRef,
    String? credentialPassphraseRef,
    String? hostKey,
    String? hostKeyFingerprint,
    String? defaultWorkingDirectory,
    String? targetType,
    String? relayUrl,
    String? deviceId,
    String? relayTokenRef,
    String? deviceTokenRef,
  }) {
    return ServerProfile(
      id: id,
      name: name ?? this.name,
      host: host ?? this.host,
      port: port ?? this.port,
      username: username ?? this.username,
      authType: authType ?? this.authType,
      credentialRef: credentialRef ?? this.credentialRef,
      credentialPassphraseRef:
          credentialPassphraseRef ?? this.credentialPassphraseRef,
      hostKey: hostKey ?? this.hostKey,
      hostKeyFingerprint: hostKeyFingerprint ?? this.hostKeyFingerprint,
      defaultWorkingDirectory:
          defaultWorkingDirectory ?? this.defaultWorkingDirectory,
      targetType: targetType ?? this.targetType,
      relayUrl: relayUrl ?? this.relayUrl,
      deviceId: deviceId ?? this.deviceId,
      relayTokenRef: relayTokenRef ?? this.relayTokenRef,
      deviceTokenRef: deviceTokenRef ?? this.deviceTokenRef,
    );
  }
}

class ProviderProfile {
  final String id;
  final String name;
  final String baseUrl;
  final String model;
  final String reasoningEffort;
  final List<String> customReasoningEfforts;
  final String wireApi;
  final String contextWindowMode;
  final String? apiKeyRef;
  final bool isDefault;
  final Map<String, ProviderModelMetadata> modelMetadata;

  const ProviderProfile({
    required this.id,
    required this.name,
    required this.baseUrl,
    required this.model,
    this.reasoningEffort = 'default',
    this.customReasoningEfforts = const [],
    this.wireApi = 'responses',
    this.contextWindowMode = defaultContextWindowMode,
    required this.apiKeyRef,
    required this.isDefault,
    this.modelMetadata = const {},
  });

  factory ProviderProfile.fromMap(Map<String, Object?> map) {
    return ProviderProfile(
      id: map['id'] as String,
      name: map['name'] as String,
      baseUrl: map['baseUrl'] as String,
      model: map['model'] as String,
      reasoningEffort: normalizeReasoningEffort(
        map['reasoningEffort'] as String?,
      ),
      customReasoningEfforts: _readCustomReasoningEfforts(
        map['customReasoningEfforts'] ?? map['custom_reasoning_efforts'],
      ),
      wireApi: map['wireApi'] as String? ?? 'responses',
      contextWindowMode: normalizeContextWindowMode(
        map['contextWindowMode'] as String?,
      ),
      apiKeyRef: map['apiKeyRef'] as String?,
      isDefault: map['isDefault'] as bool,
      modelMetadata: _readProviderModelMetadata(map['modelMetadata']),
    );
  }

  Map<String, Object?> toMap() => {
    'id': id,
    'name': name,
    'baseUrl': baseUrl,
    'model': model,
    'reasoningEffort': normalizeReasoningEffort(reasoningEffort),
    'customReasoningEfforts': jsonEncode(customReasoningEfforts),
    'wireApi': wireApi,
    'contextWindowMode': normalizeContextWindowMode(contextWindowMode),
    'apiKeyRef': apiKeyRef,
    'isDefault': isDefault,
    'modelMetadata': jsonEncode({
      for (final entry in modelMetadata.entries) entry.key: entry.value.toMap(),
    }),
  };

  ProviderProfile copyWith({
    String? name,
    String? baseUrl,
    String? model,
    String? reasoningEffort,
    List<String>? customReasoningEfforts,
    String? wireApi,
    String? contextWindowMode,
    String? apiKeyRef,
    bool? isDefault,
    Map<String, ProviderModelMetadata>? modelMetadata,
  }) {
    return ProviderProfile(
      id: id,
      name: name ?? this.name,
      baseUrl: baseUrl ?? this.baseUrl,
      model: model ?? this.model,
      reasoningEffort: reasoningEffort == null
          ? this.reasoningEffort
          : normalizeReasoningEffort(reasoningEffort),
      customReasoningEfforts:
          customReasoningEfforts ?? this.customReasoningEfforts,
      wireApi: wireApi ?? this.wireApi,
      contextWindowMode: contextWindowMode ?? this.contextWindowMode,
      apiKeyRef: apiKeyRef ?? this.apiKeyRef,
      isDefault: isDefault ?? this.isDefault,
      modelMetadata: modelMetadata ?? this.modelMetadata,
    );
  }
}

/// A locally configured MCP endpoint. The access token is deliberately kept
/// outside this durable model; [tokenRef] points to the platform secure store.
class McpServerProfile {
  const McpServerProfile({
    required this.id,
    required this.name,
    required this.url,
    this.enabled = true,
    this.tokenRef,
    this.tools = const [],
    this.protocolVersion,
    this.toolsUpdatedAt,
  });

  final String id;
  final String name;
  final String url;
  final bool enabled;
  final String? tokenRef;
  final List<McpToolProfile> tools;
  final String? protocolVersion;
  final DateTime? toolsUpdatedAt;

  factory McpServerProfile.fromMap(Map<String, Object?> map) {
    final rawTools = map['tools'];
    final tools = <McpToolProfile>[];
    if (rawTools is List) {
      for (final value in rawTools) {
        if (value is! Map) continue;
        try {
          tools.add(McpToolProfile.fromMap(Map<String, Object?>.from(value)));
        } on Object {
          // One stale tool must not hide the remaining MCP configuration.
        }
      }
    }
    final updatedAt = map['toolsUpdatedAt'] ?? map['tools_updated_at'];
    return McpServerProfile(
      id: map['id'] as String,
      name: map['name'] as String,
      url: map['url'] as String,
      enabled: map['enabled'] != false,
      tokenRef: map['tokenRef'] as String? ?? map['token_ref'] as String?,
      tools: List.unmodifiable(tools),
      protocolVersion:
          map['protocolVersion'] as String? ??
          map['protocol_version'] as String?,
      toolsUpdatedAt: updatedAt is String && updatedAt.isNotEmpty
          ? DateTime.tryParse(updatedAt)
          : null,
    );
  }

  Map<String, Object?> toMap() => {
    'id': id,
    'name': name,
    'url': url,
    'enabled': enabled,
    if (tokenRef != null) 'tokenRef': tokenRef,
    'tools': [for (final tool in tools) tool.toMap()],
    if (protocolVersion != null) 'protocolVersion': protocolVersion,
    if (toolsUpdatedAt != null)
      'toolsUpdatedAt': toolsUpdatedAt!.toUtc().toIso8601String(),
  };

  McpServerProfile copyWith({
    String? name,
    String? url,
    bool? enabled,
    String? tokenRef,
    List<McpToolProfile>? tools,
    String? protocolVersion,
    DateTime? toolsUpdatedAt,
  }) {
    return McpServerProfile(
      id: id,
      name: name ?? this.name,
      url: url ?? this.url,
      enabled: enabled ?? this.enabled,
      tokenRef: tokenRef ?? this.tokenRef,
      tools: tools ?? this.tools,
      protocolVersion: protocolVersion ?? this.protocolVersion,
      toolsUpdatedAt: toolsUpdatedAt ?? this.toolsUpdatedAt,
    );
  }
}

/// Durable cache of one MCP tool definition. It contains only the schema,
/// never a tool result or credential.
class McpToolProfile {
  const McpToolProfile({
    required this.name,
    required this.description,
    required this.inputSchema,
    this.title,
    this.annotations = const {},
  });

  final String name;
  final String description;
  final String? title;
  final Map<String, Object?> inputSchema;
  final Map<String, Object?> annotations;

  factory McpToolProfile.fromMap(Map<String, Object?> map) {
    final name = map['name'];
    if (name is! String || name.trim().isEmpty) {
      throw const FormatException('MCP 工具缺少名称');
    }
    final rawSchema = map['inputSchema'];
    final rawAnnotations = map['annotations'];
    return McpToolProfile(
      name: name,
      description: map['description'] as String? ?? '',
      title: map['title'] as String?,
      inputSchema: rawSchema is Map
          ? Map<String, Object?>.from(rawSchema)
          : const {'type': 'object', 'properties': {}},
      annotations: rawAnnotations is Map
          ? Map<String, Object?>.from(rawAnnotations)
          : const {},
    );
  }

  Map<String, Object?> toMap() => {
    'name': name,
    'description': description,
    if (title != null) 'title': title,
    'inputSchema': inputSchema,
    if (annotations.isNotEmpty) 'annotations': annotations,
  };
}

/// Metadata used by the Codex-compatible context policy for one provider
/// model. The window is the model's raw window; the effective window reserves
/// the same percentage of headroom used by Codex for prompts, tools, and
/// output. All values are optional because a normal OpenAI-compatible
/// /models response often contains only model ids.
class ProviderModelMetadata {
  const ProviderModelMetadata({
    required this.model,
    this.contextWindowTokens,
    this.maxContextWindowTokens,
    this.effectiveContextWindowPercent = 95,
    this.autoCompactTokenLimit,
    this.compactionMode = 'auto',
    this.source = 'manual',
    this.reasoning,
    this.defaultReasoningLevel,
    this.supportedReasoningLevels,
    this.inputModalities,
    this.truncationPolicy,
    this.shellType,
    this.applyPatchToolType,
    this.webSearchToolType,
    this.toolMode,
    this.experimentalSupportedTools,
    this.supportsSearchTool,
    this.supportsImageDetailOriginal,
    this.compHash,
  });

  final String model;
  final int? contextWindowTokens;
  final int? maxContextWindowTokens;
  final int effectiveContextWindowPercent;
  final int? autoCompactTokenLimit;
  final String compactionMode;
  final String source;
  final bool? reasoning;
  final String? defaultReasoningLevel;
  final List<ProviderReasoningLevel>? supportedReasoningLevels;
  final List<String>? inputModalities;
  final ProviderTruncationPolicy? truncationPolicy;
  final String? shellType;
  final String? applyPatchToolType;
  final String? webSearchToolType;
  final String? toolMode;
  final List<String>? experimentalSupportedTools;
  final bool? supportsSearchTool;
  final bool? supportsImageDetailOriginal;
  final String? compHash;

  factory ProviderModelMetadata.fromMap(Map<String, Object?> map) {
    return ProviderModelMetadata(
      model: map['model'] as String,
      contextWindowTokens: _readOptionalInt(
        map['contextWindowTokens'] ??
            map['context_window'] ??
            _nestedValue(map['limit'], 'context'),
      ),
      maxContextWindowTokens: _readOptionalInt(
        map['maxContextWindowTokens'] ??
            map['max_context_window'] ??
            _nestedValue(map['limit'], 'max_context'),
      ),
      effectiveContextWindowPercent:
          _readOptionalInt(
            map['effectiveContextWindowPercent'] ??
                map['effective_context_window_percent'],
          ) ??
          95,
      autoCompactTokenLimit: _readOptionalInt(
        map['autoCompactTokenLimit'] ?? map['auto_compact_token_limit'],
      ),
      compactionMode:
          (map['compactionMode'] ?? map['compaction_mode']) as String? ??
          'auto',
      source: map['source'] as String? ?? 'manual',
      reasoning: _readOptionalBool(map['reasoning']),
      defaultReasoningLevel: _readOptionalString(
        map['defaultReasoningLevel'] ??
            map['default_reasoning_level'] ??
            map['reasoningEffort'] ??
            map['reasoning_effort'],
      ),
      supportedReasoningLevels: _readOptionalReasoningLevels(
        map['supportedReasoningLevels'] ??
            map['supported_reasoning_levels'] ??
            map['reasoningEfforts'] ??
            map['reasoning_efforts'] ??
            map['reasoningOptions'] ??
            map['reasoning_options'],
        reasoning: _readOptionalBool(map['reasoning']),
      ),
      inputModalities: _readOptionalStringList(
        map['inputModalities'] ??
            map['input_modalities'] ??
            _nestedValue(map['modalities'], 'input'),
      ),
      truncationPolicy: ProviderTruncationPolicy.fromMap(
        map['truncationPolicy'] ?? map['truncation_policy'],
      ),
      shellType: _readOptionalString(map['shellType'] ?? map['shell_type']),
      applyPatchToolType: _readOptionalString(
        map['applyPatchToolType'] ?? map['apply_patch_tool_type'],
      ),
      webSearchToolType: _readOptionalString(
        map['webSearchToolType'] ?? map['web_search_tool_type'],
      ),
      toolMode: _readOptionalString(map['toolMode'] ?? map['tool_mode']),
      experimentalSupportedTools: _readOptionalStringList(
        map['experimentalSupportedTools'] ??
            map['experimental_supported_tools'],
      ),
      supportsSearchTool: _readOptionalBool(
        map['supportsSearchTool'] ?? map['supports_search_tool'],
      ),
      supportsImageDetailOriginal: _readOptionalBool(
        map['supportsImageDetailOriginal'] ??
            map['supports_image_detail_original'],
      ),
      compHash: _readOptionalString(map['compHash'] ?? map['comp_hash']),
    );
  }

  Map<String, Object?> toMap() => {
    'model': model,
    if (contextWindowTokens != null) 'contextWindowTokens': contextWindowTokens,
    if (maxContextWindowTokens != null)
      'maxContextWindowTokens': maxContextWindowTokens,
    'effectiveContextWindowPercent': effectiveContextWindowPercent,
    if (autoCompactTokenLimit != null)
      'autoCompactTokenLimit': autoCompactTokenLimit,
    'compactionMode': compactionMode,
    'source': source,
    if (reasoning != null) 'reasoning': reasoning,
    if (defaultReasoningLevel != null)
      'defaultReasoningLevel': defaultReasoningLevel,
    if (supportedReasoningLevels != null)
      'supportedReasoningLevels': [
        for (final level in supportedReasoningLevels!) level.toMap(),
      ],
    if (inputModalities != null) 'inputModalities': inputModalities,
    if (truncationPolicy != null) 'truncationPolicy': truncationPolicy!.toMap(),
    if (shellType != null) 'shellType': shellType,
    if (applyPatchToolType != null) 'applyPatchToolType': applyPatchToolType,
    if (webSearchToolType != null) 'webSearchToolType': webSearchToolType,
    if (toolMode != null) 'toolMode': toolMode,
    if (experimentalSupportedTools != null)
      'experimentalSupportedTools': experimentalSupportedTools,
    if (supportsSearchTool != null) 'supportsSearchTool': supportsSearchTool,
    if (supportsImageDetailOriginal != null)
      'supportsImageDetailOriginal': supportsImageDetailOriginal,
    if (compHash != null) 'compHash': compHash,
  };

  /// Resolves the Codex default window or the optional maximum window.
  /// Ignore non-positive metadata so a malformed catalog cannot make the
  /// request client emit an invalid compaction threshold.
  int? resolveContextWindowTokens({
    String contextWindowMode = defaultContextWindowMode,
  }) {
    final useMaximum =
        normalizeContextWindowMode(contextWindowMode) ==
        maximumContextWindowMode;
    final candidates = useMaximum
        ? [maxContextWindowTokens, contextWindowTokens]
        : [contextWindowTokens, maxContextWindowTokens];
    for (final candidate in candidates) {
      if (candidate != null && candidate > 0) return candidate;
    }
    return null;
  }

  int? get resolvedContextWindowTokens => resolveContextWindowTokens();

  int? resolveEffectiveContextWindowTokens({
    String contextWindowMode = defaultContextWindowMode,
  }) {
    final window = resolveContextWindowTokens(
      contextWindowMode: contextWindowMode,
    );
    if (window == null) return null;
    final percent = effectiveContextWindowPercent.clamp(0, 100).toInt();
    return window * percent ~/ 100;
  }

  int? get effectiveContextWindowTokens =>
      resolveEffectiveContextWindowTokens();

  /// Codex derives the automatic threshold as 90% of the raw context window
  /// and clamps an explicitly supplied threshold to that value.
  int? resolveAutoCompactTokenLimit({
    String contextWindowMode = defaultContextWindowMode,
  }) {
    if (compactionMode == 'disabled') return null;
    final window = resolveContextWindowTokens(
      contextWindowMode: contextWindowMode,
    );
    final windowLimit = window == null ? null : window * 9 ~/ 10;
    final configured =
        autoCompactTokenLimit != null && autoCompactTokenLimit! > 0
        ? autoCompactTokenLimit
        : null;
    if (windowLimit == null) return configured;
    if (configured == null) return windowLimit;
    return configured < windowLimit ? configured : windowLimit;
  }

  int? get resolvedAutoCompactTokenLimit => resolveAutoCompactTokenLimit();

  bool get hasExpandedContextWindow {
    final defaultWindow = resolveContextWindowTokens();
    final maximumWindow = resolveContextWindowTokens(
      contextWindowMode: maximumContextWindowMode,
    );
    return maximumWindow != null &&
        (defaultWindow == null || maximumWindow > defaultWindow);
  }

  /// Codex supplies this policy in its fallback model descriptor when a model
  /// catalog has no richer metadata.
  ProviderTruncationPolicy get resolvedTruncationPolicy =>
      truncationPolicy ?? ProviderTruncationPolicy.codexFallback;

  ProviderModelMetadata mergedWith(ProviderModelMetadata remote) {
    // A normal OpenAI-compatible /models response often returns only an id.
    // Keep a manually supplied window in that case, while allowing a Codex
    // model catalog to replace it when it supplies real limits.
    final hasRemoteWindow =
        (remote.contextWindowTokens ?? 0) > 0 ||
        (remote.maxContextWindowTokens ?? 0) > 0 ||
        (remote.autoCompactTokenLimit ?? 0) > 0;
    final hasRemotePolicy =
        hasRemoteWindow ||
        remote.effectiveContextWindowPercent != 95 ||
        remote.compactionMode != 'auto';
    // Merge optional capability fields independently. An ordinary /models
    // response containing only an id has null values for these fields and
    // therefore cannot erase manually configured metadata.
    return ProviderModelMetadata(
      model: model,
      contextWindowTokens: hasRemotePolicy
          ? remote.contextWindowTokens ?? contextWindowTokens
          : contextWindowTokens,
      maxContextWindowTokens: hasRemotePolicy
          ? remote.maxContextWindowTokens ?? maxContextWindowTokens
          : maxContextWindowTokens,
      effectiveContextWindowPercent:
          hasRemotePolicy && remote.effectiveContextWindowPercent != 95
          ? remote.effectiveContextWindowPercent
          : effectiveContextWindowPercent,
      autoCompactTokenLimit: hasRemotePolicy
          ? remote.autoCompactTokenLimit ?? autoCompactTokenLimit
          : autoCompactTokenLimit,
      compactionMode: hasRemotePolicy && remote.compactionMode != 'auto'
          ? remote.compactionMode
          : compactionMode,
      source: remote.source,
      reasoning: remote.reasoning ?? reasoning,
      defaultReasoningLevel:
          remote.defaultReasoningLevel ?? defaultReasoningLevel,
      supportedReasoningLevels:
          remote.supportedReasoningLevels ?? supportedReasoningLevels,
      inputModalities: remote.inputModalities ?? inputModalities,
      truncationPolicy: remote.truncationPolicy ?? truncationPolicy,
      shellType: remote.shellType ?? shellType,
      applyPatchToolType: remote.applyPatchToolType ?? applyPatchToolType,
      webSearchToolType: remote.webSearchToolType ?? webSearchToolType,
      toolMode: remote.toolMode ?? toolMode,
      experimentalSupportedTools:
          remote.experimentalSupportedTools ?? experimentalSupportedTools,
      supportsSearchTool: remote.supportsSearchTool ?? supportsSearchTool,
      supportsImageDetailOriginal:
          remote.supportsImageDetailOriginal ?? supportsImageDetailOriginal,
      compHash: remote.compHash ?? compHash,
    );
  }
}

/// The Codex model catalog supplies these values even when a compatible
/// provider's `/models` endpoint returns only model ids. Unknown models use
/// the same generic fallback as Codex; explicit provider metadata still wins.
ProviderModelMetadata? codexCatalogMetadataForModel(String model) {
  switch (model.trim()) {
    case 'gpt-5.6':
    case 'gpt-5.6-sol':
    case 'gpt-5.6-terra':
    case 'gpt-5.6-luna':
      return ProviderModelMetadata(
        model: model.trim(),
        contextWindowTokens: 272000,
        maxContextWindowTokens: 872000,
        source: 'codex-catalog',
        inputModalities: const ['text', 'image'],
        truncationPolicy: const ProviderTruncationPolicy(
          mode: 'tokens',
          limit: 10000,
        ),
      );
    default:
      return null;
  }
}

ProviderModelMetadata codexFallbackMetadataForModel(String model) {
  return ProviderModelMetadata(
    model: model.trim(),
    contextWindowTokens: 272000,
    maxContextWindowTokens: 272000,
    source: 'codex-fallback',
    inputModalities: const ['text', 'image'],
    truncationPolicy: const ProviderTruncationPolicy(
      mode: 'bytes',
      limit: 10000,
    ),
  );
}

ProviderModelMetadata? resolveProviderModelMetadata(
  ProviderProfile provider,
  String model,
) {
  final normalizedModel = model.trim();
  ProviderModelMetadata? configured;
  for (final entry in provider.modelMetadata.entries) {
    if (entry.key == model ||
        entry.key.trim() == normalizedModel ||
        entry.value.model.trim() == normalizedModel) {
      configured = entry.value;
      break;
    }
  }
  if (normalizedModel.isEmpty) return configured;
  final fallback =
      codexCatalogMetadataForModel(normalizedModel) ??
      codexFallbackMetadataForModel(normalizedModel);
  if (configured == null) return fallback;

  // A provider may return only {id: ...}. Keep the known Codex catalog
  // values in that case, while letting real provider fields override them.
  return fallback.mergedWith(configured);
}

/// One entry from Codex's `supported_reasoning_levels` catalog field.
class ProviderReasoningLevel {
  const ProviderReasoningLevel({required this.effort, this.description});

  final String effort;
  final String? description;

  factory ProviderReasoningLevel.fromMap(Object? value) {
    if (value is String) return ProviderReasoningLevel(effort: value);
    if (value is Map) {
      final effort =
          value['effort'] ?? value['reasoning_effort'] ?? value['value'];
      if (effort is String && effort.isNotEmpty) {
        final description = value['description'] ?? value['label'];
        return ProviderReasoningLevel(
          effort: effort,
          description: description is String ? description : null,
        );
      }
    }
    throw const FormatException('推理强度元数据格式无效');
  }

  Map<String, Object?> toMap() => {
    'effort': effort,
    if (description != null) 'description': description,
  };
}

/// Codex's per-model tool-output truncation policy.
class ProviderTruncationPolicy {
  const ProviderTruncationPolicy({required this.mode, required this.limit});

  static const codexFallback = ProviderTruncationPolicy(
    mode: 'bytes',
    limit: 10000,
  );

  final String mode;
  final int limit;

  static ProviderTruncationPolicy? fromMap(Object? value) {
    if (value is! Map) return null;
    final mode = value['mode'];
    final limit = _readOptionalInt(value['limit']);
    if (mode is! String || limit == null) return null;
    return ProviderTruncationPolicy(mode: mode, limit: limit);
  }

  Map<String, Object?> toMap() => {'mode': mode, 'limit': limit};
}

int? _readOptionalInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

String? _readOptionalString(Object? value) =>
    value is String && value.isNotEmpty ? value : null;

Object? _nestedValue(Object? value, String key) {
  if (value is Map) return value[key];
  return null;
}

bool? _readOptionalBool(Object? value) => value is bool ? value : null;

List<String>? _readOptionalStringList(Object? value) {
  if (value is! List) return null;
  return List.unmodifiable([
    for (final item in value)
      if (item is String) item,
  ]);
}

List<ProviderReasoningLevel>? _readOptionalReasoningLevels(
  Object? value, {
  bool? reasoning,
}) {
  if (value == null) {
    return reasoning == false ? const <ProviderReasoningLevel>[] : null;
  }
  if (value is! List) return null;
  final levels = <ProviderReasoningLevel>[];
  for (final item in value) {
    try {
      if (item is Map && item['type'] == 'effort' && item['values'] is List) {
        for (final option in item['values'] as List) {
          if (option is String && option.isNotEmpty) {
            levels.add(ProviderReasoningLevel(effort: option));
          } else if (option is Map) {
            levels.add(ProviderReasoningLevel.fromMap(option));
          }
        }
      } else {
        levels.add(ProviderReasoningLevel.fromMap(item));
      }
    } on FormatException {
      // Ignore malformed entries while retaining the valid catalog entries.
    }
  }
  return List.unmodifiable(levels);
}

Map<String, ProviderModelMetadata> _readProviderModelMetadata(Object? value) {
  Object? decoded = value;
  if (value is String && value.isNotEmpty) {
    try {
      decoded = jsonDecode(value);
    } on FormatException {
      return const {};
    }
  }
  if (decoded is! Map) return const {};
  final result = <String, ProviderModelMetadata>{};
  for (final entry in decoded.entries) {
    if (entry.key is! String || entry.value is! Map) continue;
    try {
      final item = Map<String, Object?>.from(entry.value as Map);
      final model = item['model'] is String
          ? item['model'] as String
          : entry.key as String;
      result[entry.key as String] = ProviderModelMetadata.fromMap({
        ...item,
        'model': model,
      });
    } on Object {
      // Ignore one malformed optional metadata entry and keep the provider.
    }
  }
  return Map.unmodifiable(result);
}

class ProviderBalance {
  const ProviderBalance({
    required this.amount,
    required this.remaining,
    required this.currency,
    this.granted,
    this.toppedUp,
  });

  final double amount;
  final double remaining;
  final String currency;
  final double? granted;
  final double? toppedUp;
}

class ProviderUsageWindow {
  const ProviderUsageWindow({
    required this.label,
    required this.usedPercent,
    this.status = 'ok',
    this.resetsAt,
  });

  final String label;
  final double usedPercent;
  final String status;
  final DateTime? resetsAt;
}

class ProviderUsageSnapshot {
  const ProviderUsageSnapshot({
    required this.providerId,
    required this.status,
    this.balance,
    this.windows = const [],
    this.planName,
    this.mode,
    this.todayRequests,
    this.todayCost,
    this.message,
    this.updatedAt,
  });

  final String providerId;
  final String status;
  final ProviderBalance? balance;
  final List<ProviderUsageWindow> windows;
  final String? planName;
  final String? mode;
  final int? todayRequests;
  final double? todayCost;
  final String? message;
  final DateTime? updatedAt;

  bool get isUsable => status == 'ok' || status == 'stale';
}

class Project {
  final String id;
  final String name;
  final String localPath;

  const Project({
    required this.id,
    required this.name,
    required this.localPath,
  });

  factory Project.fromMap(Map<String, Object?> map) {
    return Project(
      id: map['id'] as String,
      name: map['name'] as String,
      localPath: map['localPath'] as String,
    );
  }

  Map<String, Object?> toMap() => {
    'id': id,
    'name': name,
    'localPath': localPath,
  };

  Project copyWith({String? name, String? localPath}) {
    return Project(
      id: id,
      name: name ?? this.name,
      localPath: localPath ?? this.localPath,
    );
  }
}

/// A user message submitted while another turn is running.
///
/// Attachment values are durable metadata maps (usually attachment IDs), not
/// the attachment bytes themselves. The controller resolves them only when a
/// turn is about to send a request.
class QueuedTaskInput {
  final String id;
  final String prompt;
  final List<Map<String, Object?>> attachments;
  final DateTime createdAt;

  const QueuedTaskInput({
    required this.id,
    required this.prompt,
    this.attachments = const [],
    required this.createdAt,
  });

  factory QueuedTaskInput.fromMap(Map<String, Object?> map) {
    final rawAttachments = map['attachments'];
    return QueuedTaskInput(
      id: map['id'] as String,
      prompt: map['prompt'] as String? ?? '',
      attachments: [
        for (final item in rawAttachments is List ? rawAttachments : const [])
          if (item is Map) Map<String, Object?>.from(item),
      ],
      createdAt: _readTime(map['createdAt']),
    );
  }

  Map<String, Object?> toMap() => {
    'id': id,
    'prompt': prompt,
    'attachments': attachments,
    'createdAt': _writeTime(createdAt),
  };
}

List<String> reasoningEffortValuesForModel(
  ProviderProfile provider,
  String model, {
  String? preserveCurrent,
}) {
  final values = <String>[defaultReasoningEffort];
  final levels = resolveProviderModelMetadata(
    provider,
    model,
  )?.supportedReasoningLevels;
  if (levels != null) {
    for (final level in levels) {
      if (level.effort.trim().isNotEmpty && !values.contains(level.effort)) {
        values.add(level.effort);
      }
    }
  } else if (model.trim().isNotEmpty) {
    // A normal OpenAI-compatible /models response often returns only IDs.
    // Keep the picker useful for providers such as DeepSeek/OpenCode until a
    // richer model catalog is available. An explicit empty list still means
    // that the provider declared no adjustable reasoning levels.
    values.addAll(genericReasoningEffortValues);
  }
  final customEfforts = normalizeCustomReasoningEfforts(
    provider.customReasoningEfforts,
  );
  for (final effort in customEfforts) {
    final normalized = effort.trim();
    if (normalized.isNotEmpty && !values.contains(normalized)) {
      values.add(normalized);
    }
  }
  // Keep an already persisted explicit value visible until the user replaces
  // it. This matters when an older app version stored a value that the new
  // model catalog does not advertise: omitting it would make a Dropdown have
  // an invalid initial value and would silently change the next request.
  final current = preserveCurrent?.trim();
  if (current != null && current.isNotEmpty && !values.contains(current)) {
    values.add(current);
  }
  return values;
}

List<String> normalizeCustomReasoningEfforts(Iterable<String> values) {
  final normalized = <String>[];
  for (final value in values) {
    final trimmed = value.trim();
    if (trimmed.isEmpty || trimmed == defaultReasoningEffort) continue;
    if (!normalized.contains(trimmed)) normalized.add(trimmed);
  }
  return List.unmodifiable(normalized);
}

bool isCustomReasoningEffort(ProviderProfile provider, String value) {
  final normalized = value.trim();
  return normalized.isNotEmpty &&
      normalizeCustomReasoningEfforts(provider.customReasoningEfforts)
          .contains(normalized);
}

List<String> _readCustomReasoningEfforts(Object? value) {
  Object? decoded = value;
  if (value is String) {
    try {
      decoded = jsonDecode(value);
    } on FormatException {
      return const [];
    }
  }
  if (decoded is! List) return const [];
  return normalizeCustomReasoningEfforts([
    for (final item in decoded)
      if (item is String) item,
  ]);
}

class Task {
  final String id;
  final String mode;
  final String? workMode;
  final String? projectId;
  final String? serverId;

  /// Servers bound to this conversation, in the order selected by the user.
  /// [serverId] remains the active server for the current Agent turn and is
  /// kept for compatibility with older task records.
  final List<String> serverIds;
  final String? providerId;
  final String? reviewProviderId;
  final String? reviewModelOverride;
  final String? modelOverride;
  final String? reasoningEffortOverride;
  final String title;
  final String? workingDirectory;
  final String executionMode;
  final bool isSubagent;
  final String? parentTaskId;
  final String? rootTaskId;
  final int agentDepth;
  final String? agentName;
  final String? agentPath;
  final String? agentRole;
  final String? agentForkTurns;
  final List<String> agentMailbox;
  final List<QueuedTaskInput> pendingInputs;
  final String? agentSummary;
  final String status;
  final DateTime createdAt;
  final DateTime updatedAt;

  const Task({
    required this.id,
    required this.mode,
    this.workMode,
    this.projectId,
    required this.serverId,
    this.serverIds = const [],
    required this.providerId,
    this.reviewProviderId,
    this.reviewModelOverride,
    this.modelOverride,
    this.reasoningEffortOverride,
    required this.title,
    required this.workingDirectory,
    required this.executionMode,
    this.isSubagent = false,
    this.parentTaskId,
    this.rootTaskId,
    this.agentDepth = 0,
    this.agentName,
    this.agentPath,
    this.agentRole,
    this.agentForkTurns,
    this.agentMailbox = const [],
    this.pendingInputs = const [],
    this.agentSummary,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
  });

  factory Task.fromMap(Map<String, Object?> map) {
    final serverId = map['serverId'] as String?;
    final serverIds = _readTaskServerIds(map['serverIds'], fallback: serverId);
    final mode =
        map['mode'] as String? ?? (serverId == null ? 'chat' : 'agent');
    return Task(
      id: map['id'] as String,
      mode: mode,
      // Older builds could persist a stale Agent work mode on a chat task.
      // Chat mode has no tools, so normalize that inconsistent record while
      // loading it instead of changing the explicit work-mode API semantics.
      workMode: mode == 'chat' ? 'chat' : map['workMode'] as String?,
      projectId: map['projectId'] as String?,
      serverId: serverId,
      serverIds: serverIds,
      providerId: map['providerId'] as String?,
      reviewProviderId: map['reviewProviderId'] as String?,
      reviewModelOverride: map['reviewModelOverride'] as String?,
      modelOverride: map['modelOverride'] as String?,
      reasoningEffortOverride: map['reasoningEffortOverride'] as String?,
      title: map['title'] as String,
      workingDirectory: map['workingDirectory'] as String?,
      executionMode: map['executionMode'] == 'auto_review'
          ? 'auto_review'
          : map['executionMode'] == 'auto'
          ? 'auto'
          : 'confirm',
      isSubagent: map['isSubagent'] == true || map['isSubagent'] == 1,
      parentTaskId: map['parentTaskId'] as String?,
      rootTaskId: map['rootTaskId'] as String?,
      agentDepth: _readOptionalInt(map['agentDepth']) ?? 0,
      agentName: map['agentName'] as String?,
      agentPath: map['agentPath'] as String?,
      agentRole: map['agentRole'] as String?,
      agentForkTurns: map['agentForkTurns'] as String?,
      agentMailbox: _readTaskMailbox(map['agentMailbox']),
      pendingInputs: _readPendingTaskInputs(map['pendingInputs']),
      agentSummary: map['agentSummary'] as String?,
      status: map['status'] as String,
      createdAt: _readTime(map['createdAt']),
      updatedAt: _readTime(map['updatedAt']),
    );
  }

  Map<String, Object?> toMap() => {
    'id': id,
    'mode': mode,
    'workMode': workMode,
    'projectId': projectId,
    'serverId': serverId,
    'serverIds': jsonEncode(serverIds),
    'providerId': providerId,
    'reviewProviderId': reviewProviderId,
    'reviewModelOverride': reviewModelOverride,
    'modelOverride': modelOverride,
    'reasoningEffortOverride': reasoningEffortOverride,
    'title': title,
    'workingDirectory': workingDirectory,
    'executionMode': executionMode,
    'isSubagent': isSubagent,
    'parentTaskId': parentTaskId,
    'rootTaskId': rootTaskId,
    'agentDepth': agentDepth,
    'agentName': agentName,
    'agentPath': agentPath,
    'agentRole': agentRole,
    'agentForkTurns': agentForkTurns,
    'agentMailbox': jsonEncode(agentMailbox),
    'pendingInputs': jsonEncode([
      for (final input in pendingInputs) input.toMap(),
    ]),
    'agentSummary': agentSummary,
    'status': status,
    'createdAt': _writeTime(createdAt),
    'updatedAt': _writeTime(updatedAt),
  };

  Task copyWith({
    String? mode,
    Object? workMode = _taskFieldUnset,
    Object? projectId = _taskFieldUnset,
    String? serverId,
    Object? serverIds = _taskFieldUnset,
    String? providerId,
    Object? reviewProviderId = _taskFieldUnset,
    Object? reviewModelOverride = _taskFieldUnset,
    String? modelOverride,
    String? reasoningEffortOverride,
    String? title,
    String? workingDirectory,
    String? executionMode,
    bool? isSubagent,
    Object? parentTaskId = _taskFieldUnset,
    Object? rootTaskId = _taskFieldUnset,
    int? agentDepth,
    Object? agentName = _taskFieldUnset,
    Object? agentPath = _taskFieldUnset,
    Object? agentRole = _taskFieldUnset,
    Object? agentForkTurns = _taskFieldUnset,
    Object? agentMailbox = _taskFieldUnset,
    Object? pendingInputs = _taskFieldUnset,
    Object? agentSummary = _taskFieldUnset,
    String? status,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return Task(
      id: id,
      mode: mode ?? this.mode,
      workMode: identical(workMode, _taskFieldUnset)
          ? this.workMode
          : workMode as String?,
      projectId: identical(projectId, _taskFieldUnset)
          ? this.projectId
          : projectId as String?,
      serverId: serverId ?? this.serverId,
      serverIds: identical(serverIds, _taskFieldUnset)
          ? this.serverIds
          : _readTaskServerIds(serverIds),
      providerId: providerId ?? this.providerId,
      reviewProviderId: identical(reviewProviderId, _taskFieldUnset)
          ? this.reviewProviderId
          : reviewProviderId as String?,
      reviewModelOverride: identical(reviewModelOverride, _taskFieldUnset)
          ? this.reviewModelOverride
          : reviewModelOverride as String?,
      modelOverride: modelOverride ?? this.modelOverride,
      reasoningEffortOverride:
          reasoningEffortOverride ?? this.reasoningEffortOverride,
      title: title ?? this.title,
      workingDirectory: workingDirectory ?? this.workingDirectory,
      executionMode: executionMode ?? this.executionMode,
      isSubagent: isSubagent ?? this.isSubagent,
      parentTaskId: identical(parentTaskId, _taskFieldUnset)
          ? this.parentTaskId
          : parentTaskId as String?,
      rootTaskId: identical(rootTaskId, _taskFieldUnset)
          ? this.rootTaskId
          : rootTaskId as String?,
      agentDepth: agentDepth ?? this.agentDepth,
      agentName: identical(agentName, _taskFieldUnset)
          ? this.agentName
          : agentName as String?,
      agentPath: identical(agentPath, _taskFieldUnset)
          ? this.agentPath
          : agentPath as String?,
      agentRole: identical(agentRole, _taskFieldUnset)
          ? this.agentRole
          : agentRole as String?,
      agentForkTurns: identical(agentForkTurns, _taskFieldUnset)
          ? this.agentForkTurns
          : agentForkTurns as String?,
      agentMailbox: identical(agentMailbox, _taskFieldUnset)
          ? this.agentMailbox
          : _readTaskMailbox(agentMailbox),
      pendingInputs: identical(pendingInputs, _taskFieldUnset)
          ? this.pendingInputs
          : _readPendingTaskInputs(pendingInputs),
      agentSummary: identical(agentSummary, _taskFieldUnset)
          ? this.agentSummary
          : agentSummary as String?,
      status: status ?? this.status,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  String get effectiveWorkMode => resolveWorkMode(
    workMode: workMode,
    mode: mode,
    projectId: projectId,
    serverId: serverId,
    serverIds: serverIds,
  );
}

const _taskFieldUnset = Object();

List<String> _readTaskServerIds(Object? value, {String? fallback}) {
  Object? decoded = value;
  if (value is String && value.trim().isNotEmpty) {
    try {
      decoded = jsonDecode(value);
    } on FormatException {
      decoded = const [];
    }
  }
  final ids = <String>[];
  if (decoded is Iterable) {
    for (final item in decoded) {
      if (item is String) {
        final id = item.trim();
        if (id.isNotEmpty && !ids.contains(id)) ids.add(id);
      }
    }
  }
  final active = fallback?.trim();
  if (active != null && active.isNotEmpty && !ids.contains(active)) {
    ids.insert(0, active);
  }
  return List.unmodifiable(ids);
}

List<String> _readTaskMailbox(Object? value) {
  Object? decoded = value;
  if (value is String && value.trim().isNotEmpty) {
    try {
      decoded = jsonDecode(value);
    } on FormatException {
      decoded = const [];
    }
  }
  if (decoded is! Iterable) return const [];
  return List.unmodifiable([
    for (final item in decoded)
      if (item is String && item.trim().isNotEmpty) item.trim(),
  ]);
}

List<QueuedTaskInput> _readPendingTaskInputs(Object? value) {
  Object? decoded = value;
  if (value is String && value.trim().isNotEmpty) {
    try {
      decoded = jsonDecode(value);
    } on FormatException {
      decoded = const [];
    }
  }
  if (decoded is! Iterable) return const [];
  final inputs = <QueuedTaskInput>[];
  for (final item in decoded) {
    if (item is QueuedTaskInput) {
      if (item.id.trim().isNotEmpty &&
          (item.prompt.trim().isNotEmpty || item.attachments.isNotEmpty)) {
        inputs.add(item);
      }
      continue;
    }
    if (item is! Map) continue;
    try {
      final input = QueuedTaskInput.fromMap(Map<String, Object?>.from(item));
      if (input.id.trim().isEmpty ||
          (input.prompt.trim().isEmpty && input.attachments.isEmpty)) {
        continue;
      }
      inputs.add(input);
    } on Object {
      // Ignore one malformed queue entry while keeping the conversation usable.
    }
  }
  return List.unmodifiable(inputs);
}

class TaskEvent {
  final String eventId;
  final String taskId;
  final int sequence;
  final String type;
  final DateTime timestamp;
  final Map<String, Object?> payload;

  TaskEvent({
    required this.eventId,
    required this.taskId,
    required this.sequence,
    required this.type,
    required this.timestamp,
    required Map<String, Object?> payload,
  }) : payload = _freezeMap(payload);

  factory TaskEvent.fromMap(Map<String, Object?> map) {
    return TaskEvent(
      eventId: map['eventId'] as String,
      taskId: map['taskId'] as String,
      sequence: map['sequence'] as int,
      type: map['type'] as String,
      timestamp: _readTime(map['timestamp']),
      payload: _readMap(map['payload']),
    );
  }

  Map<String, Object?> toMap() => {
    'eventId': eventId,
    'taskId': taskId,
    'sequence': sequence,
    'type': type,
    'timestamp': _writeTime(timestamp),
    'payload': payload,
  };
}

class AttachmentRecord {
  const AttachmentRecord({
    required this.id,
    required this.taskId,
    required this.name,
    required this.mimeType,
    required this.byteLength,
    required this.storagePath,
    required this.createdAt,
  });

  final String id;
  final String taskId;
  final String name;
  final String mimeType;
  final int byteLength;
  final String storagePath;
  final DateTime createdAt;

  factory AttachmentRecord.fromMap(Map<String, Object?> map) {
    return AttachmentRecord(
      id: map['id'] as String,
      taskId: map['taskId'] as String,
      name: map['name'] as String,
      mimeType: map['mimeType'] as String,
      byteLength: map['byteLength'] as int,
      storagePath: map['storagePath'] as String,
      createdAt: _readTime(map['createdAt']),
    );
  }

  Map<String, Object?> toMap() => {
    'id': id,
    'taskId': taskId,
    'name': name,
    'mimeType': mimeType,
    'byteLength': byteLength,
    'storagePath': storagePath,
    'createdAt': _writeTime(createdAt),
  };
}

DateTime _readTime(Object? value) => DateTime.parse(value as String);

String _writeTime(DateTime value) => value.toUtc().toIso8601String();

Map<String, Object?> _readMap(Object? value) {
  final source = value as Map;
  return {for (final entry in source.entries) entry.key as String: entry.value};
}

Map<String, Object?> _freezeMap(Map<String, Object?> source) {
  return Map<String, Object?>.unmodifiable({
    for (final entry in source.entries) entry.key: _freezeValue(entry.value),
  });
}

Object? _freezeValue(Object? value) {
  if (value is Map) {
    return Map<String, Object?>.unmodifiable({
      for (final entry in value.entries)
        entry.key as String: _freezeValue(entry.value),
    });
  }
  if (value is List) {
    return List<Object?>.unmodifiable(value.map(_freezeValue));
  }
  return value;
}

class ServerDisk {
  const ServerDisk({
    required this.mount,
    required this.total,
    required this.used,
    required this.available,
    this.usedPercent,
  });

  final String mount;
  final String total;
  final String used;
  final String available;
  final int? usedPercent;

  Map<String, Object?> toMap() => {
    'mount': mount,
    'total': total,
    'used': used,
    'available': available,
    'usedPercent': usedPercent,
  };

  factory ServerDisk.fromMap(Map<String, Object?> map) => ServerDisk(
    mount: map['mount'] as String? ?? '/',
    total: map['total'] as String? ?? 'unknown',
    used: map['used'] as String? ?? 'unknown',
    available: map['available'] as String? ?? 'unknown',
    usedPercent: _readOptionalInt(map['usedPercent']),
  );
}

class ServerNetwork {
  const ServerNetwork({
    required this.interfaceName,
    required this.receivedBytes,
    required this.transmittedBytes,
  });

  final String interfaceName;
  final int receivedBytes;
  final int transmittedBytes;

  Map<String, Object?> toMap() => {
    'interfaceName': interfaceName,
    'receivedBytes': receivedBytes,
    'transmittedBytes': transmittedBytes,
  };

  factory ServerNetwork.fromMap(Map<String, Object?> map) => ServerNetwork(
    interfaceName: map['interfaceName'] as String? ?? 'unknown',
    receivedBytes: _readOptionalInt(map['receivedBytes']) ?? 0,
    transmittedBytes: _readOptionalInt(map['transmittedBytes']) ?? 0,
  );
}

class ServerCpuCore {
  const ServerCpuCore({required this.name, required this.usage});

  final String name;
  final int usage;

  Map<String, Object?> toMap() => {'name': name, 'usage': usage};

  factory ServerCpuCore.fromMap(Map<String, Object?> map) => ServerCpuCore(
    name: map['name'] as String? ?? 'cpu?',
    usage: _readOptionalInt(map['usage']) ?? 0,
  );
}

class ServerDashboard {
  const ServerDashboard({
    required this.hostname,
    required this.os,
    required this.kernel,
    required this.uptime,
    required this.load,
    required this.cpu,
    required this.memory,
    required this.disk,
    required this.statusScriptInstalled,
    this.cpuUsage,
    this.cpuCores = const [],
    this.disks = const [],
    this.network,
    this.processCount,
  });

  final String hostname;
  final String os;
  final String kernel;
  final String uptime;
  final String load;
  final String cpu;
  final int? cpuUsage;
  final List<ServerCpuCore> cpuCores;
  final String memory;
  final String disk;
  final bool statusScriptInstalled;
  final List<ServerDisk> disks;
  final ServerNetwork? network;
  final int? processCount;

  factory ServerDashboard.fromJson(String value) {
    final decoded = jsonDecode(value);
    if (decoded is! Map) throw const FormatException('服务器状态缓存格式无效');
    final map = Map<String, Object?>.from(decoded);
    final rawCpuCores = map['cpuCores'];
    final rawDisks = map['disks'];
    final rawNetwork = map['network'];
    return ServerDashboard(
      hostname: map['hostname'] as String? ?? 'unknown',
      os: map['os'] as String? ?? 'unknown',
      kernel: map['kernel'] as String? ?? 'unknown',
      uptime: map['uptime'] as String? ?? 'unknown',
      load: map['load'] as String? ?? 'unknown',
      cpu: map['cpu'] as String? ?? 'unknown',
      cpuUsage: _readOptionalInt(map['cpuUsage']),
      cpuCores: rawCpuCores is List
          ? [
              for (final item in rawCpuCores)
                if (item is Map)
                  ServerCpuCore.fromMap(Map<String, Object?>.from(item)),
            ]
          : const [],
      memory: map['memory'] as String? ?? 'unknown',
      disk: map['disk'] as String? ?? 'unknown',
      statusScriptInstalled: map['statusScriptInstalled'] == true,
      disks: rawDisks is List
          ? [
              for (final item in rawDisks)
                if (item is Map)
                  ServerDisk.fromMap(Map<String, Object?>.from(item)),
            ]
          : const [],
      network: rawNetwork is Map
          ? ServerNetwork.fromMap(Map<String, Object?>.from(rawNetwork))
          : null,
      processCount: _readOptionalInt(map['processCount']),
    );
  }

  String toJson() => jsonEncode({
    'hostname': hostname,
    'os': os,
    'kernel': kernel,
    'uptime': uptime,
    'load': load,
    'cpu': cpu,
    'cpuUsage': cpuUsage,
    'cpuCores': [for (final item in cpuCores) item.toMap()],
    'memory': memory,
    'disk': disk,
    'statusScriptInstalled': statusScriptInstalled,
    'disks': [for (final item in disks) item.toMap()],
    'network': network?.toMap(),
    'processCount': processCount,
  });
}
