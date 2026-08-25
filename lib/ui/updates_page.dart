import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

const _repositoryOwner = '2296199707';
const _repositoryName = 'pocket-server-ops-ai';
const _fallbackVersion = '1.0.2';

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

class UpdateService {
  UpdateService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  Future<List<AppRelease>> fetchReleases({
    bool includePrereleases = false,
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

  void close() => _client.close();

  static int compareVersions(String left, String right) {
    final a = _versionParts(left);
    final b = _versionParts(right);
    for (var index = 0; index < 3; index++) {
      final result = a[index].compareTo(b[index]);
      if (result != 0) return result;
    }
    return 0;
  }

  static String? _normalizeVersion(Object? value) {
    if (value is! String) return null;
    final match = RegExp(r'^v?(\d+\.\d+\.\d+)').firstMatch(value.trim());
    return match?.group(1);
  }

  static List<int> _versionParts(String value) {
    final normalized = _normalizeVersion(value);
    if (normalized == null) return [0, 0, 0];
    return normalized.split('.').map(int.parse).toList();
  }

  static Uri? _uriFrom(Object? value) {
    if (value is! String || value.isEmpty) return null;
    return Uri.tryParse(value);
  }
}

class UpdatesPage extends StatefulWidget {
  const UpdatesPage({super.key, this.service, this.includePrereleases = false});

  final UpdateService? service;
  final bool includePrereleases;

  @override
  State<UpdatesPage> createState() => _UpdatesPageState();
}

class _UpdatesPageState extends State<UpdatesPage> {
  late final UpdateService _service = widget.service ?? UpdateService();
  String _currentVersion = _fallbackVersion;
  List<AppRelease> _releases = const [];
  bool _loading = false;
  bool _checked = false;
  String? _error;

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
            '更新来源：GitHub Releases。旧版本下载后，Android 可能要求先处理当前版本后才能回退安装。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _buildReleaseTile(AppRelease release) {
    final comparison = UpdateService.compareVersions(
      release.version,
      _currentVersion,
    );
    final isCurrent = comparison == 0;
    final isNewer = comparison > 0;
    final actionLabel = isCurrent
        ? '当前'
        : isNewer
        ? '更新'
        : '回退';
    final date = release.publishedAt;
    final subtitle = [
      if (release.title.isNotEmpty) release.title,
      if (date != null) _formatDate(date),
      if (release.notes.trim().isNotEmpty) _trimNotes(release.notes),
    ].join('\n');

    return Card(
      child: ListTile(
        leading: Icon(
          isCurrent
              ? Icons.check_circle_outline
              : isNewer
              ? Icons.system_update_outlined
              : Icons.history,
        ),
        title: Text('v${release.version}'),
        subtitle: subtitle.isEmpty ? null : Text(subtitle),
        isThreeLine: subtitle.split('\n').length > 2,
        trailing: isCurrent
            ? null
            : OutlinedButton(
                onPressed: () => _openRelease(release, isNewer: isNewer),
                child: Text(actionLabel),
              ),
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

  Future<void> _openRelease(AppRelease release, {required bool isNewer}) async {
    if (!isNewer) {
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
    final uri = release.apkUrl ?? release.releaseUrl;
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication) &&
        mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('无法打开下载页面')));
    }
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
