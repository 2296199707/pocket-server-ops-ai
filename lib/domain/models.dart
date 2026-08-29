import 'dart:convert';

// `default` is an app-only sentinel: omitting reasoning.effort lets the
// selected model use its documented default. Explicit values come from the
// selected model's provider metadata.
const defaultReasoningEffort = 'default';

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
}) {
  final selected = workMode?.trim();
  if (selected != null && workModeOptions.contains(selected)) return selected;
  if (mode == 'chat') return 'chat';
  final hasProject = projectId?.isNotEmpty == true;
  final hasServer = serverId?.isNotEmpty == true;
  if (hasProject && hasServer) return 'collaborative';
  if (hasServer) return 'server';
  return 'local';
}

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
  });

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
    );
  }
}

class ProviderProfile {
  final String id;
  final String name;
  final String baseUrl;
  final String model;
  final String reasoningEffort;
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
      reasoningEffort: map['reasoningEffort'] as String? ?? 'default',
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
    'reasoningEffort': reasoningEffort,
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
      reasoningEffort: reasoningEffort ?? this.reasoningEffort,
      wireApi: wireApi ?? this.wireApi,
      contextWindowMode: contextWindowMode ?? this.contextWindowMode,
      apiKeyRef: apiKeyRef ?? this.apiKeyRef,
      isDefault: isDefault ?? this.isDefault,
      modelMetadata: modelMetadata ?? this.modelMetadata,
    );
  }
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
        map['contextWindowTokens'] ?? map['context_window'],
      ),
      maxContextWindowTokens: _readOptionalInt(
        map['maxContextWindowTokens'] ?? map['max_context_window'],
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
            map['reasoning_efforts'],
      ),
      inputModalities: _readOptionalStringList(
        map['inputModalities'] ?? map['input_modalities'],
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

bool? _readOptionalBool(Object? value) => value is bool ? value : null;

List<String>? _readOptionalStringList(Object? value) {
  if (value is! List) return null;
  return List.unmodifiable([
    for (final item in value)
      if (item is String) item,
  ]);
}

List<ProviderReasoningLevel>? _readOptionalReasoningLevels(Object? value) {
  if (value is! List) return null;
  final levels = <ProviderReasoningLevel>[];
  for (final item in value) {
    try {
      levels.add(ProviderReasoningLevel.fromMap(item));
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
  }
  if (preserveCurrent != null &&
      preserveCurrent.trim().isNotEmpty &&
      !values.contains(preserveCurrent)) {
    // Keep an old explicit setting visible until the user replaces it. The
    // UI marks it as unconfirmed when the provider did not advertise it.
    values.add(preserveCurrent);
  }
  return values;
}

class Task {
  final String id;
  final String mode;
  final String? workMode;
  final String? projectId;
  final String? serverId;
  final String? providerId;
  final String? reviewProviderId;
  final String? reviewModelOverride;
  final String? modelOverride;
  final String? reasoningEffortOverride;
  final String title;
  final String? workingDirectory;
  final String executionMode;
  final String status;
  final DateTime createdAt;
  final DateTime updatedAt;

  const Task({
    required this.id,
    required this.mode,
    this.workMode,
    this.projectId,
    required this.serverId,
    required this.providerId,
    this.reviewProviderId,
    this.reviewModelOverride,
    this.modelOverride,
    this.reasoningEffortOverride,
    required this.title,
    required this.workingDirectory,
    required this.executionMode,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
  });

  factory Task.fromMap(Map<String, Object?> map) {
    final serverId = map['serverId'] as String?;
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
    'providerId': providerId,
    'reviewProviderId': reviewProviderId,
    'reviewModelOverride': reviewModelOverride,
    'modelOverride': modelOverride,
    'reasoningEffortOverride': reasoningEffortOverride,
    'title': title,
    'workingDirectory': workingDirectory,
    'executionMode': executionMode,
    'status': status,
    'createdAt': _writeTime(createdAt),
    'updatedAt': _writeTime(updatedAt),
  };

  Task copyWith({
    String? mode,
    Object? workMode = _taskFieldUnset,
    Object? projectId = _taskFieldUnset,
    String? serverId,
    String? providerId,
    Object? reviewProviderId = _taskFieldUnset,
    Object? reviewModelOverride = _taskFieldUnset,
    String? modelOverride,
    String? reasoningEffortOverride,
    String? title,
    String? workingDirectory,
    String? executionMode,
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
  );
}

const _taskFieldUnset = Object();

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
  final String memory;
  final String disk;
  final bool statusScriptInstalled;
  final List<ServerDisk> disks;
  final ServerNetwork? network;
  final int? processCount;
}
