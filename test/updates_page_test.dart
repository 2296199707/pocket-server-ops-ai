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
}
