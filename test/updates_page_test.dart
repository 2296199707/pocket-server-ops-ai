import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:mobile_agent/ui/updates_page.dart';

void main() {
  test('release versions are sorted and APK asset is selected', () async {
    final service = UpdateService(
      client: MockClient((request) async {
        return http.Response(
          '[{"tag_name":"v1.0.1","name":"Older","body":"old",'
          '"html_url":"https://github.com/2296199707/pocket-server-ops-ai/releases/tag/v1.0.1",'
          '"published_at":"2026-08-01T00:00:00Z","assets":[]},'
          '{"tag_name":"v1.0.2","name":"Current","body":"new",'
          '"html_url":"https://github.com/2296199707/pocket-server-ops-ai/releases/tag/v1.0.2",'
          '"published_at":"2026-08-02T00:00:00Z","assets":['
          '{"name":"pocket-server-ops-ai-v1.0.2-release.apk",'
          '"browser_download_url":"https://github.com/download.apk"}],'
          '"prerelease":false},'
          '{"tag_name":"v1.0.3-beta.1","name":"Beta", "body":"beta",'
          '"html_url":"https://github.com/2296199707/pocket-server-ops-ai/releases/tag/v1.0.3-beta.1",'
          '"published_at":"2026-08-03T00:00:00Z","prerelease":true,"assets":[]}]',
          200,
        );
      }),
    );
    addTearDown(service.close);

    final releases = await service.fetchReleases();

    expect(releases.map((release) => release.version), ['1.0.2', '1.0.1']);
    expect(releases.first.apkUrl.toString(), 'https://github.com/download.apk');

    final withBeta = await service.fetchReleases(includePrereleases: true);
    expect(withBeta.first.isPrerelease, isTrue);
    expect(withBeta.first.version, '1.0.3-beta.1');
  });

  test('version comparison ignores a leading v', () {
    expect(UpdateService.compareVersions('v1.0.2', '1.0.0'), greaterThan(0));
    expect(UpdateService.compareVersions('1.0.2', 'v1.0.2'), 0);
    expect(UpdateService.compareVersions('1.0.1', '1.0.2'), lessThan(0));
    expect(
      UpdateService.compareVersions('1.0.3-beta.2', '1.0.3-beta.1'),
      greaterThan(0),
    );
    expect(
      UpdateService.compareVersions('1.0.3', '1.0.3-beta.9'),
      greaterThan(0),
    );
  });

  test(
    'static update channels read the manifest from their own hosts',
    () async {
      const manifest = '''
{
  "releases": [
    {
      "version": "1.0.3-beta.23",
      "title": "Beta",
      "release_url": "https://github.com/example/beta",
      "apk_url": "https://github.com/example/beta.apk",
      "prerelease": true,
      "published_at": "2026-08-28T18:23:06Z"
    },
    {
      "version": "1.0.2",
      "title": "Stable",
      "release_url": "https://github.com/example/stable",
      "apk_url": "https://github.com/example/stable.apk",
      "prerelease": false,
      "published_at": "2026-08-25T16:59:41Z"
    }
  ]
}
''';
      final requests = <http.Request>[];
      final service = UpdateService(
        client: MockClient((request) async {
          requests.add(request);
          return http.Response(manifest, 200);
        }),
      );
      addTearDown(service.close);

      final stable = await service.fetchReleases(
        source: UpdateSource.githubRaw,
      );
      expect(requests.single.url.host, 'raw.githubusercontent.com');
      expect(requests.single.url.path, contains('/beta/updates/releases.json'));
      expect(stable.map((release) => release.version), ['1.0.2']);

      final beta = await service.fetchReleases(
        source: UpdateSource.jsDelivr,
        includePrereleases: true,
      );
      expect(requests[1].url.host, 'cdn.jsdelivr.net');
      expect(requests[1].url.path, contains('/updates/releases.json'));
      expect(beta.map((release) => release.version), [
        '1.0.3-beta.23',
        '1.0.2',
      ]);
    },
  );

  testWidgets('update page shows the concrete source buttons', (tester) async {
    final service = UpdateService(
      client: MockClient((_) async => http.Response('{}', 200)),
    );
    addTearDown(service.close);

    await tester.pumpWidget(MaterialApp(home: UpdatesPage(service: service)));
    await tester.pump();

    expect(find.text('GitHub API'), findsOneWidget);
    expect(find.text('GitHub Raw'), findsOneWidget);
    expect(find.text('jsDelivr CDN'), findsOneWidget);
  });

  test('downloads an APK to a local file and reports progress', () async {
    final bytes = List<int>.generate(2048, (index) => index % 251);
    final service = UpdateService(
      client: MockClient((request) async {
        expect(request.method, 'GET');
        return http.Response.bytes(bytes, 200);
      }),
    );
    addTearDown(service.close);
    final destination = await Directory.systemTemp.createTemp(
      'pocket-server-ops-update-',
    );
    addTearDown(() => destination.delete(recursive: true));
    final release = AppRelease(
      version: '1.0.3-beta.17',
      title: 'Beta',
      notes: '',
      releaseUrl: Uri.parse('https://github.com/example/release'),
      isPrerelease: true,
      apkUrl: Uri.parse('https://github.com/example/app.apk'),
    );
    final progress = <List<int>>[];

    final file = await service.downloadApk(
      release,
      destination,
      onProgress: (received, total) => progress.add([received, total ?? -1]),
    );

    expect(await file.readAsBytes(), bytes);
    expect(file.path, contains('pocket-server-ops-ai-v1.0.3-beta.17.apk'));
    expect(progress.first, [0, bytes.length]);
    expect(progress.last, [bytes.length, bytes.length]);
    expect(await File('${file.path}.part').exists(), isFalse);
  });
}
