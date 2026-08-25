import 'package:flutter_test/flutter_test.dart';
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
      title: '检查服务',
      workingDirectory: '/srv/app',
      executionMode: 'confirm',
      status: 'queued',
      createdAt: DateTime.utc(2026, 8, 24),
      updatedAt: DateTime.utc(2026, 8, 24),
    );

    expect(ServerProfile.fromMap(server.toMap()).host, server.host);
    expect(Task.fromMap(task.toMap()).mode, 'agent');
    expect(server.toMap().containsKey('relayId'), isFalse);
    expect(task.toMap().containsKey('relayId'), isFalse);
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
}
