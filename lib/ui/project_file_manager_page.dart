import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as path_util;
import 'package:path_provider/path_provider.dart';

import '../app_controller.dart';
import '../domain/models.dart';
import '../local/document_export.dart';
import '../local/project_files.dart';
import '../platform/android_file_opener.dart';
import 'document_preview_page.dart';
import 'local_preview_page.dart';

enum _ProjectSortOption {
  nameAscending,
  nameDescending,
  modifiedNewest,
  modifiedOldest,
  sizeLargest,
  sizeSmallest,
}

class ProjectFileManagerPage extends StatefulWidget {
  const ProjectFileManagerPage({
    required this.controller,
    required this.project,
    this.initialPath,
    super.key,
  });

  final AppController controller;
  final Project project;
  final String? initialPath;

  @override
  State<ProjectFileManagerPage> createState() => _ProjectFileManagerPageState();
}

class _ProjectFileManagerPageState extends State<ProjectFileManagerPage> {
  late final TextEditingController _path;
  final _manualFiles = const ManualFileStore();
  final Map<String, String> _textCache = {};
  final Map<String, List<ProjectFileEntry>> _directoryCache = {};
  final Set<String> _selected = {};
  final List<String> _clipboard = [];
  List<ProjectFileEntry> _entries = const [];
  bool _loading = false;
  bool _clipboardMoves = false;
  String? _error;
  final Map<String, DateTime?> _modifiedTimes = {};
  _ProjectSortOption _sortOption = _ProjectSortOption.nameAscending;

  @override
  void initState() {
    super.initState();
    final initial = _normalizeAbsolutePath(
      widget.initialPath ?? widget.project.localPath,
    );
    _path = TextEditingController(text: initial);
    unawaited(_initialize());
  }

  @override
  void dispose() {
    _path.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final currentPath = _normalizeAbsolutePath(_path.text);
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
              ? '${widget.project.name} · 文件'
              : '已选择 ${_selected.length} 项',
        ),
        actions: [
          if (_selected.isEmpty) ...[
            IconButton(
              tooltip: '本地网页预览',
              onPressed: _openPreview,
              icon: const Icon(Icons.preview_outlined),
            ),
            IconButton(
              tooltip: '新建文件',
              onPressed: _loading ? null : _createFile,
              icon: const Icon(Icons.note_add_outlined),
            ),
            IconButton(
              tooltip: '新建文件夹',
              onPressed: _loading ? null : _createDirectory,
              icon: const Icon(Icons.create_new_folder_outlined),
            ),
            PopupMenuButton<_ProjectSortOption>(
              tooltip: '排序设置',
              initialValue: _sortOption,
              onSelected: _selectSortOption,
              itemBuilder: (context) => [
                const PopupMenuItem(
                  value: _ProjectSortOption.nameAscending,
                  child: Text('名称 A-Z'),
                ),
                const PopupMenuItem(
                  value: _ProjectSortOption.nameDescending,
                  child: Text('名称 Z-A'),
                ),
                const PopupMenuItem(
                  value: _ProjectSortOption.modifiedNewest,
                  child: Text('修改时间 新-旧'),
                ),
                const PopupMenuItem(
                  value: _ProjectSortOption.modifiedOldest,
                  child: Text('修改时间 旧-新'),
                ),
                const PopupMenuItem(
                  value: _ProjectSortOption.sizeLargest,
                  child: Text('大小 大-小'),
                ),
                const PopupMenuItem(
                  value: _ProjectSortOption.sizeSmallest,
                  child: Text('大小 小-大'),
                ),
              ],
            ),
            IconButton(
              tooltip: '刷新目录',
              onPressed: _loading ? null : () => _load(forceRefresh: true),
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
                  onPressed: _loading || currentPath == '/' ? null : _goParent,
                  icon: const Icon(Icons.arrow_upward),
                ),
                Expanded(
                  child: TextField(
                    controller: _path,
                    enabled: !_loading,
                    textInputAction: TextInputAction.go,
                    onSubmitted: (_) => _load(),
                    decoration: const InputDecoration(
                      labelText: '手机路径',
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
          if (_error != null)
            Container(
              width: double.infinity,
              color: Theme.of(context).colorScheme.errorContainer,
              padding: const EdgeInsets.all(12),
              child: Text(_error!),
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
                            ? const Text('文件夹')
                            : Text(_formatSize(entry.size)),
                        trailing: _selected.isEmpty
                            ? const Icon(Icons.chevron_right)
                            : null,
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
      setState(() => _sortOption = _projectSortOptionFromStorage(saved));
    }
    await _load();
  }

  String get _sortPreferenceKey => 'project:${widget.project.id}';

  Future<void> _load({bool forceRefresh = false}) async {
    final path = _normalizeAbsolutePath(_path.text);
    final cached = _directoryCache[path];
    if (!forceRefresh && cached != null) {
      final sorted = await _sortEntries(cached);
      if (mounted) {
        setState(() {
          _entries = sorted;
          _error = null;
          _loading = true;
        });
      }
      await _refresh(path);
      return;
    }
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    await _refresh(path, forceRefresh: forceRefresh);
  }

  Future<void> _refresh(String path, {bool forceRefresh = true}) async {
    try {
      final entries = await _manualFiles.list(path);
      final sorted = await _sortEntries(entries);
      _directoryCache[path] = List<ProjectFileEntry>.unmodifiable(sorted);
      if (mounted && _normalizeAbsolutePath(_path.text) == path) {
        setState(() => _entries = sorted);
      }
    } catch (error) {
      if (mounted && _normalizeAbsolutePath(_path.text) == path) {
        setState(
          () => _error = _entries.isEmpty
              ? '读取目录失败：$error'
              : '刷新失败，继续显示缓存：$error',
        );
      }
    } finally {
      if (mounted && _normalizeAbsolutePath(_path.text) == path) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _selectSortOption(_ProjectSortOption option) async {
    if (option == _sortOption) return;
    setState(() {
      _sortOption = option;
      _loading = true;
      _error = null;
    });
    unawaited(_writeFileManagerSortPreference(_sortPreferenceKey, option.name));
    try {
      final sorted = await _sortEntries(_entries);
      final path = _normalizeAbsolutePath(_path.text);
      _directoryCache[path] = List<ProjectFileEntry>.unmodifiable(sorted);
      if (mounted) setState(() => _entries = sorted);
    } catch (error) {
      if (mounted) setState(() => _error = '排序失败：$error');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<List<ProjectFileEntry>> _sortEntries(
    Iterable<ProjectFileEntry> source,
  ) async {
    final entries = List<ProjectFileEntry>.of(source);
    if (_sortOption == _ProjectSortOption.modifiedNewest ||
        _sortOption == _ProjectSortOption.modifiedOldest) {
      final stats = await Future.wait(
        entries.map((entry) async {
          try {
            return MapEntry<String, DateTime?>(
              entry.path,
              (await FileStat.stat(entry.path)).modified,
            );
          } catch (_) {
            return MapEntry<String, DateTime?>(entry.path, null);
          }
        }),
      );
      for (final stat in stats) {
        _modifiedTimes[stat.key] = stat.value;
      }
    }
    entries.sort(_compareEntries);
    return entries;
  }

  int _compareEntries(ProjectFileEntry left, ProjectFileEntry right) {
    if (left.isDirectory != right.isDirectory) {
      return left.isDirectory ? -1 : 1;
    }
    int comparison;
    switch (_sortOption) {
      case _ProjectSortOption.nameAscending:
      case _ProjectSortOption.nameDescending:
        comparison = left.name.compareTo(right.name);
      case _ProjectSortOption.modifiedNewest:
      case _ProjectSortOption.modifiedOldest:
        comparison = _compareNullable(
          _modifiedTimes[left.path],
          _modifiedTimes[right.path],
        );
      case _ProjectSortOption.sizeLargest:
      case _ProjectSortOption.sizeSmallest:
        comparison = _compareNullable(left.size, right.size);
    }
    if (comparison != 0 && _isDescending) return -comparison;
    if (comparison != 0) return comparison;
    return left.name.compareTo(right.name);
  }

  bool get _isDescending =>
      _sortOption == _ProjectSortOption.nameDescending ||
      _sortOption == _ProjectSortOption.modifiedNewest ||
      _sortOption == _ProjectSortOption.sizeLargest;

  int _compareNullable<T extends Comparable<Object>>(T? left, T? right) {
    if (left == null) return right == null ? 0 : 1;
    if (right == null) return -1;
    return left.compareTo(right);
  }

  Future<void> _open(ProjectFileEntry entry) async {
    if (entry.isDirectory) {
      _path.text = entry.path;
      await _load();
      return;
    }
    if (!_isInsideProject(entry.path)) {
      await _openExternalPath(entry.path);
      return;
    }
    final projectPath = _projectRelativePath(entry.path);
    final cached = _textCache[projectPath];
    final saved = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        builder: (_) => ProjectFileEditorPage(
          controller: widget.controller,
          project: widget.project,
          path: projectPath,
          name: entry.name,
          initialContent: cached,
        ),
      ),
    );
    if (saved != null) _textCache[projectPath] = saved;
    if (mounted) unawaited(_load(forceRefresh: true));
  }

  ProjectFileEntry? get _selectedEntry {
    if (_selected.length != 1) return null;
    final path = _selected.single;
    for (final entry in _entries) {
      if (entry.path == path) return entry;
    }
    return null;
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
    final selectedFile = _selectedEntry;
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
                onPressed: _selected.isEmpty || _loading
                    ? null
                    : () => _copySelection(move: false),
              ),
              _actionButton(
                icon: Icons.content_paste_outlined,
                label: '粘贴',
                onPressed: _clipboard.isEmpty || _loading ? null : _paste,
              ),
              _actionButton(
                icon: Icons.drive_file_move_outlined,
                label: '移动',
                onPressed: _selected.isEmpty || _loading
                    ? null
                    : () => _copySelection(move: true),
              ),
              _actionButton(
                icon: Icons.info_outline,
                label: '属性',
                onPressed: _selected.isEmpty || _loading ? null : _showInfo,
              ),
              _actionButton(
                icon: Icons.drive_file_rename_outline,
                label: '重命名',
                onPressed: _selected.length != 1 || _loading
                    ? null
                    : _renameSelected,
              ),
              _actionButton(
                icon: Icons.open_in_new,
                label: '打开',
                onPressed:
                    selectedFile == null || selectedFile.isDirectory || _loading
                    ? null
                    : _openExternal,
              ),
              _actionButton(
                icon: Icons.delete_outline,
                label: '删除',
                onPressed: _selected.isEmpty || _loading
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
    final destination = _normalizeAbsolutePath(_path.text);
    final paths = List<String>.from(_clipboard);
    final move = _clipboardMoves;
    setState(() => _loading = true);
    try {
      if (move) {
        await _manualFiles.move(paths, destination);
      } else {
        await _manualFiles.copy(paths, destination);
      }
      if (move) _clipboard.clear();
      _textCache.clear();
      _directoryCache.clear();
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
      await _manualFiles.rename(entry.path, name);
      _textCache.clear();
      _directoryCache.clear();
      _clearSelection();
      if (mounted) await _load(forceRefresh: true);
    } catch (error) {
      if (mounted) setState(() => _error = '重命名失败：$error');
    }
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
      await _manualFiles.delete(paths);
      _textCache.clear();
      _directoryCache.clear();
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
      final info = await _manualFiles.info(selected.single);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          title: Text(info.name),
          content: Text(
            '位置：${info.path}\n'
            '类型：${info.isDirectory ? '文件夹' : '文件'}\n'
            '大小：${_formatSize(info.size)}\n'
            '修改时间：${info.modified.toLocal().toString().split('.').first}',
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

  Future<void> _openExternal() async {
    final entry = _selectedEntry;
    if (entry == null || entry.isDirectory) return;
    await _openExternalPath(entry.path);
  }

  Future<void> _openExternalPath(String absolutePath) async {
    try {
      await AndroidFileOpener.open(absolutePath);
    } catch (error) {
      if (mounted) setState(() => _error = '打开文件失败：$error');
    }
  }

  bool _isInsideProject(String absolutePath) {
    final root = _normalizeAbsolutePath(widget.project.localPath);
    final path = _normalizeAbsolutePath(absolutePath);
    return path == root || path.startsWith('$root/');
  }

  String _projectRelativePath(String absolutePath) {
    return path_util
        .relative(
          _normalizeAbsolutePath(absolutePath),
          from: _normalizeAbsolutePath(widget.project.localPath),
        )
        .replaceAll(path_util.separator, '/');
  }

  Future<void> _openPreview() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => LocalPreviewPage(
          controller: widget.controller,
          project: widget.project,
        ),
      ),
    );
  }

  void _goParent() {
    final current = _normalizeAbsolutePath(_path.text);
    if (current == '/') return;
    _path.text = _normalizeAbsolutePath(path_util.dirname(current));
    unawaited(_load());
  }

  Future<void> _createFile() async {
    final name = await _askName('新建文件', '文件名');
    if (name == null || name.trim().isEmpty) return;
    try {
      await _manualFiles.createFile(
        path_util.join(_normalizeAbsolutePath(_path.text), name),
      );
      _directoryCache.clear();
      if (mounted) await _load(forceRefresh: true);
    } catch (error) {
      if (mounted) setState(() => _error = '新建文件失败：$error');
    }
  }

  Future<void> _createDirectory() async {
    final name = await _askName('新建文件夹', '文件夹名称');
    if (name == null || name.trim().isEmpty) return;
    try {
      await _manualFiles.createDirectory(
        path_util.join(_normalizeAbsolutePath(_path.text), name),
      );
      _directoryCache.clear();
      if (mounted) await _load(forceRefresh: true);
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
}

class ProjectFileEditorPage extends StatefulWidget {
  const ProjectFileEditorPage({
    required this.controller,
    required this.project,
    required this.path,
    required this.name,
    this.initialContent,
    super.key,
  });

  final AppController controller;
  final Project project;
  final String path;
  final String name;
  final String? initialContent;

  @override
  State<ProjectFileEditorPage> createState() => _ProjectFileEditorPageState();
}

class _ProjectFileEditorPageState extends State<ProjectFileEditorPage> {
  late final TextEditingController _content;
  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _content = TextEditingController(text: widget.initialContent ?? '');
    if (widget.initialContent == null) {
      unawaited(_load());
    } else {
      _loading = false;
    }
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
          if (widget.controller.documentModuleEnabled &&
              isDocumentSourceFile(widget.name))
            IconButton(
              tooltip: '文档预览',
              onPressed: _loading ? null : _previewDocument,
              icon: const Icon(Icons.article_outlined),
            ),
          if (widget.controller.documentModuleEnabled &&
              isDocumentSourceFile(widget.name))
            IconButton(
              tooltip: '导出 DOCX',
              onPressed: _loading || _saving ? null : _exportDocx,
              icon: const Icon(Icons.file_download_outlined),
            ),
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
                    expands: true,
                    maxLines: null,
                    minLines: null,
                    textAlignVertical: TextAlignVertical.top,
                    decoration: const InputDecoration(
                      hintText: '文本内容',
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
      final value = await widget.controller.readProjectFile(
        widget.project,
        widget.path,
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
      await widget.controller.writeProjectFile(
        widget.project,
        widget.path,
        _content.text,
      );
      if (mounted) Navigator.pop(context, _content.text);
    } catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = '保存文件失败：$error';
        });
      }
    }
  }

  Future<void> _previewDocument() async {
    if (_loading) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) =>
            DocumentPreviewPage(fileName: widget.name, content: _content.text),
      ),
    );
  }

  Future<void> _exportDocx() async {
    if (_loading || _saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final extension = path_util.posix.extension(widget.path);
    final outputPath = extension.isEmpty
        ? '${widget.path}.docx'
        : '${widget.path.substring(0, widget.path.length - extension.length)}.docx';
    try {
      final bytes = const DocumentExportService().exportDocx(
        fileName: widget.name,
        content: _content.text,
      );
      await widget.controller.writeProjectBytes(
        widget.project,
        outputPath,
        bytes,
      );
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('已导出：$outputPath')));
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = '导出 DOCX 失败：$error';
        });
      }
    }
  }
}

String _normalizeAbsolutePath(String value) {
  final path = value.trim().replaceAll('\\', '/');
  if (!path_util.posix.isAbsolute(path)) return '/';
  return path_util.posix.normalize(path);
}

String _formatSize(int? bytes) {
  if (bytes == null) return '大小未知';
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

_ProjectSortOption _projectSortOptionFromStorage(String value) {
  for (final option in _ProjectSortOption.values) {
    if (option.name == value) return option;
  }
  return _ProjectSortOption.nameAscending;
}

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
