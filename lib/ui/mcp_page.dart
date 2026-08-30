import 'dart:async';

import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../domain/models.dart';

class McpServersPage extends StatefulWidget {
  const McpServersPage({required this.controller, super.key});

  final AppController controller;

  @override
  State<McpServersPage> createState() => _McpServersPageState();
}

class _McpServersPageState extends State<McpServersPage> {
  String? _refreshingId;

  Future<void> _edit([McpServerProfile? profile]) async {
    final saved = await showMcpEditor(context, widget.controller, profile);
    if (!mounted || saved == null) return;
    await _refresh(saved);
  }

  Future<void> _refresh(McpServerProfile profile) async {
    if (_refreshingId != null) return;
    setState(() => _refreshingId = profile.id);
    try {
      final count = await widget.controller.refreshMcpServerTools(profile);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('已获取 $count 个 MCP 工具')));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('连接失败：$error')));
    } finally {
      if (mounted) setState(() => _refreshingId = null);
    }
  }

  Future<void> _toggle(McpServerProfile profile, bool enabled) async {
    try {
      await widget.controller.setMcpServerEnabled(profile, enabled);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('保存失败：$error')));
    }
  }

  Future<void> _delete(McpServerProfile profile) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除 MCP 配置？'),
        content: Text(profile.name),
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
    if (confirmed != true) return;
    try {
      await widget.controller.deleteMcpServer(profile);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('删除失败：$error')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final profiles = widget.controller.mcpServers;
        return Scaffold(
          appBar: AppBar(title: const Text('MCP 工具')),
          body: profiles.isEmpty
              ? const Center(child: Text('还没有 MCP 服务\n点击右下角添加手机本地 MCP 地址'))
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 88),
                  itemCount: profiles.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final profile = profiles[index];
                    return _McpServerCard(
                      profile: profile,
                      refreshing: _refreshingId == profile.id,
                      onEnabledChanged: (value) =>
                          unawaited(_toggle(profile, value)),
                      onRefresh: () => unawaited(_refresh(profile)),
                      onEdit: () => unawaited(_edit(profile)),
                      onDelete: () => unawaited(_delete(profile)),
                    );
                  },
                ),
          floatingActionButton: FloatingActionButton(
            onPressed: () => unawaited(_edit()),
            tooltip: '添加 MCP 服务',
            child: const Icon(Icons.add),
          ),
        );
      },
    );
  }
}

class _McpServerCard extends StatelessWidget {
  const _McpServerCard({
    required this.profile,
    required this.refreshing,
    required this.onEnabledChanged,
    required this.onRefresh,
    required this.onEdit,
    required this.onDelete,
  });

  final McpServerProfile profile;
  final bool refreshing;
  final ValueChanged<bool> onEnabledChanged;
  final VoidCallback onRefresh;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final updated = profile.toolsUpdatedAt;
    return Card(
      margin: EdgeInsets.zero,
      child: Column(
        children: [
          ListTile(
            leading: const CircleAvatar(child: Icon(Icons.extension_outlined)),
            title: Text(profile.name),
            subtitle: Text(
              '${profile.url}\n${profile.tools.length} 个工具'
              '${updated == null ? '' : ' · ${_formatDate(updated)}'}',
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
            isThreeLine: true,
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (refreshing)
                  const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                else
                  IconButton(
                    onPressed: onRefresh,
                    tooltip: '刷新工具列表',
                    icon: const Icon(Icons.refresh),
                  ),
                PopupMenuButton<String>(
                  onSelected: (value) {
                    if (value == 'edit') onEdit();
                    if (value == 'delete') onDelete();
                  },
                  itemBuilder: (context) => const [
                    PopupMenuItem(value: 'edit', child: Text('编辑')),
                    PopupMenuItem(value: 'delete', child: Text('删除')),
                  ],
                ),
                Switch.adaptive(
                  value: profile.enabled,
                  onChanged: onEnabledChanged,
                ),
              ],
            ),
          ),
          if (profile.tools.isNotEmpty)
            ExpansionTile(
              tilePadding: const EdgeInsets.symmetric(horizontal: 16),
              title: Text('查看工具（${profile.tools.length}）'),
              children: [
                for (final tool in profile.tools)
                  ListTile(
                    dense: true,
                    contentPadding: const EdgeInsets.fromLTRB(28, 0, 16, 4),
                    leading: const Icon(Icons.build_outlined, size: 18),
                    title: Text(
                      tool.title?.trim().isNotEmpty == true
                          ? tool.title!
                          : tool.name,
                    ),
                    subtitle: Text(
                      tool.title?.trim().isNotEmpty == true
                          ? '${tool.name}${tool.description.isEmpty ? '' : ' · ${tool.description}'}'
                          : tool.description,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

Future<McpServerProfile?> showMcpEditor(
  BuildContext context,
  AppController controller, [
  McpServerProfile? existing,
]) {
  return showModalBottomSheet<McpServerProfile>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => _McpEditorSheet(controller: controller, existing: existing),
  );
}

class _McpEditorSheet extends StatefulWidget {
  const _McpEditorSheet({required this.controller, this.existing});

  final AppController controller;
  final McpServerProfile? existing;

  @override
  State<_McpEditorSheet> createState() => _McpEditorSheetState();
}

class _McpEditorSheetState extends State<_McpEditorSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _url;
  late final TextEditingController _token;
  late bool _enabled;
  bool _clearToken = false;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _name = TextEditingController(text: existing?.name ?? '手机本地 MCP');
    _url = TextEditingController(
      text: existing?.url ?? 'http://127.0.0.1:8787/mcp',
    );
    _token = TextEditingController();
    _enabled = existing?.enabled ?? true;
  }

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _token.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hasToken = widget.existing?.tokenRef != null;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        16,
        16,
        16,
        16 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Form(
        key: _formKey,
        child: ListView(
          shrinkWrap: true,
          children: [
            Text(
              widget.existing == null ? '添加 MCP 服务' : '编辑 MCP 服务',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _name,
              decoration: const InputDecoration(labelText: '名称'),
              validator: (value) =>
                  value == null || value.trim().isEmpty ? '请输入名称' : null,
            ),
            TextFormField(
              controller: _url,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: 'MCP 地址',
                hintText: 'http://127.0.0.1:8787/mcp',
              ),
              validator: (value) {
                final uri = Uri.tryParse(value?.trim() ?? '');
                if (uri == null ||
                    uri.host.isEmpty ||
                    (uri.scheme != 'http' && uri.scheme != 'https')) {
                  return '请输入有效的 http 或 https 地址';
                }
                return null;
              },
            ),
            TextFormField(
              controller: _token,
              obscureText: true,
              decoration: InputDecoration(
                labelText: '访问令牌（可选）',
                hintText: hasToken ? '留空则保留已保存令牌' : null,
              ),
            ),
            if (hasToken)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('清除已保存令牌'),
                value: _clearToken,
                onChanged: (value) =>
                    setState(() => _clearToken = value ?? false),
              ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('启用此 MCP'),
              value: _enabled,
              onChanged: (value) => setState(() => _enabled = value),
            ),
            const SizedBox(height: 4),
            Text(
              '保存后会获取一次工具列表；以后使用缓存，点击刷新才重新获取。令牌只保存在手机安全存储，不会交给 AI。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _saving ? null : _save,
              icon: _saving
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save_outlined),
              label: const Text('保存并获取工具'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final saved = await widget.controller.saveMcpServer(
        existing: widget.existing,
        name: _name.text.trim(),
        url: _url.text.trim(),
        enabled: _enabled,
        token: _token.text,
        clearToken: _clearToken,
      );
      if (mounted) Navigator.pop(context, saved);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = '$error';
      });
    }
  }
}

String _formatDate(DateTime value) {
  final local = value.toLocal();
  return '${local.month}/${local.day} ${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
}
