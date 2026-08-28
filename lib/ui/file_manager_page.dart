import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path_util;
import 'package:path_provider/path_provider.dart';

import '../app_controller.dart';
import '../domain/models.dart';
import '../platform/android_file_opener.dart';
import '../ssh/ssh_connection.dart';

enum _RemoteSortOption {
  nameAscending,
  nameDescending,
  modifiedNewest,
  modifiedOldest,
  sizeLargest,
  sizeSmallest,
}

class FileManagerPage extends StatefulWidget {
  const FileManagerPage({
    required this.controller,
    required this.server,
    this.initialPath,
    this.onCdToDirectory,
    super.key,
  });

  final AppController controller;
  final ServerProfile server;
  final String? initialPath;
  final ValueChanged<String>? onCdToDirectory;

  @override
  State<FileManagerPage> createState() => _FileManagerPageState();
}

class _FileManagerPageState extends State<FileManagerPage> {
  late final TextEditingController _path;
  List<SshDirectoryEntry> _entries = const [];
  bool _loading = false;
  bool _downloading = false;
  String? _downloadName;
  int _downloadedBytes = 0;
  int? _downloadTotalBytes;
  bool _uploading = false;
  String? _uploadName;
  int _uploadedBytes = 0;
  int? _uploadTotalBytes;
  String? _error;
  final Set<String> _selected = {};
  final List<String> _clipboard = [];
  bool _clipboardMoves = false;
  final Map<String, DateTime?> _modifiedTimes = {};
  _RemoteSortOption _sortOption = _RemoteSortOption.nameAscending;

  @override
  void initState() {
    super.initState();
    final configuredPath = widget.initialPath?.trim();
    _path = TextEditingController(
      text: configuredPath?.isNotEmpty == true
          ? configuredPath!
          : widget.server.defaultWorkingDirectory?.trim().isNotEmpty == true
          ? widget.server.defaultWorkingDirectory
          : '/',
    );
    unawaited(_initialize());
  }

  @override
  void dispose() {
    _path.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: _selected.isEmpty
            ? null
            : IconButton(
                tooltip: '退出选择',
                onPressed: _clearSelection,
                icon: const Icon(Icons.close),
              ),
        title: Text(
          _selected.isEmpty
              ? '${widget.server.name} · 文件'
              : '已选择 ${_selected.length} 项',
        ),
        actions: [
          if (_selected.isEmpty) ...[
            IconButton(
              tooltip: '上传文件',
              onPressed: _loading || _transferInProgress ? null : _upload,
              icon: const Icon(Icons.upload_file_outlined),
            ),
            IconButton(
              tooltip: '新建文件',
              onPressed: _loading || _transferInProgress ? null : _createFile,
              icon: const Icon(Icons.note_add_outlined),
            ),
            IconButton(
              tooltip: '新建文件夹',
              onPressed: _loading || _transferInProgress
                  ? null
                  : _createDirectory,
              icon: const Icon(Icons.create_new_folder_outlined),
            ),
            if (widget.onCdToDirectory != null)
              IconButton(
                tooltip: 'cd 到当前位置',
                onPressed: _loading || _transferInProgress
                    ? null
                    : _cdToCurrentDirectory,
                icon: const Icon(Icons.subdirectory_arrow_right),
              ),
            PopupMenuButton<_RemoteSortOption>(
              tooltip: '排序设置',
              initialValue: _sortOption,
              onSelected: _selectSortOption,
              itemBuilder: (context) => [
                const PopupMenuItem(
                  value: _RemoteSortOption.nameAscending,
                  child: Text('名称 A-Z'),
                ),
                const PopupMenuItem(
                  value: _RemoteSortOption.nameDescending,
                  child: Text('名称 Z-A'),
                ),
                const PopupMenuItem(
                  value: _RemoteSortOption.modifiedNewest,
                  child: Text('修改时间 新-旧'),
                ),
                const PopupMenuItem(
                  value: _RemoteSortOption.modifiedOldest,
                  child: Text('修改时间 旧-新'),
                ),
                const PopupMenuItem(
                  value: _RemoteSortOption.sizeLargest,
                  child: Text('大小 大-小'),
                ),
                const PopupMenuItem(
                  value: _RemoteSortOption.sizeSmallest,
                  child: Text('大小 小-大'),
                ),
              ],
            ),
            IconButton(
              tooltip: '刷新目录',
              onPressed: _loading || _transferInProgress ? null : _load,
              icon: _loading
                  ? const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh),
            ),
          ],
        ],
      ),
      bottomNavigationBar: _buildActionBar(),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            child: Row(
              children: [
                IconButton(
                  tooltip: '返回上级目录',
                  onPressed: _loading ? null : _goParent,
                  icon: const Icon(Icons.arrow_upward),
                ),
                Expanded(
                  child: TextField(
                    controller: _path,
                    enabled: !_loading,
                    textInputAction: TextInputAction.go,
                    onSubmitted: (_) => _load(),
                    decoration: const InputDecoration(
                      labelText: '远程目录',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '打开目录',
                  onPressed: _loading ? null : _load,
                  icon: const Icon(Icons.arrow_forward),
                ),
              ],
            ),
          ),
          if (widget.onCdToDirectory != null)
            Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.only(right: 12, bottom: 4),
                child: TextButton.icon(
                  onPressed: _loading ? null : _cdToCurrentDirectory,
                  icon: const Icon(Icons.terminal_outlined, size: 18),
                  label: const Text('cd 到当前位置'),
                ),
              ),
            ),
          if (_error != null)
            Container(
              width: double.infinity,
              color: Theme.of(context).colorScheme.errorContainer,
              padding: const EdgeInsets.all(12),
              child: Text(_error!),
            ),
          if (_transferInProgress)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${_uploading ? '上传' : '下载'} ${_transferName ?? ''}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(_transferProgressLabel),
                    ],
                  ),
                  const SizedBox(height: 4),
                  LinearProgressIndicator(value: _transferProgress),
                ],
              ),
            ),
          Expanded(
            child: _loading && _entries.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : _entries.isEmpty
                ? const Center(child: Text('目录为空'))
                : ListView.separated(
                    itemCount: _entries.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final entry = _entries[index];
                      return ListTile(
                        selected: _selected.contains(entry.path),
                        leading: _selected.isNotEmpty
                            ? Checkbox(
                                value: _selected.contains(entry.path),
                                onChanged: (_) => _toggleSelection(entry.path),
                              )
                            : Icon(
                                entry.isDirectory
                                    ? Icons.folder_outlined
                                    : Icons.description_outlined,
                              ),
                        title: Text(
                          entry.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: entry.isDirectory
                            ? const Text('目录')
                            : Text(_formatSize(entry.size)),
                        trailing: _selected.isNotEmpty
                            ? null
                            : entry.isDirectory
                            ? const Icon(Icons.chevron_right)
                            : Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    tooltip: '下载到手机项目',
                                    onPressed: _transferInProgress
                                        ? null
                                        : () => _download(entry),
                                    icon: const Icon(Icons.download_outlined),
                                  ),
                                  const Icon(Icons.chevron_right),
                                ],
                              ),
                        onTap: () => _selected.isEmpty
                            ? _open(entry)
                            : _toggleSelection(entry.path),
                        onLongPress: () =>
                            _toggleSelection(entry.path, select: true),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Future<void> _initialize() async {
    final saved = await _readFileManagerSortPreference(_sortPreferenceKey);
    if (!mounted) return;
    if (saved != null) {
      setState(() => _sortOption = _remoteSortOptionFromStorage(saved));
    }
    final cached = widget.controller.cachedServerDirectory(
      widget.server,
      _path.text,
    );
    if (cached == null) {
      await _load();
      return;
    }
    final sorted = await _sortEntries(cached);
    if (!mounted) return;
    setState(() {
      _entries = sorted;
      _loading = true;
      _error = null;
    });
    await _refresh(_path.text);
  }

  String get _sortPreferenceKey => 'server:${widget.server.id}';

  Future<void> _load({bool forceRefresh = false}) async {
    final path = _path.text.trim();
    if (path.isEmpty) return;
    final cached = widget.controller.cachedServerDirectory(widget.server, path);
    if (!forceRefresh && cached != null) {
      final sorted = await _sortEntries(cached);
      if (mounted) {
        setState(() {
          _entries = sorted;
          _loading = true;
          _error = null;
        });
      }
      await _refresh(path);
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    await _refresh(path);
  }

  Future<void> _refresh(String path) async {
    try {
      final entries = await widget.controller.listServerDirectory(
        widget.server,
        path,
        onFirstHostKey: _confirmHostKey,
        forceRefresh: true,
      );
      _modifiedTimes.clear();
      final sorted = await _sortEntries(entries);
      if (mounted && _path.text.trim() == path) {
        setState(() => _entries = sorted);
      }
    } catch (error) {
      if (mounted && _path.text.trim() == path) {
        setState(
          () => _error = _entries.isEmpty
              ? '读取目录失败：$error'
              : '刷新失败，继续显示缓存：$error',
        );
      }
    } finally {
      if (mounted && _path.text.trim() == path) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _selectSortOption(_RemoteSortOption option) async {
    if (option == _sortOption) return;
    setState(() {
      _sortOption = option;
      _loading = true;
      _error = null;
    });
    unawaited(_writeFileManagerSortPreference(_sortPreferenceKey, option.name));
    try {
      final sorted = await _sortEntries(_entries);
      if (mounted) setState(() => _entries = sorted);
    } catch (error) {
      if (mounted) setState(() => _error = '排序失败：$error');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<List<SshDirectoryEntry>> _sortEntries(
    Iterable<SshDirectoryEntry> source,
  ) async {
    if (_sortOption == _RemoteSortOption.modifiedNewest ||
        _sortOption == _RemoteSortOption.modifiedOldest) {
      await _loadModifiedTimes(source);
    }
    final entries = List<SshDirectoryEntry>.of(source);
    entries.sort(_compareEntries);
    return entries;
  }

  Future<void> _loadModifiedTimes(Iterable<SshDirectoryEntry> source) async {
    final missing = source
        .where((entry) => !_modifiedTimes.containsKey(entry.path))
        .toList(growable: false);
    if (missing.isEmpty) return;
    final command =
        'for p in ${missing.map((entry) => _shellQuote(entry.path)).join(' ')}; '
        'do stat -c %Y -- "\$p" 2>/dev/null || printf \'0\\n\'; done';
    final result = await widget.controller.runServerCommand(
      widget.server,
      command,
      onFirstHostKey: _confirmHostKey,
    );
    if (result.exitCode != 0) return;
    final lines = result.stdout.trim().split(RegExp(r'\s+'));
    for (
      var index = 0;
      index < missing.length && index < lines.length;
      index++
    ) {
      final seconds = int.tryParse(lines[index]);
      _modifiedTimes[missing[index].path] = seconds == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
    }
  }

  int _compareEntries(SshDirectoryEntry left, SshDirectoryEntry right) {
    if (left.isDirectory != right.isDirectory) {
      return left.isDirectory ? -1 : 1;
    }
    int comparison;
    switch (_sortOption) {
      case _RemoteSortOption.nameAscending:
      case _RemoteSortOption.nameDescending:
        comparison = left.name.compareTo(right.name);
      case _RemoteSortOption.modifiedNewest:
      case _RemoteSortOption.modifiedOldest:
        comparison = _compareNullable(
          _modifiedTimes[left.path],
          _modifiedTimes[right.path],
        );
      case _RemoteSortOption.sizeLargest:
      case _RemoteSortOption.sizeSmallest:
        comparison = _compareNullable(left.size, right.size);
    }
    if (comparison != 0 && _isDescending) return -comparison;
    if (comparison != 0) return comparison;
    return left.name.compareTo(right.name);
  }

  bool get _isDescending =>
      _sortOption == _RemoteSortOption.nameDescending ||
      _sortOption == _RemoteSortOption.modifiedNewest ||
      _sortOption == _RemoteSortOption.sizeLargest;

  int _compareNullable<T extends Comparable<Object>>(T? left, T? right) {
    if (left == null) return right == null ? 0 : 1;
    if (right == null) return -1;
    return left.compareTo(right);
  }

  void _toggleSelection(String entryPath, {bool select = false}) {
    setState(() {
      if (select || !_selected.contains(entryPath)) {
        _selected.add(entryPath);
      } else {
        _selected.remove(entryPath);
      }
    });
  }

  void _clearSelection() {
    if (_selected.isEmpty) return;
    setState(_selected.clear);
  }

  Widget? _buildActionBar() {
    if (_selected.isEmpty && _clipboard.isEmpty) return null;
    final selectedEntry = _selectedEntry;
    return BottomAppBar(
      padding: EdgeInsets.zero,
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 68,
          child: Row(
            children: [
              _actionButton(
                icon: Icons.copy_outlined,
                label: '复制',
                onPressed: _selected.isEmpty || _loading || _transferInProgress
                    ? null
                    : () => _copySelection(move: false),
              ),
              _actionButton(
                icon: Icons.content_paste_outlined,
                label: '粘贴',
                onPressed: _clipboard.isEmpty || _loading || _transferInProgress
                    ? null
                    : _paste,
              ),
              _actionButton(
                icon: Icons.drive_file_move_outlined,
                label: '移动',
                onPressed: _selected.isEmpty || _loading || _transferInProgress
                    ? null
                    : () => _copySelection(move: true),
              ),
              _actionButton(
                icon: Icons.info_outline,
                label: '属性',
                onPressed: _selected.isEmpty || _loading || _transferInProgress
                    ? null
                    : _showInfo,
              ),
              _actionButton(
                icon: Icons.drive_file_rename_outline,
                label: '重命名',
                onPressed:
                    _selected.length != 1 || _loading || _transferInProgress
                    ? null
                    : _renameSelected,
              ),
              _actionButton(
                icon: Icons.open_in_new,
                label: '打开',
                onPressed:
                    selectedEntry == null ||
                        selectedEntry.isDirectory ||
                        _loading ||
                        _transferInProgress
                    ? null
                    : _openSelected,
              ),
              _actionButton(
                icon: Icons.delete_outline,
                label: '删除',
                onPressed: _selected.isEmpty || _loading || _transferInProgress
                    ? null
                    : _deleteSelected,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _actionButton({
    required IconData icon,
    required String label,
    required VoidCallback? onPressed,
  }) {
    final color = onPressed == null
        ? Theme.of(context).disabledColor
        : Theme.of(context).colorScheme.primary;
    return Expanded(
      child: InkWell(
        onTap: onPressed,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 21, color: color),
            const SizedBox(height: 3),
            Text(label, style: TextStyle(fontSize: 11, color: color)),
          ],
        ),
      ),
    );
  }

  SshDirectoryEntry? get _selectedEntry {
    if (_selected.length != 1) return null;
    final path = _selected.single;
    for (final entry in _entries) {
      if (entry.path == path) return entry;
    }
    return null;
  }

  void _copySelection({required bool move}) {
    setState(() {
      _clipboard
        ..clear()
        ..addAll(_selected);
      _clipboardMoves = move;
      _selected.clear();
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(move ? '已准备移动，进入目标文件夹后粘贴' : '已复制，进入目标文件夹后粘贴')),
    );
  }

  Future<void> _paste() async {
    if (_clipboard.isEmpty) return;
    final destination = _normalizeRemotePath(_path.text);
    final paths = List<String>.from(_clipboard);
    final move = _clipboardMoves;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (move) {
        await widget.controller.moveServerFiles(
          widget.server,
          paths,
          destination,
          onFirstHostKey: _confirmHostKey,
        );
      } else {
        await widget.controller.copyServerFiles(
          widget.server,
          paths,
          destination,
          onFirstHostKey: _confirmHostKey,
        );
      }
      if (move) _clipboard.clear();
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(move ? '移动完成' : '粘贴完成')));
        await _load(forceRefresh: true);
      }
    } catch (error) {
      if (mounted) setState(() => _error = '粘贴失败：$error');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _renameSelected() async {
    final entry = _selectedEntry;
    if (entry == null) return;
    final name = await _askName(
      '重命名',
      '名称',
      initialValue: entry.name,
      confirmLabel: '保存',
    );
    if (name == null || name.trim().isEmpty) return;
    try {
      await widget.controller.renameServerFile(
        widget.server,
        entry.path,
        name,
        onFirstHostKey: _confirmHostKey,
      );
      _clearSelection();
      if (mounted) await _load(forceRefresh: true);
    } catch (error) {
      if (mounted) setState(() => _error = '重命名失败：$error');
    }
  }

  Future<void> _showInfo() async {
    final selected = List<String>.from(_selected);
    if (selected.length != 1) {
      await showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('属性'),
          content: Text('已选择 ${selected.length} 项'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('确定'),
            ),
          ],
        ),
      );
      return;
    }
    try {
      final info = await widget.controller.statServerFile(
        widget.server,
        selected.single,
        onFirstHostKey: _confirmHostKey,
      );
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          title: Text(info.name),
          content: Text(
            '位置：${info.path}\n'
            '类型：${info.isSymbolicLink
                ? '符号链接'
                : info.isDirectory
                ? '文件夹'
                : '文件'}\n'
            '大小：${_formatSize(info.size)}\n'
            '修改时间：${_formatRemoteDate(info.modified)}',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('确定'),
            ),
          ],
        ),
      );
    } catch (error) {
      if (mounted) setState(() => _error = '读取属性失败：$error');
    }
  }

  Future<void> _openSelected() async {
    final entry = _selectedEntry;
    if (entry == null || entry.isDirectory) return;
    _clearSelection();
    await _download(entry, openAfterDownload: true);
  }

  Future<void> _deleteSelected() async {
    final paths = List<String>.from(_selected);
    if (paths.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除文件'),
        content: Text('确定删除已选择的 ${paths.length} 项？文件夹及其内容也会删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await widget.controller.deleteServerFiles(
        widget.server,
        paths,
        onFirstHostKey: _confirmHostKey,
      );
      if (mounted) {
        setState(_selected.clear);
        await _load(forceRefresh: true);
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('删除完成')));
        }
      }
    } catch (error) {
      if (mounted) setState(() => _error = '删除失败：$error');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _open(SshDirectoryEntry entry) async {
    if (entry.isDirectory) {
      _path.text = entry.path;
      await _load();
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => RemoteFileEditorPage(
          controller: widget.controller,
          server: widget.server,
          path: entry.path,
          name: entry.name,
        ),
      ),
    );
    if (mounted) unawaited(_load(forceRefresh: true));
  }

  double? get _downloadProgress {
    final total = _downloadTotalBytes;
    if (total == null || total <= 0) return null;
    return (_downloadedBytes / total).clamp(0, 1).toDouble();
  }

  bool get _transferInProgress => _downloading || _uploading;

  String? get _transferName => _uploading ? _uploadName : _downloadName;

  double? get _transferProgress {
    if (_uploading) {
      final total = _uploadTotalBytes;
      if (total == null || total <= 0) return null;
      return (_uploadedBytes / total).clamp(0, 1).toDouble();
    }
    return _downloadProgress;
  }

  String get _transferProgressLabel {
    final progress = _transferProgress;
    if (progress == null) return _uploading ? '上传中' : '下载中';
    return '${(progress * 100).round()}%';
  }

  Future<void> _download(
    SshDirectoryEntry entry, {
    bool openAfterDownload = false,
  }) async {
    final projects = widget.controller.projects;
    if (projects.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请先创建手机项目，再下载服务器文件')));
      return;
    }
    final project = projects.length == 1
        ? projects.single
        : await _chooseProject(projects);
    if (!mounted || project == null) return;
    final projectPath = await _askProjectPath(entry.name);
    if (!mounted || projectPath == null || projectPath.trim().isEmpty) return;

    setState(() {
      _downloading = true;
      _downloadName = entry.name;
      _downloadedBytes = 0;
      _downloadTotalBytes = entry.size;
      _error = null;
    });
    try {
      final downloaded = await widget.controller.downloadServerFileToProject(
        widget.server,
        project,
        entry.path,
        projectPath,
        onFirstHostKey: _confirmHostKey,
        onProgress: (received, total) {
          if (!mounted) return;
          setState(() {
            _downloadedBytes = received;
            _downloadTotalBytes = total;
          });
        },
      );
      if (openAfterDownload) await AndroidFileOpener.open(downloaded.path);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              openAfterDownload
                  ? '已下载并打开 ${project.name}/$projectPath'
                  : '已下载到 ${project.name}/$projectPath',
            ),
          ),
        );
      }
    } catch (error) {
      if (mounted) {
        setState(() => _error = '下载失败，已保留临时文件，重试将继续：$error');
      }
    } finally {
      if (mounted) {
        setState(() {
          _downloading = false;
          _downloadName = null;
        });
      }
    }
  }

  Future<void> _upload() async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: false,
      withData: false,
      withReadStream: false,
      type: FileType.any,
    );
    if (result == null || !mounted) return;
    final picked = result.files.single;
    final sourcePath = picked.path;
    if (sourcePath == null || sourcePath.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('无法读取手机文件：${picked.name}')));
      return;
    }
    final remotePath = await _askRemotePath(picked.name);
    if (!mounted || remotePath == null || remotePath.trim().isEmpty) return;

    setState(() {
      _uploading = true;
      _uploadName = picked.name;
      _uploadedBytes = 0;
      _uploadTotalBytes = picked.size;
      _error = null;
    });
    try {
      final uploaded = await widget.controller.uploadFileToServer(
        widget.server,
        File(sourcePath),
        remotePath,
        onFirstHostKey: _confirmHostKey,
        onProgress: (sent, total) {
          if (!mounted) return;
          setState(() {
            _uploadedBytes = sent;
            _uploadTotalBytes = total;
          });
        },
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已上传 ${_formatSize(uploaded)} 到 $remotePath')),
        );
        unawaited(_load(forceRefresh: true));
      }
    } catch (error) {
      if (mounted) {
        setState(() => _error = '上传失败，服务器临时文件已保留，重试将继续：$error');
      }
    } finally {
      if (mounted) {
        setState(() {
          _uploading = false;
          _uploadName = null;
        });
      }
    }
  }

  Future<String?> _askRemotePath(String name) {
    final directory = _path.text.trim();
    final initial = path_util.posix.join(
      directory.isEmpty ? '/' : directory,
      name,
    );
    final controller = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('上传到服务器'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '远程文件路径',
            hintText: '/var/www/app/file.bin',
          ),
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('上传'),
          ),
        ],
      ),
    ).whenComplete(controller.dispose);
  }

  Future<Project?> _chooseProject(List<Project> projects) {
    return showDialog<Project>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('选择手机项目'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 320),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final project in projects)
                  ListTile(
                    title: Text(project.name),
                    subtitle: Text(
                      project.localPath,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () => Navigator.pop(context, project),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
        ],
      ),
    );
  }

  Future<String?> _askProjectPath(String name) {
    final controller = TextEditingController(text: name);
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('保存到项目'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '项目内相对路径',
            hintText: '例如 assets/data.bin',
          ),
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('下载'),
          ),
        ],
      ),
    ).whenComplete(controller.dispose);
  }

  void _goParent() {
    final path = _path.text.trim();
    if (path.isEmpty || path == '/') return;
    final clean = path.endsWith('/')
        ? path.substring(0, path.length - 1)
        : path;
    final separator = clean.lastIndexOf('/');
    _path.text = separator <= 0 ? '/' : clean.substring(0, separator);
    _load();
  }

  Future<void> _createFile() async {
    final name = await showDialog<String>(
      context: context,
      builder: (context) {
        final controller = TextEditingController();
        return AlertDialog(
          title: const Text('新建文件'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(labelText: '文件名'),
            onSubmitted: (value) => Navigator.pop(context, value),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, controller.text),
              child: const Text('创建'),
            ),
          ],
        );
      },
    );
    if (name == null || name.trim().isEmpty || name.contains('/')) return;
    final directory = _path.text.trim();
    final path = directory == '/'
        ? '/${name.trim()}'
        : '$directory/${name.trim()}';
    try {
      await widget.controller.writeServerFile(
        widget.server,
        path,
        '',
        onFirstHostKey: _confirmHostKey,
      );
      await _load(forceRefresh: true);
    } catch (error) {
      if (mounted) {
        setState(() => _error = '新建文件失败：$error');
      }
    }
  }

  Future<void> _createDirectory() async {
    final name = await _askName('新建文件夹', '文件夹名称');
    if (name == null || name.trim().isEmpty) return;
    if (name.contains('/') || name.contains('\\')) {
      setState(() => _error = '文件夹名称不能包含路径分隔符');
      return;
    }
    final directory = _normalizeRemotePath(_path.text);
    final path = path_util.posix.join(directory, name.trim());
    try {
      await widget.controller.createServerDirectory(
        widget.server,
        path,
        onFirstHostKey: _confirmHostKey,
      );
      await _load(forceRefresh: true);
    } catch (error) {
      if (mounted) setState(() => _error = '新建文件夹失败：$error');
    }
  }

  Future<String?> _askName(
    String title,
    String label, {
    String? initialValue,
    String confirmLabel = '创建',
  }) {
    final controller = TextEditingController(text: initialValue);
    if (initialValue != null) {
      controller.selection = TextSelection.collapsed(
        offset: initialValue.length,
      );
    }
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(labelText: label),
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: Text(confirmLabel),
          ),
        ],
      ),
    ).whenComplete(controller.dispose);
  }

  void _cdToCurrentDirectory() {
    final path = _path.text.trim();
    if (path.isEmpty) return;
    widget.onCdToDirectory?.call(path);
  }

  Future<bool> _confirmHostKey(SshHostKey key) async {
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('确认主机指纹'),
            content: SelectableText('${key.type}\n${key.fingerprint}'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('拒绝'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('信任并保存'),
              ),
            ],
          ),
        ) ??
        false;
  }
}

class RemoteFileEditorPage extends StatefulWidget {
  const RemoteFileEditorPage({
    required this.controller,
    required this.server,
    required this.path,
    required this.name,
    super.key,
  });

  final AppController controller;
  final ServerProfile server;
  final String path;
  final String name;

  @override
  State<RemoteFileEditorPage> createState() => _RemoteFileEditorPageState();
}

class _RemoteFileEditorPageState extends State<RemoteFileEditorPage> {
  late final TextEditingController _content;
  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _content = TextEditingController();
    unawaited(_load());
  }

  @override
  void dispose() {
    _content.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: '保存文件',
            onPressed: _loading || _saving ? null : _save,
            icon: _saving
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save_outlined),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                if (_error != null)
                  Container(
                    width: double.infinity,
                    color: Theme.of(context).colorScheme.errorContainer,
                    padding: const EdgeInsets.all(12),
                    child: Text(_error!),
                  ),
                Expanded(
                  child: TextField(
                    controller: _content,
                    minLines: 20,
                    maxLines: null,
                    expands: false,
                    textAlignVertical: TextAlignVertical.top,
                    decoration: const InputDecoration(
                      hintText: '文件内容',
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.all(12),
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  Future<void> _load() async {
    try {
      final value = await widget.controller.readServerFile(
        widget.server,
        widget.path,
        onFirstHostKey: _confirmHostKey,
      );
      if (mounted) {
        _content.text = value;
        setState(() => _loading = false);
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '读取文件失败：$error';
        });
      }
    }
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.controller.writeServerFile(
        widget.server,
        widget.path,
        _content.text,
        onFirstHostKey: _confirmHostKey,
      );
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('文件已保存')));
      }
    } catch (error) {
      if (mounted) setState(() => _error = '保存文件失败：$error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<bool> _confirmHostKey(SshHostKey key) async {
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('确认主机指纹'),
            content: SelectableText('${key.type}\n${key.fingerprint}'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('拒绝'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('信任并保存'),
              ),
            ],
          ),
        ) ??
        false;
  }
}

String _formatSize(int? size) {
  if (size == null) return '未知大小';
  if (size < 1024) return '$size B';
  if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(1)} KiB';
  return '${(size / (1024 * 1024)).toStringAsFixed(1)} MiB';
}

String _normalizeRemotePath(String value) {
  final path = value.trim().replaceAll('\\', '/');
  if (path.isEmpty) return '/';
  return path_util.posix.normalize(path);
}

String _formatRemoteDate(DateTime? value) {
  if (value == null) return '未知';
  return value.toLocal().toString().split('.').first;
}

_RemoteSortOption _remoteSortOptionFromStorage(String value) {
  for (final option in _RemoteSortOption.values) {
    if (option.name == value) return option;
  }
  return _RemoteSortOption.nameAscending;
}

String _shellQuote(String value) => "'${value.replaceAll("'", "'\"'\"'")}'";

Future<String?> _readFileManagerSortPreference(String key) async {
  try {
    final directory = await getApplicationSupportDirectory();
    final file = File(
      path_util.join(
        directory.path,
        'file-manager-sort-${Uri.encodeComponent(key)}',
      ),
    );
    if (!await file.exists()) return null;
    return (await file.readAsString()).trim();
  } catch (_) {
    return null;
  }
}

Future<void> _writeFileManagerSortPreference(String key, String value) async {
  try {
    final directory = await getApplicationSupportDirectory();
    await directory.create(recursive: true);
    await File(
      path_util.join(
        directory.path,
        'file-manager-sort-${Uri.encodeComponent(key)}',
      ),
    ).writeAsString(value, flush: true);
  } catch (_) {}
}
