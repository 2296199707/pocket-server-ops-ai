import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_agent/domain/models.dart';
import 'package:mobile_agent/local/local_preview.dart';
import 'package:mobile_agent/local/project_files.dart';

void main() {
  test('local preview serves project files on loopback and blocks links out', () async {
    final root = Directory(
      '/www/mobile-agent-preview-${DateTime.now().microsecondsSinceEpoch}',
    );
    final outside = Directory(
      '/www/mobile-agent-preview-outside-${DateTime.now().microsecondsSinceEpoch}',
    );
    final project = Project(
      id: 'preview-project',
      name: '预览项目',
      localPath: root.path,
    );
    const files = ProjectFileStore();
    final preview = LocalPreviewServer(files: files);
    final client = HttpClient();
    try {
      await files.ensureRoot(project);
      await files.writeText(
        project,
        'index.html',
        '<!doctype html><script src="app.js"></script>',
      );
      await files.writeText(project, 'app.js', 'console.log("ok")');
      await outside.create(recursive: true);
      await File('${outside.path}/secret.txt').writeAsString('secret');
      await Link('${root.path}/escape').create(outside.path);

      final status = await preview.start(project);
      final request = await client.getUrl(Uri.parse(status.url!));
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      expect(response.statusCode, HttpStatus.ok);
      expect(body, contains('app.js'));
      expect(status.url, startsWith('http://127.0.0.1:'));

      final escapedRequest = await client.getUrl(
        Uri.parse(
          '${status.url!.replaceFirst('/index.html', '')}/escape/secret.txt',
        ),
      );
      final escaped = await escapedRequest.close();
      expect(escaped.statusCode, HttpStatus.notFound);
      await escaped.drain<void>();

      final logs = preview.logs(project, limit: 20);
      expect(logs.any((log) => log.source == 'http'), isTrue);
      await preview.stop(project);
    } finally {
      client.close(force: true);
      await preview.close();
      if (await root.exists()) await root.delete(recursive: true);
      if (await outside.exists()) await outside.delete(recursive: true);
    }
  });

  test('web check reports missing HTML and CSS resources', () async {
    final root = Directory(
      '/www/mobile-agent-web-check-${DateTime.now().microsecondsSinceEpoch}',
    );
    final project = Project(
      id: 'web-check-project',
      name: '网页检查',
      localPath: root.path,
    );
    const files = ProjectFileStore();
    final preview = LocalPreviewServer(files: files);
    try {
      await files.ensureRoot(project);
      await files.writeText(
        project,
        'index.html',
        '<link href="styles.css"><script src="missing.js"></script>',
      );
      await files.writeText(
        project,
        'styles.css',
        'body { background: url("missing.png"); }',
      );

      final result = await preview.testWeb(project);
      expect(result.ok, isFalse);
      expect(
        result.issues.map((issue) => issue.resource),
        containsAll(<String>['missing.js', 'missing.png']),
      );
      expect(
        result.checkedFiles,
        containsAll(<String>['index.html', 'styles.css']),
      );
    } finally {
      await preview.close();
      if (await root.exists()) await root.delete(recursive: true);
    }
  });

  test('preview log cursor and reload marker are incremental', () async {
    final root = Directory(
      '/www/mobile-agent-preview-log-${DateTime.now().microsecondsSinceEpoch}',
    );
    final project = Project(
      id: 'preview-log-project',
      name: '日志项目',
      localPath: root.path,
    );
    final preview = LocalPreviewServer();
    try {
      await preview.start(project);
      final before = preview.status(project);
      preview.recordLog(
        project,
        level: 'error',
        source: 'javascript',
        message: 'boom',
      );
      final reloaded = preview.reload(project);
      final logs = preview.logs(project, after: before.logSequence);

      expect(reloaded.reloadToken, 1);
      expect(logs.map((log) => log.message), contains('boom'));
      expect(logs.every((log) => log.sequence > before.logSequence), isTrue);
    } finally {
      await preview.close();
      if (await root.exists()) await root.delete(recursive: true);
    }
  });
}
