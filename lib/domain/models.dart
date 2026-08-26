// `default` is an app-only sentinel: omitting reasoning.effort lets the
// selected model use its documented default. The other values are the
// official Responses API effort values; individual models support subsets.
const reasoningEffortOptions = <String>[
  'default',
  'none',
  'minimal',
  'low',
  'medium',
  'high',
  'xhigh',
  'max',
];

const wireApiOptions = <String>['responses', 'chat-completions'];

String wireApiLabel(String value) {
  switch (value) {
    case 'responses':
      return 'Responses';
    case 'chat-completions':
      return 'Chat Completions';
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
  final String? apiKeyRef;
  final bool isDefault;

  const ProviderProfile({
    required this.id,
    required this.name,
    required this.baseUrl,
    required this.model,
    this.reasoningEffort = 'default',
    this.wireApi = 'responses',
    required this.apiKeyRef,
    required this.isDefault,
  });

  factory ProviderProfile.fromMap(Map<String, Object?> map) {
    return ProviderProfile(
      id: map['id'] as String,
      name: map['name'] as String,
      baseUrl: map['baseUrl'] as String,
      model: map['model'] as String,
      reasoningEffort: map['reasoningEffort'] as String? ?? 'default',
      wireApi: map['wireApi'] as String? ?? 'responses',
      apiKeyRef: map['apiKeyRef'] as String?,
      isDefault: map['isDefault'] as bool,
    );
  }

  Map<String, Object?> toMap() => {
    'id': id,
    'name': name,
    'baseUrl': baseUrl,
    'model': model,
    'reasoningEffort': reasoningEffort,
    'wireApi': wireApi,
    'apiKeyRef': apiKeyRef,
    'isDefault': isDefault,
  };
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
    return Task(
      id: map['id'] as String,
      mode: map['mode'] as String? ?? (serverId == null ? 'chat' : 'agent'),
      workMode: map['workMode'] as String?,
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
