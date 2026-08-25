import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_agent/domain/models.dart';
import 'package:mobile_agent/local/project_files.dart';

void main() {
  test('project files support directory listing and text editing', () async {
    final root = Directory(
      '/www/mobile-agent-test-files-${DateTime.now().microsecondsSinceEpoch}',
    );
    final project = Project(
      id: 'project-1',
      name: '测试项目',
      localPath: root.path,
    );
    const files = ProjectFileStore();
    try {
      await files.ensureRoot(project);
      await files.createDirectory(project, 'lib');
      await files.writeText(project, 'lib/main.txt', '旧内容');
      expect(await files.readText(project, 'lib/main.txt'), '旧内容');

      await files.replaceText(project, 'lib/main.txt', '旧内容', '新内容');
      expect(await files.readText(project, 'lib/main.txt'), '新内容');
      final entries = await files.list(project, 'lib');
      expect(entries.single.name, 'main.txt');
      expect(entries.single.isDirectory, isFalse);
      expect(
        files.resolve(project, 'lib/main.txt'),
        '${root.path}/lib/main.txt',
      );
      expect(
        () => files.resolve(project, '../outside.txt'),
        throwsArgumentError,
      );
    } finally {
      if (await root.exists()) await root.delete(recursive: true);
    }
  });
}
