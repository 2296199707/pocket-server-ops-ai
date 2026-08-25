import 'dart:convert';

import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';

import '../domain/models.dart';

class AppDatabase {
  Database? _database;

  Future<Database> get _db async => _database ??= await _open();

  Future<Database> _open() async {
    final databasesPath = await getDatabasesPath();
    return openDatabase(
      path.join(databasesPath, 'mobile_agent_v1.db'),
      version: 4,
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
            apiKeyRef TEXT,
            isDefault INTEGER NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE tasks (
            id TEXT PRIMARY KEY,
            mode TEXT NOT NULL,
            serverId TEXT,
            providerId TEXT,
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
    await database.delete('task_events', where: 'taskId = ?', whereArgs: [id]);
    await database.delete('tasks', where: 'id = ?', whereArgs: [id]);
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

  Future<List<TaskEvent>> loadAllEvents() async {
    final rows = await (await _db).query(
      'task_events',
      orderBy: 'taskId, sequence',
    );
    return rows.map(_eventFromRow).toList(growable: false);
  }

  TaskEvent _eventFromRow(Map<String, Object?> row) {
    final map = Map<String, Object?>.from(row);
    map['payload'] = Map<String, Object?>.from(
      jsonDecode(row['payload'] as String) as Map,
    );
    return TaskEvent.fromMap(map);
  }

  Future<void> close() async {
    final database = _database;
    _database = null;
    await database?.close();
  }
}
