import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../platform/app_update_installer.dart';

const _repositoryOwner = '2296199707';
const _repositoryName = 'pocket-server-ops-ai';
const _fallbackVersion = '1.0.3-beta.24';

typedef UpdateDownloadProgress = void Function(int received, int? total);

enum UpdateSource {
  githubApi('GitHub API', 'api.github.com'),
  githubRaw('GitHub Raw', 'raw.githubusercontent.com'),
  jsDelivr('jsDelivr CDN', 'cdn.jsdelivr.net');

  const UpdateSource(this.label, this.host);

  final String label;
  final String host;
}

class AppRelease {
  const AppRelease({
    required this.version,
    required this.title,
    required this.notes,
    required this.releaseUrl,
    required this.isPrerelease,
    this.apkUrl,
    this.publishedAt,
  });

  final String version;
  final String title;
  final String notes;
  final Uri releaseUrl;
  final bool isPrerelease;
  final Uri? apkUrl;
  final DateTime? publishedAt;
}

enum ReleaseAction { current, update, beta, rollback }

class UpdateService {
  UpdateService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  Future<List<AppRelease>> fetchReleases({
    bool includePrereleases = false,
    UpdateSource source = UpdateSource.githubApi,
  }) async {
    if (source == UpdateSource.githubApi) {
      return _fetchApiReleases(includePrereleases: includePrereleases);
    }
    return _fetchManifestReleases(
      includePrereleases: includePrereleases,
      source: source,
    );
  }

  static ReleaseAction classifyRelease(
    AppRelease release,
    String currentVersion,
  ) {
    final comparison = compareVersions(release.version, currentVersion);
    if (comparison == 0) return ReleaseAction.current;
    if (release.isPrerelease) return ReleaseAction.beta;
    return comparison > 0 ? ReleaseAction.update : ReleaseAction.rollback;
  }

  Future<List<AppRelease>> _fetchApiReleases({
    required bool includePrereleases,
  }) async {
    final uri = Uri.https(
      'api.github.com',
      '/repos/$_repositoryOwner/$_repositoryName/releases',
      {'per_page': '20'},
    );
    final response = await _client
        .get(
          uri,
          headers: const {
            'Accept': 'application/vnd.github+json',
            'X-GitHub-Api-Version': '2022-11-28',
            'User-Agent': 'PocketServerOps-AI',
          },
        )
        .timeout(const Duration(seconds: 10));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('GitHub 返回 HTTP ${response.statusCode}');
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! List) {
      throw const FormatException('GitHub Releases 格式无效');
    }

    final releases = <AppRelease>[];
    for (final item in decoded) {
      if (item is! Map ||
          item['draft'] == true ||
          (!includePrereleases && item['prerelease'] == true)) {
        continue;
      }
      final version = _normalizeVersion(item['tag_name']);
      final releaseUrl = _uriFrom(item['html_url']);
      if (version == null || releaseUrl == null) continue;

      Uri? apkUrl;
      final assets = item['assets'];
      if (assets is List) {
        for (final asset in assets) {
          if (asset is! Map) continue;
          final name = asset['name'];
          final url = _uriFrom(asset['browser_download_url']);
          if (name is String &&
              name.toLowerCase().endsWith('.apk') &&
              url != null) {
            apkUrl = url;
            break;
          }
        }
      }

      releases.add(
        AppRelease(
          version: version,
          title: item['name'] is String ? item['name'] as String : '',
          notes: item['body'] is String ? item['body'] as String : '',
          releaseUrl: releaseUrl,
          isPrerelease: item['prerelease'] == true,
          apkUrl: apkUrl,
          publishedAt: DateTime.tryParse(item['published_at'] as String? ?? ''),
        ),
      );
    }
    releases.sort((a, b) {
      final versionOrder = compareVersions(b.version, a.version);
      if (versionOrder != 0) return versionOrder;
      return (b.publishedAt ?? DateTime.fromMillisecondsSinceEpoch(0))
          .compareTo(a.publishedAt ?? DateTime.fromMillisecondsSinceEpoch(0));
    });
    return releases;
  }

  Future<List<AppRelease>> _fetchManifestReleases({
    required bool includePrereleases,
    required UpdateSource source,
  }) async {
    final response = await _client
        .get(
          _manifestUri(source),
          headers: const {
            'Accept': 'application/json',
            'User-Agent': 'PocketServerOps-AI',
          },
        )
        .timeout(const Duration(seconds: 10));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('${source.label} 返回 HTTP ${response.statusCode}');
    }

    final decoded = jsonDecode(response.body);
    final entries = decoded is Map && decoded['releases'] is List
        ? decoded['releases'] as List
        : decoded is Map
        ? [decoded]
        : const <Object?>[];
    if (entries.isEmpty) {
      throw const FormatException('更新清单为空或格式无效');
    }

    final releases = <AppRelease>[];
    for (final entry in entries) {
      if (entry is! Map ||
          (!includePrereleases && entry['prerelease'] == true)) {
        continue;
      }
      final release = _releaseFromManifest(entry);
      if (release != null) releases.add(release);
    }
    _sortReleases(releases);
    return releases;
  }

  AppRelease? _releaseFromManifest(Map<Object?, Object?> entry) {
    final version = _normalizeVersion(entry['version'] ?? entry['tag_name']);
    final releaseUrl = _uriFrom(entry['release_url'] ?? entry['html_url']);
    if (version == null || releaseUrl == null) return null;
    return AppRelease(
      version: version,
      title: _stringValue(entry['title'] ?? entry['name']),
      notes: _stringValue(entry['notes'] ?? entry['body']),
      releaseUrl: releaseUrl,
      isPrerelease: entry['prerelease'] == true,
      apkUrl: _uriFrom(entry['apk_url'] ?? entry['browser_download_url']),
      publishedAt: DateTime.tryParse(
        entry['published_at'] is String ? entry['published_at'] as String : '',
      ),
    );
  }

  static Uri _manifestUri(UpdateSource source) {
    switch (source) {
      case UpdateSource.githubApi:
        throw ArgumentError.value(source, 'source', 'API has no manifest URL');
      case UpdateSource.githubRaw:
        return Uri.https(
          'raw.githubusercontent.com',
          '/$_repositoryOwner/$_repositoryName/beta/updates/releases.json',
        );
      case UpdateSource.jsDelivr:
        return Uri.https(
          'cdn.jsdelivr.net',
          '/gh/$_repositoryOwner/$_repositoryName@beta/updates/releases.json',
        );
    }
  }

  static String _stringValue(Object? value) => value is String ? value : '';

  static void _sortReleases(List<AppRelease> releases) {
    releases.sort((a, b) {
      final versionOrder = compareVersions(b.version, a.version);
      if (versionOrder != 0) return versionOrder;
      return (b.publishedAt ?? DateTime.fromMillisecondsSinceEpoch(0))
          .compareTo(a.publishedAt ?? DateTime.fromMillisecondsSinceEpoch(0));
    });
  }

  static String apkFileName(String version) =>
      'pocket-server-ops-ai-v$version.apk';

  Future<File> downloadApk(
    AppRelease release,
    Directory destination, {
    UpdateDownloadProgress? onProgress,
  }) async {
    final uri = release.apkUrl;
    if (uri == null) {
      throw StateError('此版本没有可下载的 APK');
    }
    await destination.create(recursive: true);
    final target = File(
      path.join(destination.path, apkFileName(release.version)),
    );
    final partial = File('${target.path}.part');
    if (await partial.exists()) await partial.delete();

    final request = http.Request('GET', uri)
      ..headers.addAll(const {
        'Accept': 'application/vnd.android.package-archive',
        'User-Agent': 'PocketServerOps-AI',
      });
    final response = await _client
        .send(request)
        .timeout(const Duration(seconds: 20));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('APK 下载失败：HTTP ${response.statusCode}');
    }

    final sink = partial.openWrite();
    var received = 0;
    var closed = false;
    onProgress?.call(0, response.contentLength);
    try {
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 30),
      )) {
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, response.contentLength);
      }
      if (received == 0) throw StateError('APK 下载内容为空');
      await sink.flush();
      await sink.close();
      closed = true;
      if (await target.exists()) await target.delete();
      await partial.rename(target.path);
      return target;
    } catch (_) {
      if (!closed) await sink.close();
      if (await partial.exists()) await partial.delete();
      rethrow;
    }
  }

  void close() => _client.close();

  static int compareVersions(String left, String right) {
    final a = _parseVersion(left);
    final b = _parseVersion(right);
    for (var index = 0; index < 3; index++) {
      final result = a.base[index].compareTo(b.base[index]);
      if (result != 0) return result;
    }
    final aPrerelease = a.prerelease;
    final bPrerelease = b.prerelease;
    if (aPrerelease == bPrerelease) return 0;
    if (aPrerelease == null) return 1;
    if (bPrerelease == null) return -1;
    final aParts = aPrerelease.split('.');
    final bParts = bPrerelease.split('.');
    final length = aParts.length < bParts.length
        ? aParts.length
        : bParts.length;
    for (var index = 0; index < length; index++) {
      final leftPart = aParts[index];
      final rightPart = bParts[index];
      if (leftPart == rightPart) continue;
      final leftNumber = int.tryParse(leftPart);
      final rightNumber = int.tryParse(rightPart);
      if (leftNumber != null && rightNumber != null) {
        return leftNumber.compareTo(rightNumber);
      }
      if (leftNumber != null) return -1;
      if (rightNumber != null) return 1;
      return leftPart.compareTo(rightPart);
    }
    return aParts.length.compareTo(bParts.length);
  }

  static String? _normalizeVersion(Object? value) {
    if (value is! String) return null;
    final match = RegExp(r'^v?(\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)')
        .firstMatch(value.trim());
    return match?.group(1);
  }

  static _VersionParts _parseVersion(String value) {
    final normalized = _normalizeVersion(value) ?? '0.0.0';
    final separator = normalized.indexOf('-');
    final base = separator < 0
        ? normalized
        : normalized.substring(0, separator);
    final prerelease = separator < 0
        ? null
        : normalized.substring(separator + 1);
    return _VersionParts(
      base: base.split('.').map(int.parse).toList(growable: false),
      prerelease: prerelease,
    );
  }

  static Uri? _uriFrom(Object? value) {
    if (value is! String || value.isEmpty) return null;
    return Uri.tryParse(value);
  }
}

class _VersionParts {
  const _VersionParts({required this.base, required this.prerelease});

  final List<int> base;
  final String? prerelease;
}

class UpdatesPage extends StatefulWidget {
  const UpdatesPage({
    super.key,
    this.service,
    this.installer,
    this.includePrereleases = false,
  });

  final UpdateService? service;
  final AppUpdateInstaller? installer;
  final bool includePrereleases;

  @override
  State<UpdatesPage> createState() => _UpdatesPageState();
}

class _UpdatesPageState extends State<UpdatesPage> {
  late final UpdateService _service = widget.service ?? UpdateService();
  late final AppUpdateInstaller _installer =
      widget.installer ?? const AppUpdateInstaller();
  String _currentVersion = _fallbackVersion;
  List<AppRelease> _releases = const [];
  bool _loading = false;
  bool _checked = false;
  bool _downloading = false;
  bool _installing = false;
  bool _downloadOperationActive = false;
  String? _downloadVersion;
  File? _downloadedApk;
  int _downloadedBytes = 0;
  int? _downloadTotal;
  String? _error;
  UpdateSource _source = UpdateSource.githubApi;

  @override
  void initState() {
    super.initState();
    unawaited(_loadCurrentVersion());
  }

  @override
  void dispose() {
    if (widget.service == null) _service.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('版本与更新')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 32),
        children: [
          Card(
            child: ListTile(
              leading: const Icon(Icons.phone_android_outlined),
              title: const Text('当前版本'),
              subtitle: Text('v$_currentVersion'),
              trailing: _loading
                  ? const SizedBox.square(
                      dimension: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : null,
            ),
          ),
          const SizedBox(height: 12),
          Text('检查渠道', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: UpdateSource.values
                .map((source) {
                  return ChoiceChip(
                    label: Text(source.label),
                    selected: _source == source,
                    onSelected: _loading
                        ? null
                        : (selected) {
                            if (!selected) return;
                            setState(() {
                              _source = source;
                              _checked = false;
                              _error = null;
                              _releases = const [];
                            });
                          },
                  );
                })
                .toList(growable: false),
          ),
          const SizedBox(height: 4),
          Text(_source.host, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _loading ? null : _checkForUpdates,
            icon: const Icon(Icons.refresh),
            label: const Text('检查更新'),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          if (_checked && _error == null && _releases.isEmpty) ...[
            const SizedBox(height: 18),
            const Center(child: Text('暂无已发布版本')),
          ],
          if (_checked && _error == null && _releases.isNotEmpty) ...[
            const SizedBox(height: 24),
            Text('版本历史', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            ..._releases.map(_buildReleaseTile),
          ],
          const SizedBox(height: 16),
          Text(
            '检查渠道可切换 GitHub API、GitHub Raw 或 jsDelivr CDN。APK 默认在 APP 内下载并交给 Android 安装；也可从版本菜单打开浏览器或复制链接。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _buildReleaseTile(AppRelease release) {
    final action = UpdateService.classifyRelease(release, _currentVersion);
    final isCurrent = action == ReleaseAction.current;
    final isNewer = action == ReleaseAction.update;
    final isDownloading = _downloading && _downloadVersion == release.version;
    final isDownloaded =
        _downloadVersion == release.version && _downloadedApk != null;
    final actionLabel = switch (action) {
      ReleaseAction.current => '当前',
      ReleaseAction.update => '更新',
      ReleaseAction.beta => '安装测试版',
      ReleaseAction.rollback => '回退',
    };
    final date = release.publishedAt;
    final subtitle = [
      if (release.title.isNotEmpty) release.title,
      if (date != null) _formatDate(date),
      if (release.notes.trim().isNotEmpty) _trimNotes(release.notes),
    ].join('\n');

    return Card(
      child: Column(
        children: [
          ListTile(
            leading: Icon(
              isCurrent
                  ? Icons.check_circle_outline
                  : action == ReleaseAction.beta
                  ? Icons.science_outlined
                  : isNewer
                  ? Icons.system_update_outlined
                  : Icons.history,
            ),
            title: Text('v${release.version}'),
            subtitle: subtitle.isEmpty ? null : Text(subtitle),
            isThreeLine: subtitle.split('\n').length > 2,
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!isCurrent)
                  OutlinedButton.icon(
                    onPressed:
                        release.apkUrl == null || _downloading || _installing
                        ? null
                        : () => _downloadOrInstall(release, action: action),
                    icon: Icon(
                      isDownloaded
                          ? Icons.install_mobile_outlined
                          : Icons.download_outlined,
                    ),
                    label: Text(
                      isDownloading
                          ? _downloadPercentLabel()
                          : isDownloaded
                          ? '安装'
                          : actionLabel,
                    ),
                  ),
                PopupMenuButton<_ReleaseMenuAction>(
                  tooltip: '更多下载方式',
                  onSelected: (action) => _handleMenuAction(action, release),
                  itemBuilder: (context) => const [
                    PopupMenuItem(
                      value: _ReleaseMenuAction.browser,
                      child: ListTile(
                        leading: Icon(Icons.open_in_browser_outlined),
                        title: Text('浏览器打开'),
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                    PopupMenuItem(
                      value: _ReleaseMenuAction.copy,
                      child: ListTile(
                        leading: Icon(Icons.link_outlined),
                        title: Text('复制下载链接'),
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (isDownloading)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: LinearProgressIndicator(
                value: _downloadProgress,
                minHeight: 3,
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _loadCurrentVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (mounted && info.version.trim().isNotEmpty) {
        setState(() => _currentVersion = info.version);
      }
    } catch (_) {
      // The fallback keeps web previews and test environments usable.
    }
  }

  Future<void> _checkForUpdates() async {
    setState(() {
      _loading = true;
      _checked = false;
      _error = null;
    });
    try {
      final releases = await _service.fetchReleases(
        includePrereleases: widget.includePrereleases,
        source: _source,
      );
      if (!mounted) return;
      setState(() {
        _releases = releases;
        _checked = true;
        _loading = false;
      });
      final newest = releases.firstOrNull;
      if (newest != null &&
          UpdateService.compareVersions(newest.version, _currentVersion) > 0) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('发现新版本 v${newest.version}')));
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _checked = true;
        _error = '检查更新失败：$error';
      });
    }
  }

  double? get _downloadProgress {
    final total = _downloadTotal;
    if (total == null || total <= 0) return null;
    return (_downloadedBytes / total).clamp(0, 1).toDouble();
  }

  String _downloadPercentLabel() {
    final progress = _downloadProgress;
    return progress == null ? '下载中' : '${(progress * 100).round()}%';
  }

  Future<Directory> _downloadDirectory() async {
    final support = await getApplicationSupportDirectory();
    return Directory(path.join(support.path, 'updates'));
  }

  Future<void> _downloadOrInstall(
    AppRelease release, {
    required ReleaseAction action,
  }) async {
    if (_downloadOperationActive) return;
    _downloadOperationActive = true;
    try {
      await _downloadOrInstallOnce(release, action: action);
    } finally {
      _downloadOperationActive = false;
    }
  }

  Future<void> _downloadOrInstallOnce(
    AppRelease release, {
    required ReleaseAction action,
  }) async {
    if (_downloadVersion == release.version && _downloadedApk != null) {
      if (await _downloadedApk!.exists()) {
        if (!mounted) return;
        await _installApk(_downloadedApk!);
        return;
      }
    }
    if (!mounted) return;
    if (action == ReleaseAction.rollback) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('下载 v${release.version}？'),
          content: const Text(
            '这是低于当前版本的旧版。Android 通常不允许低版本直接覆盖当前版本，请确认下载后再按系统提示安装。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('继续'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    final uri = release.apkUrl;
    if (uri == null) {
      _showMessage('此版本没有可下载的 APK，请使用版本菜单查看 Release 页面');
      return;
    }

    final directory = await _downloadDirectory();
    if (!mounted) return;
    final cached = File(
      path.join(directory.path, UpdateService.apkFileName(release.version)),
    );
    if (await cached.exists() && await cached.length() > 0) {
      if (!mounted) return;
      setState(() {
        _downloadVersion = release.version;
        _downloadedApk = cached;
      });
      await _installApk(cached);
      return;
    }

    if (!mounted) return;
    setState(() {
      _downloading = true;
      _downloadVersion = release.version;
      _downloadedApk = null;
      _downloadedBytes = 0;
      _downloadTotal = null;
      _error = null;
    });
    try {
      final file = await _service.downloadApk(
        release,
        directory,
        onProgress: (received, total) {
          if (!mounted) return;
          setState(() {
            _downloadedBytes = received;
            _downloadTotal = total;
          });
        },
      );
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _downloadedApk = file;
      });
      await _installApk(file);
    } catch (error) {
      if (!mounted) return;
      setState(() => _downloading = false);
      _showMessage('下载更新失败：$error');
    }
  }

  Future<void> _installApk(File file) async {
    if (mounted) setState(() => _installing = true);
    try {
      await _installer.install(file);
      if (mounted) _showMessage('已打开系统安装器');
    } catch (error) {
      if (mounted) _showMessage('安装更新失败：$error');
    } finally {
      if (mounted) setState(() => _installing = false);
    }
  }

  Future<void> _handleMenuAction(
    _ReleaseMenuAction action,
    AppRelease release,
  ) async {
    final uri = release.apkUrl ?? release.releaseUrl;
    switch (action) {
      case _ReleaseMenuAction.browser:
        if (!await launchUrl(uri, mode: LaunchMode.externalApplication) &&
            mounted) {
          _showMessage('无法打开浏览器');
        }
      case _ReleaseMenuAction.copy:
        await Clipboard.setData(ClipboardData(text: uri.toString()));
        if (mounted) _showMessage('下载链接已复制');
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  String _formatDate(DateTime date) {
    final local = date.toLocal();
    return '${local.year}-${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')}';
  }

  String _trimNotes(String notes) {
    final singleLine = notes.trim().replaceAll(RegExp(r'\s+'), ' ');
    return singleLine.length > 80
        ? '${singleLine.substring(0, 80)}…'
        : singleLine;
  }
}

enum _ReleaseMenuAction { browser, copy }
