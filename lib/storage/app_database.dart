import 'dart:convert';

import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';

import '../domain/models.dart';
import '../ssh/ssh_connection.dart';

class TaskEventPage {
  const TaskEventPage({required this.events, required this.hasEarlier});

  final List<TaskEvent> events;
  final bool hasEarlier;
}

class ServerDirectoryCacheRecord {
  const ServerDirectoryCacheRecord({
    required this.cacheKey,
    required this.serverId,
    required this.host,
    required this.port,
    required this.username,
    required this.remotePath,
    required this.fingerprint,
    required this.entries,
    required this.cachedAt,
    required this.checkedAt,
    required this.accessedAt,
  });

  final String cacheKey;
  final String serverId;
  final String host;
  final int port;
  final String username;
  final String remotePath;
  final String? fingerprint;
  final List<SshDirectoryEntry> entries;
  final DateTime cachedAt;
  final DateTime? checkedAt;
  final DateTime accessedAt;

  factory ServerDirectoryCacheRecord.fromMap(Map<String, Object?> map) {
    final rawEntries = jsonDecode(map['entries'] as String) as List;
    return ServerDirectoryCacheRecord(
      cacheKey: map['cacheKey'] as String,
      serverId: map['serverId'] as String,
      host: map['host'] as String,
      port: map['port'] as int,
      username: map['username'] as String,
      remotePath: map['remotePath'] as String,
      fingerprint: map['fingerprint'] as String?,
      entries: [
        for (final raw in rawEntries)
          _entryFromJson(Map<String, Object?>.from(raw as Map)),
      ],
      cachedAt: DateTime.parse(map['cachedAt'] as String),
      checkedAt: _parseDate(map['checkedAt']),
      accessedAt: DateTime.parse(map['accessedAt'] as String),
    );
  }

  Map<String, Object?> toMap() => {
    'cacheKey': cacheKey,
    'serverId': serverId,
    'host': host,
    'port': port,
    'username': username,
    'remotePath': remotePath,
    'fingerprint': fingerprint,
    'entries': jsonEncode([
      for (final entry in entries)
        {
          'name': entry.name,
          'path': entry.path,
          'isDirectory': entry.isDirectory,
          'size': entry.size,
          'modified': entry.modified?.toUtc().toIso8601String(),
        },
    ]),
    'cachedAt': cachedAt.toUtc().toIso8601String(),
    'checkedAt': checkedAt?.toUtc().toIso8601String(),
    'accessedAt': accessedAt.toUtc().toIso8601String(),
  };

  static SshDirectoryEntry _entryFromJson(Map<String, Object?> map) {
    final modified = _parseDate(map['modified']);
    return SshDirectoryEntry(
      name: map['name'] as String,
      path: map['path'] as String,
      isDirectory: map['isDirectory'] == true,
      size: (map['size'] as num?)?.toInt(),
      modified: modified,
    );
  }

  static DateTime? _parseDate(Object? value) {
    final text = value as String?;
    return text == null || text.isEmpty ? null : DateTime.parse(text);
  }
}

class AppDatabase {
  Database? _database;

  Future<Database> get _db async => _database ??= await _open();

  Future<Database> _open() async {
    final databasesPath = await getDatabasesPath();
    return openDatabase(
      path.join(databasesPath, 'mobile_agent_v1.db'),
      version: 12,
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE servers (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            host TEXT NOT NULL,
            port INTEGER NOT NULL,
            username TEXT NOT NULL,
            authType TEXT NOT NULL,
            credentialRef TEXT,
            credentialPassphraseRef TEXT,
            hostKey TEXT,
            hostKeyFingerprint TEXT,
            defaultWorkingDirectory TEXT
          )
        ''');
        await db.execute('''
          CREATE TABLE providers (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            baseUrl TEXT NOT NULL,
            model TEXT NOT NULL,
            reasoningEffort TEXT NOT NULL DEFAULT 'default',
            wireApi TEXT NOT NULL DEFAULT 'responses',
            contextWindowMode TEXT NOT NULL DEFAULT 'default',
            apiKeyRef TEXT,
            isDefault INTEGER NOT NULL,
            modelMetadata TEXT NOT NULL DEFAULT '{}'
          )
        ''');
        await db.execute('''
          CREATE TABLE projects (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            localPath TEXT NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE tasks (
            id TEXT PRIMARY KEY,
            mode TEXT NOT NULL,
            workMode TEXT,
            projectId TEXT,
            serverId TEXT,
            providerId TEXT,
            reviewProviderId TEXT,
            reviewModelOverride TEXT,
            modelOverride TEXT,
            reasoningEffortOverride TEXT,
            title TEXT NOT NULL,
            workingDirectory TEXT,
            executionMode TEXT NOT NULL,
            status TEXT NOT NULL,
            createdAt TEXT NOT NULL,
            updatedAt TEXT NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE task_events (
            eventId TEXT PRIMARY KEY,
            taskId TEXT NOT NULL,
            sequence INTEGER NOT NULL,
            type TEXT NOT NULL,
            timestamp TEXT NOT NULL,
            payload TEXT NOT NULL
          )
        ''');
        await db.execute(
          'CREATE INDEX task_events_task_sequence '
          'ON task_events(taskId, sequence)',
        );
        await db.execute('''
          CREATE TABLE attachments (
            id TEXT PRIMARY KEY,
            taskId TEXT NOT NULL,
            name TEXT NOT NULL,
            mimeType TEXT NOT NULL,
            byteLength INTEGER NOT NULL,
            storagePath TEXT NOT NULL,
            createdAt TEXT NOT NULL
          )
        ''');
        await db.execute(
          'CREATE INDEX attachments_task ON attachments(taskId)',
        );
        await db.execute('''
          CREATE TABLE settings (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE server_directory_cache (
            cacheKey TEXT PRIMARY KEY,
            serverId TEXT NOT NULL,
            host TEXT NOT NULL,
            port INTEGER NOT NULL,
            username TEXT NOT NULL,
            remotePath TEXT NOT NULL,
            fingerprint TEXT,
            entries TEXT NOT NULL,
            cachedAt TEXT NOT NULL,
            checkedAt TEXT,
            accessedAt TEXT NOT NULL
          )
        ''');
        await db.execute(
          'CREATE INDEX server_directory_cache_server '
          'ON server_directory_cache(serverId)',
        );
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute('''
            CREATE TABLE settings (
              key TEXT PRIMARY KEY,
              value TEXT NOT NULL
            )
          ''');
        }
        if (oldVersion < 3) {
          await db.execute(
            "ALTER TABLE providers ADD COLUMN reasoningEffort TEXT NOT NULL DEFAULT 'default'",
          );
        }
        if (oldVersion < 4) {
          await db.execute('ALTER TABLE tasks ADD COLUMN modelOverride TEXT');
          await db.execute(
            'ALTER TABLE tasks ADD COLUMN reasoningEffortOverride TEXT',
          );
        }
        if (oldVersion < 5) {
          await db.execute('''
            CREATE TABLE projects (
              id TEXT PRIMARY KEY,
              name TEXT NOT NULL,
              localPath TEXT NOT NULL
            )
          ''');
          await db.execute('ALTER TABLE tasks ADD COLUMN projectId TEXT');
        }
        if (oldVersion < 6) {
          await db.execute(
            "ALTER TABLE providers ADD COLUMN wireApi TEXT NOT NULL DEFAULT 'responses'",
          );
        }
        if (oldVersion < 7) {
          await db.execute(
            'ALTER TABLE tasks ADD COLUMN reviewProviderId TEXT',
          );
          await db.execute(
            'ALTER TABLE tasks ADD COLUMN reviewModelOverride TEXT',
          );
        }
        if (oldVersion < 8) {
          await db.execute('ALTER TABLE tasks ADD COLUMN workMode TEXT');
        }
        if (oldVersion < 9) {
          await db.execute(
            'CREATE INDEX task_events_task_sequence '
            'ON task_events(taskId, sequence)',
          );
          await db.execute('''
            CREATE TABLE attachments (
              id TEXT PRIMARY KEY,
              taskId TEXT NOT NULL,
              name TEXT NOT NULL,
              mimeType TEXT NOT NULL,
              byteLength INTEGER NOT NULL,
              storagePath TEXT NOT NULL,
              createdAt TEXT NOT NULL
            )
          ''');
          await db.execute(
            'CREATE INDEX attachments_task ON attachments(taskId)',
          );
        }
        if (oldVersion < 10) {
          await db.execute(
            "ALTER TABLE providers ADD COLUMN modelMetadata TEXT NOT NULL DEFAULT '{}'",
          );
        }
        if (oldVersion < 11) {
          await db.execute(
            "ALTER TABLE providers ADD COLUMN contextWindowMode TEXT NOT NULL DEFAULT 'default'",
          );
        }
        if (oldVersion < 12) {
          await db.execute('''
            CREATE TABLE server_directory_cache (
              cacheKey TEXT PRIMARY KEY,
              serverId TEXT NOT NULL,
              host TEXT NOT NULL,
              port INTEGER NOT NULL,
              username TEXT NOT NULL,
              remotePath TEXT NOT NULL,
              fingerprint TEXT,
              entries TEXT NOT NULL,
              cachedAt TEXT NOT NULL,
              checkedAt TEXT,
              accessedAt TEXT NOT NULL
            )
          ''');
          await db.execute(
            'CREATE INDEX server_directory_cache_server '
            'ON server_directory_cache(serverId)',
          );
        }
      },
    );
  }

  Future<String?> readSetting(String key) async {
    final rows = await (await _db).query(
      'settings',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  Future<void> writeSetting(String key, String value) async {
    await (await _db).insert('settings', {
      'key': key,
      'value': value,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<ServerProfile>> loadServers() async {
    final rows = await (await _db).query('servers', orderBy: 'name');
    return rows
        .map((row) => ServerProfile.fromMap(Map<String, Object?>.from(row)))
        .toList(growable: false);
  }

  Future<void> saveServer(ServerProfile profile) async {
    await (await _db).insert(
      'servers',
      profile.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> deleteServer(String id) async {
    await (await _db).delete('servers', where: 'id = ?', whereArgs: [id]);
  }

  Future<List<ServerDirectoryCacheRecord>> loadServerDirectoryCaches() async {
    final rows = await (await _db).query(
      'server_directory_cache',
      orderBy: 'accessedAt DESC',
    );
    return rows
        .map(
          (row) => ServerDirectoryCacheRecord.fromMap(
            Map<String, Object?>.from(row),
          ),
        )
        .toList(growable: false);
  }

  Future<void> saveServerDirectoryCache(
    ServerDirectoryCacheRecord record,
  ) async {
    final database = await _db;
    await database.insert(
      'server_directory_cache',
      record.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    await database.rawDelete('''
      DELETE FROM server_directory_cache
      WHERE cacheKey NOT IN (
        SELECT cacheKey FROM server_directory_cache
        ORDER BY accessedAt DESC
        LIMIT 256
      )
    ''');
  }

  Future<void> deleteServerDirectoryCaches(String serverId) async {
    await (await _db).delete(
      'server_directory_cache',
      where: 'serverId = ?',
      whereArgs: [serverId],
    );
  }

  Future<void> deleteServerDirectoryCache(String cacheKey) async {
    await (await _db).delete(
      'server_directory_cache',
      where: 'cacheKey = ?',
      whereArgs: [cacheKey],
    );
  }

  Future<List<ProviderProfile>> loadProviders() async {
    final rows = await (await _db).query('providers', orderBy: 'name');
    return rows
        .map((row) {
          final map = Map<String, Object?>.from(row);
          map['isDefault'] = map['isDefault'] == 1;
          return ProviderProfile.fromMap(map);
        })
        .toList(growable: false);
  }

  Future<void> clearProviderDefaults() async {
    await (await _db).update('providers', {'isDefault': 0});
  }

  Future<void> saveProvider(ProviderProfile profile) async {
    final map = Map<String, Object?>.from(profile.toMap());
    map['isDefault'] = profile.isDefault ? 1 : 0;
    await (await _db).insert(
      'providers',
      map,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> deleteProvider(String id) async {
    await (await _db).delete('providers', where: 'id = ?', whereArgs: [id]);
  }

  Future<List<Project>> loadProjects() async {
    final rows = await (await _db).query('projects', orderBy: 'name');
    return rows
        .map((row) => Project.fromMap(Map<String, Object?>.from(row)))
        .toList(growable: false);
  }

  Future<void> saveProject(Project project) async {
    await (await _db).insert(
      'projects',
      project.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> deleteProject(String id) async {
    await (await _db).delete('projects', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> saveTask(Task task) async {
    await (await _db).insert(
      'tasks',
      task.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<Task>> loadTasks() async {
    final rows = await (await _db).query('tasks', orderBy: 'updatedAt DESC');
    return rows
        .map((row) => Task.fromMap(Map<String, Object?>.from(row)))
        .toList(growable: false);
  }

  Future<void> deleteTask(String id) async {
    final database = await _db;
    await database.transaction((transaction) async {
      await transaction.delete(
        'task_events',
        where: 'taskId = ?',
        whereArgs: [id],
      );
      await transaction.delete(
        'attachments',
        where: 'taskId = ?',
        whereArgs: [id],
      );
      await transaction.delete('tasks', where: 'id = ?', whereArgs: [id]);
    });
  }

  Future<void> saveEvent(TaskEvent event) async {
    final map = Map<String, Object?>.from(event.toMap());
    map['payload'] = jsonEncode(event.payload);
    await (await _db).insert(
      'task_events',
      map,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<TaskEvent>> loadEvents(String taskId) async {
    final rows = await (await _db).query(
      'task_events',
      where: 'taskId = ?',
      whereArgs: [taskId],
      orderBy: 'sequence',
    );
    return rows.map(_eventFromRow).toList(growable: false);
  }

  /// Scans only event payloads that may contain attachment references, in
  /// small pages. Cleanup needs the references, not the complete event
  /// history, so a long conversation does not create a large temporary list.
  Future<Set<String>> loadReferencedAttachmentIds() async {
    final database = await _db;
    const pageSize = 128;
    var offset = 0;
    final ids = <String>{};
    while (true) {
      final rows = await database.query(
        'task_events',
        columns: ['payload'],
        where: 'payload LIKE ?',
        whereArgs: ['%"attachment_id"%'],
        orderBy: 'eventId',
        limit: pageSize,
        offset: offset,
      );
      for (final row in rows) {
        final decoded = jsonDecode(row['payload'] as String);
        _collectAttachmentIds(decoded, ids);
      }
      if (rows.length < pageSize) break;
      offset += rows.length;
    }
    return Set.unmodifiable(ids);
  }

  /// Reads only assistant payloads needed to rebuild context usage. This keeps
  /// the context indicator independent from the UI's paged event list and
  /// avoids loading old user attachments into memory.
  Future<List<Map<String, Object?>>> loadAssistantUsagePayloads(
    String taskId,
  ) async {
    final database = await _db;
    final contextRows = await database.query(
      'task_events',
      columns: ['sequence', 'payload'],
      where: "taskId = ? AND type = 'task.context_changed'",
      whereArgs: [taskId],
      orderBy: 'sequence',
    );
    var startSequence = 0;
    for (final row in contextRows) {
      final payload = _decodePayload(row['payload']);
      if (_isHistoryBoundary(payload)) {
        startSequence = row['sequence'] as int;
      }
    }
    var providerProjectionSequence = startSequence;
    for (final row in contextRows) {
      final sequence = row['sequence'] as int;
      if (sequence > providerProjectionSequence &&
          _requiresProviderProjection(_decodePayload(row['payload']))) {
        providerProjectionSequence = sequence;
      }
    }
    final rows = await database.query(
      'task_events',
      columns: ['payload'],
      where:
          "taskId = ? AND type IN ('assistant.completed', 'context.compacted') "
          'AND sequence > ?',
      whereArgs: [taskId, providerProjectionSequence],
      orderBy: 'sequence',
    );
    return [
      for (final row in rows)
        Map<String, Object?>.from(jsonDecode(row['payload'] as String) as Map),
    ];
  }

  Future<List<TaskEvent>> loadModelEvents(
    String taskId, {
    bool useCompactionBoundary = true,
  }) async {
    final database = await _db;
    final contextRows = await database.query(
      'task_events',
      columns: ['sequence', 'payload'],
      where: "taskId = ? AND type = 'task.context_changed'",
      whereArgs: [taskId],
      orderBy: 'sequence',
    );
    var startSequence = 0;
    for (final row in contextRows) {
      final payload = _decodePayload(row['payload']);
      if (_isHistoryBoundary(payload)) {
        startSequence = row['sequence'] as int;
      }
    }
    var providerProjectionSequence = startSequence;
    for (final row in contextRows) {
      final sequence = row['sequence'] as int;
      if (sequence > providerProjectionSequence &&
          _requiresProviderProjection(_decodePayload(row['payload']))) {
        providerProjectionSequence = sequence;
      }
    }
    String? compactedTurnId;
    if (useCompactionBoundary) {
      const scanPageSize = 32;
      var offset = 0;
      var foundCompaction = false;
      while (!foundCompaction) {
        final rows = await database.query(
          'task_events',
          columns: ['sequence', 'payload'],
          where:
              "taskId = ? AND type IN ('assistant.completed', 'context.compacted') "
              'AND sequence >= ?',
          whereArgs: [taskId, providerProjectionSequence],
          orderBy: 'sequence DESC',
          limit: scanPageSize,
          offset: offset,
        );
        for (final row in rows) {
          final payload = Map<String, Object?>.from(
            jsonDecode(row['payload'] as String) as Map,
          );
          if (_payloadHasCompaction(payload)) {
            startSequence = row['sequence'] as int;
            final turnId = payload['turn_id'];
            compactedTurnId = turnId is String && turnId.isNotEmpty
                ? turnId
                : null;
            foundCompaction = true;
            break;
          }
        }
        if (foundCompaction || rows.length < scanPageSize) break;
        offset += rows.length;
      }
    }
    final rows = await database.query(
      'task_events',
      where: 'taskId = ? AND sequence >= ?',
      whereArgs: [taskId, startSequence],
      orderBy: 'sequence',
    );
    final events = rows.map(_eventFromRow).toList(growable: false);
    if (compactedTurnId == null) return events;
    final compactedEvent = events.firstWhere(
      (event) => event.sequence == startSequence,
    );
    if (compactedEvent.payload['retained_current_turn_user'] == true) {
      return events;
    }

    // The app durably records the new user message before compaction so a
    // setup failure cannot lose it. Codex compacts before recording that
    // message, so restore the same logical order when reading model history.
    final precedingUserRows = await database.query(
      'task_events',
      where: "taskId = ? AND type = 'user.message' AND sequence < ?",
      whereArgs: [taskId, startSequence],
      orderBy: 'sequence DESC',
      limit: 1,
    );
    if (precedingUserRows.isEmpty) return events;
    final precedingUser = _eventFromRow(precedingUserRows.single);
    if (precedingUser.payload['turn_id'] != compactedTurnId) return events;

    return [
      for (final event in events) ...[
        event,
        if (event.sequence == startSequence) precedingUser,
      ],
    ];
  }

  Future<TaskEventPage> loadRecentEvents(
    String taskId, {
    int limit = 40,
  }) async {
    final rows = await (await _db).query(
      'task_events',
      where: 'taskId = ?',
      whereArgs: [taskId],
      orderBy: 'sequence DESC',
      limit: limit + 1,
    );
    final hasEarlier = rows.length > limit;
    final selected = hasEarlier ? rows.take(limit) : rows;
    return TaskEventPage(
      events: selected
          .map(_eventFromRow)
          .toList(growable: false)
          .reversed
          .toList(growable: false),
      hasEarlier: hasEarlier,
    );
  }

  Future<TaskEventPage> loadEventsBefore(
    String taskId, {
    required int beforeSequence,
    int limit = 40,
  }) async {
    final rows = await (await _db).query(
      'task_events',
      where: 'taskId = ? AND sequence < ?',
      whereArgs: [taskId, beforeSequence],
      orderBy: 'sequence DESC',
      limit: limit + 1,
    );
    final hasEarlier = rows.length > limit;
    final selected = hasEarlier ? rows.take(limit) : rows;
    return TaskEventPage(
      events: selected
          .map(_eventFromRow)
          .toList(growable: false)
          .reversed
          .toList(growable: false),
      hasEarlier: hasEarlier,
    );
  }

  Future<TaskEvent?> loadLatestEvent(String taskId) async {
    final rows = await (await _db).query(
      'task_events',
      where: 'taskId = ?',
      whereArgs: [taskId],
      orderBy: 'sequence DESC',
      limit: 1,
    );
    return rows.isEmpty ? null : _eventFromRow(rows.first);
  }

  Future<TaskEvent?> loadLatestTerminalEvent(String taskId) async {
    final rows = await (await _db).query(
      'task_events',
      where:
          "taskId = ? AND type IN ('task.completed', 'task.failed', "
          "'task.cancelled', 'task.unknown')",
      whereArgs: [taskId],
      orderBy: 'sequence DESC',
      limit: 1,
    );
    return rows.isEmpty ? null : _eventFromRow(rows.first);
  }

  Future<int> nextEventSequence(String taskId) async {
    final rows = await (await _db).rawQuery(
      'SELECT MAX(sequence) AS value FROM task_events WHERE taskId = ?',
      [taskId],
    );
    return ((rows.first['value'] as int?) ?? 0) + 1;
  }

  Future<void> saveAttachments(List<AttachmentRecord> records) async {
    if (records.isEmpty) return;
    final database = await _db;
    await database.transaction((transaction) async {
      for (final record in records) {
        await transaction.insert(
          'attachments',
          record.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    });
  }

  Future<AttachmentRecord?> loadAttachment(String id) async {
    final rows = await (await _db).query(
      'attachments',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty
        ? null
        : AttachmentRecord.fromMap(Map<String, Object?>.from(rows.first));
  }

  Future<List<AttachmentRecord>> loadAttachments() async {
    final rows = await (await _db).query('attachments', orderBy: 'createdAt');
    return rows
        .map((row) => AttachmentRecord.fromMap(Map<String, Object?>.from(row)))
        .toList(growable: false);
  }

  Future<void> deleteAttachments(List<String> ids) async {
    if (ids.isEmpty) return;
    final placeholders = List.filled(ids.length, '?').join(',');
    await (await _db).delete(
      'attachments',
      where: 'id IN ($placeholders)',
      whereArgs: ids,
    );
  }

  Future<List<TaskEvent>> loadLegacyAttachmentEvents(String taskId) async {
    final rows = await (await _db).query(
      'task_events',
      where:
          "taskId = ? AND ((type = 'user.message' AND payload LIKE ?) OR "
          "(type = 'tool.completed' AND payload LIKE ?))",
      whereArgs: [taskId, '%"base64"%', '%"data_url":"data:image/%'],
      orderBy: 'sequence',
    );
    return rows.map(_eventFromRow).toList(growable: false);
  }

  Future<void> replaceEventAttachments(
    TaskEvent event,
    List<AttachmentRecord> records,
  ) async {
    final database = await _db;
    await database.transaction((transaction) async {
      for (final record in records) {
        await transaction.insert(
          'attachments',
          record.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await transaction.update(
        'task_events',
        {'payload': jsonEncode(event.payload)},
        where: 'eventId = ?',
        whereArgs: [event.eventId],
      );
    });
  }

  TaskEvent _eventFromRow(Map<String, Object?> row) {
    final map = Map<String, Object?>.from(row);
    map['payload'] = Map<String, Object?>.from(
      jsonDecode(row['payload'] as String) as Map,
    );
    return TaskEvent.fromMap(map);
  }

  static bool _payloadHasCompaction(Map<String, Object?> payload) {
    if (payload['compaction_mode'] == 'local' &&
        payload['summary'] is String &&
        (payload['summary'] as String).trim().isNotEmpty) {
      return true;
    }
    final items = payload['responses_output_items'];
    return items is List &&
        items.any((item) => item is Map && item['type'] == 'compaction');
  }

  static Map<String, Object?> _decodePayload(Object? value) {
    return Map<String, Object?>.from(jsonDecode(value as String) as Map);
  }

  static bool _isHistoryBoundary(Map<String, Object?> payload) {
    // Task configuration changes are context notes, never a request to discard
    // the transcript. Compaction has its own boundary and is handled above.
    return false;
  }

  static bool _requiresProviderProjection(Map<String, Object?> payload) {
    return payload['history_boundary'] == false &&
        payload['history_projection'] == 'provider';
  }

  static void _collectAttachmentIds(Object? value, Set<String> ids) {
    if (value is Map) {
      for (final entry in value.entries) {
        if (entry.key == 'attachment_id' && entry.value is String) {
          ids.add(entry.value as String);
        } else {
          _collectAttachmentIds(entry.value, ids);
        }
      }
    } else if (value is Iterable) {
      for (final item in value) {
        _collectAttachmentIds(item, ids);
      }
    }
  }

  Future<void> close() async {
    final database = _database;
    _database = null;
    await database?.close();
  }
}
