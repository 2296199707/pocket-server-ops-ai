import 'dart:convert';

import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';

import '../domain/models.dart';

class TaskEventPage {
  const TaskEventPage({required this.events, required this.hasEarlier});

  final List<TaskEvent> events;
  final bool hasEarlier;
}

class AppDatabase {
  Database? _database;

  Future<Database> get _db async => _database ??= await _open();

  Future<Database> _open() async {
    final databasesPath = await getDatabasesPath();
    return openDatabase(
      path.join(databasesPath, 'mobile_agent_v1.db'),
      version: 9,
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
            apiKeyRef TEXT,
            isDefault INTEGER NOT NULL
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

  Future<List<TaskEvent>> loadModelEvents(
    String taskId, {
    bool useCompactionBoundary = true,
  }) async {
    final database = await _db;
    final boundaryRows = await database.query(
      'task_events',
      columns: ['sequence'],
      where: "taskId = ? AND type = 'task.context_changed'",
      whereArgs: [taskId],
      orderBy: 'sequence DESC',
      limit: 1,
    );
    var startSequence = boundaryRows.isEmpty
        ? 0
        : boundaryRows.first['sequence'] as int;
    if (useCompactionBoundary) {
      const scanPageSize = 32;
      var offset = 0;
      var foundCompaction = false;
      while (!foundCompaction) {
        final rows = await database.query(
          'task_events',
          columns: ['sequence', 'payload'],
          where:
              "taskId = ? AND type = 'assistant.completed' AND sequence >= ?",
          whereArgs: [taskId, startSequence],
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
    return rows.map(_eventFromRow).toList(growable: false);
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
    final items = payload['responses_output_items'];
    return items is List &&
        items.any((item) => item is Map && item['type'] == 'compaction');
  }

  Future<void> close() async {
    final database = _database;
    _database = null;
    await database?.close();
  }
}
