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
  final String? apiKeyRef;
  final bool isDefault;

  const ProviderProfile({
    required this.id,
    required this.name,
    required this.baseUrl,
    required this.model,
    this.reasoningEffort = 'default',
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
    'apiKeyRef': apiKeyRef,
    'isDefault': isDefault,
  };
}

class Task {
  final String id;
  final String mode;
  final String? serverId;
  final String? providerId;
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
    required this.serverId,
    required this.providerId,
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
      serverId: serverId,
      providerId: map['providerId'] as String?,
      modelOverride: map['modelOverride'] as String?,
      reasoningEffortOverride: map['reasoningEffortOverride'] as String?,
      title: map['title'] as String,
      workingDirectory: map['workingDirectory'] as String?,
      executionMode: map['executionMode'] == 'auto' ? 'auto' : 'confirm',
      status: map['status'] as String,
      createdAt: _readTime(map['createdAt']),
      updatedAt: _readTime(map['updatedAt']),
    );
  }

  Map<String, Object?> toMap() => {
    'id': id,
    'mode': mode,
    'serverId': serverId,
    'providerId': providerId,
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
    String? serverId,
    String? providerId,
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
      serverId: serverId ?? this.serverId,
      providerId: providerId ?? this.providerId,
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
  final String memory;
  final String disk;
  final bool statusScriptInstalled;
  final List<ServerDisk> disks;
  final ServerNetwork? network;
  final int? processCount;
}
