import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_agent/domain/models.dart';
import 'package:mobile_agent/local/project_files.dart';

void main() {
  test('project files support directory listing and text editing', () async {
    final root = Directory(
      '/www/mobile-agent-test-files-${DateTime.now().microsecondsSinceEpoch}',
    );
    final outside = Directory(
      '/www/mobile-agent-test-outside-${DateTime.now().microsecondsSinceEpoch}',
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
      await outside.create(recursive: true);
      await File('${outside.path}/secret.txt').writeAsString('secret');
      await Link('${root.path}/escape').create(outside.path);
      expect(
        await FileSystemEntity.type('${root.path}/escape', followLinks: false),
        FileSystemEntityType.link,
      );
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
        await files.resolveAbsoluteForIo(project, '${root.path}/new/file.bin'),
        '${root.path}/new/file.bin',
      );
      expect(
        await files.resolveAbsoluteForIo(project, '${outside.path}/file.bin'),
        isNull,
      );
      expect(
        () => files.resolve(project, '../outside.txt'),
        throwsArgumentError,
      );
      await expectLater(
        files.readText(project, 'escape/secret.txt'),
        throwsA(isA<StateError>()),
      );
      await expectLater(
        files.writeText(project, 'escape/secret.txt', 'blocked'),
        throwsA(isA<StateError>()),
      );
      await files.deleteContents(project);
      expect(await Directory(root.path).exists(), isTrue);
      expect(await File('${outside.path}/secret.txt').readAsString(), 'secret');
      expect(await files.list(project, ''), isEmpty);
    } finally {
      if (await root.exists()) await root.delete(recursive: true);
      if (await outside.exists()) await outside.delete(recursive: true);
    }
  });

  test('manual file manager supports cross-directory clipboard operations', () async {
    final project = Directory(
      '/www/mobile-agent-manual-project-${DateTime.now().microsecondsSinceEpoch}',
    );
    final outside = Directory(
      '/www/mobile-agent-manual-outside-${DateTime.now().microsecondsSinceEpoch}',
    );
    const files = ManualFileStore();
    final sourcePath = '${outside.path}/source.txt';
    final projectPath = '${project.path}/source.txt';
    final renamedPath = '${project.path}/renamed.txt';
    try {
      await project.create(recursive: true);
      await outside.create(recursive: true);
      await File(sourcePath).writeAsString('manual file');

      expect((await files.list(outside.path)).single.name, 'source.txt');
      await files.copy([sourcePath], project.path);
      expect(await File(projectPath).readAsString(), 'manual file');

      final info = await files.info(projectPath);
      expect(info.isDirectory, isFalse);
      expect(info.size, 'manual file'.length);
      await files.rename(projectPath, 'renamed.txt');
      await files.move([renamedPath], outside.path);
      expect(await File('${outside.path}/renamed.txt').exists(), isTrue);
      expect(await File(projectPath).exists(), isFalse);
    } finally {
      if (await project.exists()) await project.delete(recursive: true);
      if (await outside.exists()) await outside.delete(recursive: true);
    }
  });
}
